use NQPP6QRegex;
use QAST;

# This powers the optimization pass. It takes place after we've done all
# of the stuff in the grammar and actions, which means CHECK time is over.
# Thus we're allowed to assume that lexpads are immutable, declarations are
# over and done with, multi candidate lists won't change and so forth.
class Perl6::Optimizer {
    # Tracks the nested blocks we're in; it's the lexical chain, essentially.
    has @!block_stack;
    
    # How deep a chain we're in, for chaining operators.
    has $!chain_depth;
    
    # Unique ID for topic ($_) preservation registers.
    has $!pres_topic_counter;
    
    # Things that should cause compilation to fail; keys are errors, value is
    # array of line numbers.
    has %!deadly;
    
    # Things that should be warned about; keys are warnings, value is an array
    # of line numbers.
    has %!worrying;
    
    # Entry point for the optimization process.
    method optimize($past, *%adverbs) {
        # Initialize.
        @!block_stack := [$past[0]];
        $!chain_depth := 0;
        $!pres_topic_counter := 0;
        %!deadly := nqp::hash();
        %!worrying := nqp::hash();
        my $*DYNAMICALLY_COMPILED := 0;
        
        # Work out optimization level.
        my $*LEVEL := nqp::existskey(%adverbs, 'optimize') ??
            +%adverbs<optimize> !! 2;
        
        # We'll start walking over UNIT (we wouldn't find it by going
        # over OUTER since we don't walk loadinits).
        my $unit := $past<UNIT>;
        my $*GLOBALish := $past<GLOBALish>;
        my $*W := $past<W>;
        unless $unit.isa(QAST::Block) {
            nqp::die("Optimizer could not find UNIT");
        }
        self.visit_block($unit);
        
        # Die if we failed check in any way; otherwise, print any warnings.
        if +%!deadly {
            my @fails;
            for %!deadly {
                my @parts := nqp::split("\n", $_.key);
                my $headline := @parts.shift();
                @fails.push("$headline (line" ~ (+$_.value == 1 ?? ' ' !! 's ') ~
                    nqp::join(', ', $_.value) ~ ")" ~
                    (+@parts ?? "\n" ~ nqp::join("\n", @parts) !! ""));
            }
            nqp::die("CHECK FAILED:\n" ~ nqp::join("\n", @fails))
        }
        if +%!worrying {
            pir::printerr__vs("WARNINGS:\n");
            my @fails;
            for %!worrying {
                pir::printerr__vs($_.key ~ " (line" ~ (+$_.value == 1 ?? ' ' !! 's ') ~
                    nqp::join(', ', $_.value) ~ ")\n");
            }
        }
        
        $past
    }
    
    # Called when we encounter a block in the tree.
    method visit_block($block) {
        # Push block onto block stack.
        @!block_stack.push($block);
        
        # Visit children.
        if $block<DYNAMICALLY_COMPILED> {
            my $*DYNAMICALLY_COMPILED := 1;
            self.visit_children($block);
        }
        else {
            self.visit_children($block);
        }
        
        # Pop block from block stack.
        @!block_stack.pop();
        
        # If the block is immediate, we may be able to inline it.
        my $outer := @!block_stack[+@!block_stack - 1];
        if $block.blocktype eq 'immediate' && !$*DYNAMICALLY_COMPILED {
            # Scan symbols for any non-interesting ones.
            my @sigsyms;
            for $block.symtable() {
                my $name := $_.key;
                if $name ne '$_' && $name ne 'call_sig' && $name ne '$*DISPATCHER' {
                    @sigsyms.push($name);
                }
            }
            
            # If we have no interesting ones, then we can inline the
            # statements.
            # XXX We can also check for lack of colliding symbols and
            # do something in that case. However, it's non-trivial as
            # the static lexpad entries will need twiddling with.
            if +@sigsyms == 0 {
                if $*LEVEL >= 3 {
                    #return self.inline_immediate_block($block, $outer);
                }
            }
        }
        
        $block
    }
    
    # Called when we encounter a QAST::Op in the tree. Produces either
    # the op itself or some replacement opcode to put in the tree.
    method visit_op($op) {
        # If it's a QAST::Op of type handle, needs some special attention.
        my $optype := $op.op;
        if $optype eq 'handle' {
            return self.visit_handle($op);
        }
        
        # A chain with exactly two children can become the op itself.
        if $optype eq 'chain' {
            $!chain_depth := $!chain_depth + 1;
            $optype := 'call' if $!chain_depth == 1 &&
                !($op[0].isa(QAST::Op) && $op[0].op eq 'chain') &&
                !($op[1].isa(QAST::Op) && $op[1].op eq 'chain');
        }
        
        # Visit the children.
        self.visit_children($op);
        
        # Calls are especially interesting as we may wish to do some
        # kind of inlining.
        if $optype eq 'call' && $op.name ne '' {
            # See if we can find the thing we're going to call.
            my $obj;
            my $found;
            try {
                $obj := self.find_lexical($op.name);
                $found := 1;
            }
            if $found {
                # If it's an onlystar proto, we have a couple of options.
                # The first is that we may be able to work out what to
                # call at compile time. Failing that, we can at least inline
                # the proto.
                my $dispatcher;
                try { if $obj.is_dispatcher { $dispatcher := 1 } }
                if $dispatcher {
                    # Try to do compile-time multi-dispatch.
                    my @ct_arg_info := analyze_args_for_ct_call($op);
                    if +@ct_arg_info {
                        my @types := @ct_arg_info[0];
                        my @flags := @ct_arg_info[1];
                        my @ct_result := pir::perl6_multi_dispatch_ct__PPPP($obj, @types, @flags);
                        if @ct_result[0] == 1 {
                            my $chosen := @ct_result[1];
                            if $op.op eq 'chain' { $!chain_depth := $!chain_depth - 1 }
                            if $*LEVEL >= 2 {
                                return nqp::can($chosen, 'inline_info') && $chosen.inline_info ne ''
                                    ?? self.inline_call($op, $chosen)
                                    !! self.call_ct_chosen_multi($op, $obj, $chosen);
                            }
                        }
                        elsif @ct_result[0] == -1 {
                            self.report_innevitable_dispatch_failure($op, @types, @flags, $obj);
                        }
                    }
                    
                    # Otherwise, inline the proto.
                    if $op.op eq 'chain' { $!chain_depth := $!chain_depth - 1 }
                    if $*LEVEL >= 2 {
                        return self.inline_proto($op, $obj);
                    }
                }
                elsif nqp::can($obj, 'signature') {
                    # It's an only; we can at least know the return type.
                    $op.returns($obj.returns) if nqp::can($obj, 'returns');
                    
                    # If we know enough about the arguments, do a "trial bind".
                    my @ct_arg_info := analyze_args_for_ct_call($op);
                    if +@ct_arg_info {
                        my @types := @ct_arg_info[0];
                        my @flags := @ct_arg_info[1];
                        my $ct_result := pir::perl6_trial_bind_ct__IPPP($obj.signature, @types, @flags);
                        if $ct_result == 1 {
                            if $op.op eq 'chain' { $!chain_depth := $!chain_depth - 1 }
                            #say("# trial bind worked!");
                            if $*LEVEL >= 2 {
                                return nqp::can($obj, 'inline_info') && $obj.inline_info ne ''
                                    ?? self.inline_call($op, $obj)
                                    !! $op;
                            }
                        }
                        elsif $ct_result == -1 {
                            self.report_innevitable_dispatch_failure($op, @types, @flags, $obj);
                        }
                    }
                }
            }
            else {
                # We really should find routines; failure to do so is a CHECK
                # time error. Check that it's not just compile-time unknown,
                # however (shows up in e.g. sub foo(&x) { x() }).
                unless self.is_lexical_declared($op.name) {
                    self.add_deadly($op, "Undefined routine '" ~ $op.name ~ "' called");
                }
            }
        }
        
        # If it's a private method call, we can sometimes resolve it at
        # compile time. If so, we can reduce it to a sub call in some cases.
        elsif $*LEVEL >= 3 && $op.op eq 'callmethod' && $op.name eq 'dispatch:<!>' {
            if $op[1]<has_compile_time_value> && $op[1]<boxable_native> == 3 {
                my $name := $op[1][2].value; # get raw string name
                my $pkg  := $op[2].returns;  # actions always sets this
                my $meth := $pkg.HOW.find_private_method($pkg, $name);
                if $meth {
                    try {
                        $*W.get_ref($meth); # may fail, thus the try; verifies it's in SC
                        my $call := QAST::WVal.new( :value($meth) );
                        my $inv  := $op.shift;
                        $op.shift; $op.shift; # name, package (both pre-resolved now)
                        $op.unshift($inv);
                        $op.unshift($call);
                        $op.op('call');
                        $op.name(nqp::null());
                    }
                }
                else {
                    self.add_deadly($op, "Undefined private method '" ~ $name ~ "' called");
                }
            }
        }
        
        # If we end up here, just leave op as is.
        if $op.op eq 'chain' {
            $!chain_depth := $!chain_depth - 1;
        }
        $op
    }
    
    # Handles visiting a QAST::Op :op('handle').
    method visit_handle($op) {
        self.visit_children($op, :skip_selectors);
        $op
    }
    
    # Handles visiting a QAST::Want node.
    method visit_want($want) {
        # Just visit the children for now. We ignore the literal strings, so
        # it all works out.
        self.visit_children($want, :skip_selectors)
    }
    
    # Handles visit a variable node.
    method visit_var($var) {
        # Nothing to do yet.
    }
    
    # Checks arguments to see if we're going to be able to do compile
    # time analysis of the call.
    sub analyze_args_for_ct_call($op) {
        my @types;
        my @flags;
        for @($op) {
            # Can't cope with flattening or named.
            if $_.flat || $_.named ne '' {
                return [];
            }
            
            # See if we know the node's type.
            if $_<boxable_native> {
                @types.push(nqp::null());
                @flags.push($_<boxable_native>);
            }
            elsif nqp::can($_, 'returns') && !nqp::isnull($_.returns) {
                my $type := $_.returns();
                if pir::isa($type, 'Undef') {
                    return [];
                }
                elsif $type.HOW.archetypes.generic {
                    return [];
                }
                else {
                    my $prim := pir::repr_get_primitive_type_spec__IP($type);
                    @types.push($type);
                    @flags.push($prim);
                }
            }
            else {
                return [];
            }
        }
        [@types, @flags]
    }
    
    method report_innevitable_dispatch_failure($op, @types, @flags, $obj) {
        my @arg_names;
        my $i := 0;
        while $i < +@types {
            @arg_names.push(
                @flags[$i] == 1 ?? 'int' !!
                @flags[$i] == 2 ?? 'num' !!
                @flags[$i] == 3 ?? 'str' !!
                @types[$i].HOW.name(@types[$i]));
            $i := $i + 1;
        }
        self.add_deadly($op,
            "Calling '" ~ $obj.name ~ "' will never work with " ~
            (+@arg_names == 0 ??
                "no arguments" !!
                "argument types (" ~ nqp::join(', ', @arg_names) ~ ")"),
            $obj.is_dispatcher ??
                multi_sig_list($obj) !!
                ["    Expected: " ~ $obj.signature.perl]);
    }
    
    # Signature list for multis.
    sub multi_sig_list($dispatcher) {
        my @sigs := ["    Expected any of:"];
        for $dispatcher.dispatchees {
            @sigs.push("    " ~ $_.signature.perl);
        }
        @sigs
    }
    
    # Visits all of a nodes children, and dispatches appropriately.
    method visit_children($node, :$skip_selectors) {
        my $i := 0;
        while $i < +@($node) {
            unless $skip_selectors && $i % 2 {
                my $visit := $node[$i];
                if $visit.isa(QAST::Op) {
                    $node[$i] := self.visit_op($visit)
                }
                elsif $visit.isa(QAST::Block) {
                    $node[$i] := self.visit_block($visit);
                }
                elsif $visit.isa(QAST::Stmts) {
                    self.visit_children($visit);
                }
                elsif $visit.isa(QAST::Stmt) {
                    self.visit_children($visit);
                }
                elsif $visit.isa(QAST::Want) {
                    self.visit_want($visit);
                }
                elsif $visit.isa(QAST::Var) {
                    self.visit_var($visit);
                }
            }
            $i := $i + 1;
        }
    }
    
    # Locates a lexical symbol and returns its compile time value. Dies if
    # it does not exist.
    method find_lexical($name) {
        my $i := +@!block_stack;
        while $i > 0 {
            $i := $i - 1;
            my $block := @!block_stack[$i];
            my %sym := $block.symbol($name);
            if +%sym {
                if nqp::existskey(%sym, 'value') {
                    return %sym<value>;
                }
                else {
                    nqp::die("Optimizer: No lexical compile time value for $name");
                }
            }
        }
        nqp::die("Optimizer: No lexical $name found");
    }
    
    # Checks if a given lexical is declared, though it needn't have a compile
    # time known value.
    method is_lexical_declared($name) {
        my $i := +@!block_stack;
        while $i > 0 {
            $i := $i - 1;
            my $block := @!block_stack[$i];
            my %sym := $block.symbol($name);
            if +%sym {
                return 1;
            }
        }
        0
    }
    
    # Inlines an immediate block.
    method inline_immediate_block($block, $outer) {
        # Extract interesting parts of block.
        my $decls := $block.shift;
        my $stmts := $block.shift;

        # Turn block into an "optimized out" stub (deserialization
        # or fixup will still want it to be there).
        $block.blocktype('declaration');
        $block[0] := QAST::Op.new( :op('die_s'),
            QAST::SVal.new( :value('INTERNAL ERROR: Execution of block eliminated by optimizer') ) );
        $outer[0].push($block);
        
        # Copy over interesting stuff in declaration section.
        for @($decls) {
            if $_.isa(QAST::Op) && $_.op eq 'p6bindsig' {
                # Don't copy this binder call.
            }
            elsif $_.isa(QAST::Var) && ($_.name eq '$/' || $_.name eq '$!' ||
                    $_.name eq '$_' || $_.name eq 'call_sig' || $_.name eq '$*DISPATCHER') {
                # Don't copy this variable node.
            }
            else {
                $outer[0].push($_);
            }
        }
        
        # Hand back the statements, but be sure to preserve $_
        # around them.
        $!pres_topic_counter := $!pres_topic_counter + 1;
        $outer[0].push(QAST::Var.new( :scope('local'),
            :name("pres_topic_$!pres_topic_counter"), :decl('var') ));
        return QAST::Stmts.new(
            :resultchild(1),
            QAST::Op.new( :op('bind'),
                QAST::Var.new( :name("pres_topic_$!pres_topic_counter"), :scope('local') ),
                QAST::Var.new( :name('$_'), :scope('lexical') )
            ),
            $stmts,
            QAST::Op.new( :op('bind'),
                QAST::Var.new( :name('$_'), :scope('lexical') ),
                QAST::Var.new( :name("pres_topic_$!pres_topic_counter"), :scope('local') )
            )
        );
    }
    
    # Inlines a proto.
    method inline_proto($call, $proto) {
        # XXX Still needs updating.
        return $call;
        $call.unshift(PAST::Op.new(
            :pirop('perl6_multi_dispatch_thunk PP'),
            QAST::Var.new( :name($call.name), :scope('lexical') )));
        $call.name(nqp::null());
        $call.op('call');
        $call
    }
    
    # Inlines a call to a sub.
    method inline_call($call, $code_obj) {
        # XXX Still needs updating.
        return $call;
        my $inline := $code_obj.inline_info();
        my $name   := $call.name;
        my @tokens := nqp::split(' ', $inline);
        my @stack  := [PAST::Stmt.new()];
        while +@tokens {
            my $cur_tok := @tokens.shift;
            if $cur_tok eq ')' {
                my $popped := @stack.pop();
                @stack[+@stack - 1].push($popped);
            }
            elsif $cur_tok eq 'ARG' {
                @stack[+@stack - 1].push($call[+@tokens.shift()]);
            }
            elsif $cur_tok eq 'PIROP' {
                @stack.push(PAST::Op.new( :pirop(@tokens.shift()) ));
                unless @tokens.shift() eq '(' {
                    nqp::die("INTERNAL ERROR: Inline corrupt for $name; expected '('");
                }
            }
            elsif $cur_tok eq 'WANT' {
                @stack.push(PAST::Want.new());
                unless @tokens.shift() eq '(' {
                    nqp::die("INTERNAL ERROR: Inline corrupt for $name; expected '('");
                }
            }
            elsif $cur_tok eq 'WANTSPEC' {
                @stack[+@stack - 1].push(~@tokens.shift());
            }
            elsif $cur_tok ne '' {
                nqp::die("INTERNAL ERROR: Unexpected inline token for $name: " ~ $cur_tok);
                return $call;
            }
        }
        if +@stack != 1 {
            nqp::die("INTERNAL ERROR: Non-empty inline stack for $name")
        }
        if $call.named ne '' {
            @stack[0].named($call.named);
        }
        @stack[0].returns($code_obj.returns) if nqp::can($code_obj, 'returns');
        #say("# inlined a call to $name");
        @stack[0]
    }
    
    # If we decide a dispatch at compile time, this emits the direct call.
    method call_ct_chosen_multi($call, $proto, $chosen) {
        # XXX still needs updating
        return $call;
        my @cands := $proto.dispatchees();
        my $idx := 0;
        for @cands {
            if $_ =:= $chosen {
                $call.unshift(PAST::Op.new(
                    :pirop('perl6_multi_dispatch_cand_thunk PPi'),
                    QAST::Var.new( :name($call.name), :scope('lexical') ),
                    $idx));
                $call.name(nqp::null());
                $call.op('call');
                #say("# Compile-time resolved a call to " ~ $proto.name);
                last;
            }
            $idx := $idx + 1;
        }
        $call.returns($chosen.returns) if nqp::can($chosen, 'returns');
        $call
    }
    
    # Adds an entry to the list of things that would cause a check fail.
    method add_deadly($past_node, $message, @extras?) {
        my $line := HLL::Compiler.lineof($past_node<source>, $past_node<pos>);
        my $key := $message ~ (+@extras ?? "\n" ~ nqp::join("\n", @extras) !! "");
        unless %!deadly{$key} {
            %!deadly{$key} := [];
        }
        %!deadly{$key}.push($line);
    }
}
