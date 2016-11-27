# This script reads the native_array.pm file from STDIN, and generates the
# shapedintarray, shapednumarray and shapedstrarray roles in it, and writes
# it to STDOUT.

use v6;

my $generator = $*PROGRAM-NAME;
my $generated = DateTime.now.gist.subst(/\.\d+/,'');
my $start     = '#- start of generated part of shaped';
my $idpos     = $start.chars;
my $idchars   = 3;
my $end       = '#- end of generated part of shaped';

# for all the lines in the source that don't need special handling
for $*IN.lines -> $line {

    # nothing to do yet
    unless $line.starts-with($start) {
        say $line;
        next;
    }

    # found header
    my $type = $line.substr($idpos,$idchars);
    die "Don't know how to handle $type" unless $type eq "int" | "num" | "str";
    say $start ~ $type ~ "array role -----------------------------";
    say "#- Generated on $generated by $generator";
    say "#- PLEASE DON'T CHANGE ANYTHING BELOW THIS LINE";

    # skip the old version of the code
    for $*IN.lines -> $line {
        last if $line.starts-with($end);
    }

    # set up template values
    my %mapper =
      postfix => $type.substr(0,1),
      type    => $type,
      Type    => $type.tclc,
    ;

    # spurt the roles
    say Q:to/SOURCE/.subst(/ '#' (\w+) '#' /, -> $/ { %mapper{$0} }, :g).chomp;

    role shaped#type#array does shapedarray {
        multi method AT-POS(::?CLASS:D: **@indices) is raw {
            nqp::if(
              nqp::iseq_i(
                (my int $numdims = nqp::numdimensions(self)),
                (my int $numind  = @indices.elems),  # reifies
              ),
              nqp::stmts(
                (my $indices := nqp::getattr(@indices,List,'$!reified')),
                (my $idxs := nqp::list_i),
                nqp::while(                          # native index list
                  nqp::isge_i(($numdims = nqp::sub_i($numdims,1)),0),
                  nqp::push_i($idxs,nqp::shift($indices))
                ),
#?if moar
                nqp::multidimref_#postfix#(self,$idxs)
#?endif
#?if !moar
                nqp::atposnd_#postfix#(self,$idxs)
#?endif
              ),
              nqp::if(
                nqp::isgt_i($numind,$numdims),
                X::TooManyDimensions.new(
                  operation => 'access',
                  got-dimensions => $numind,
                  needed-dimensions => $numdims
                ).throw,
                X::NYI.new(
                  feature => "Partially dimensioned views of arrays"
                ).throw
              )
            )
        }

        multi method ASSIGN-POS(::?CLASS:D: **@indices) {
            nqp::stmts(
              (my #type# $value = @indices.pop),
              nqp::if(
                nqp::iseq_i(
                  (my int $numdims = nqp::numdimensions(self)),
                  (my int $numind  = @indices.elems),  # reifies
                ),
                nqp::stmts(
                  (my $indices := nqp::getattr(@indices,List,'$!reified')),
                  (my $idxs := nqp::list_i),
                  nqp::while(                          # native index list
                    nqp::isge_i(($numdims = nqp::sub_i($numdims,1)),0),
                    nqp::push_i($idxs,nqp::shift($indices))
                  ),
                  nqp::bindposnd_#postfix#(self, $idxs, $value)
                ),
                nqp::if(
                  nqp::isgt_i($numind,$numdims),
                  X::TooManyDimensions,
                  X::NotEnoughDimensions
                ).new(
                  operation => 'assign to',
                  got-dimensions => $numind,
                  needed-dimensions => $numdims
                ).throw
              )
            )
        }

        sub MEMCPY(Mu \shape, Mu \to, Mu \from) is raw {
            class :: does Rakudo::Internals::ShapeLeafIterator {
                has Mu $!from;
                method INIT(Mu \shape, Mu \to, Mu \from) {
                    nqp::stmts(
                      ($!from := from),
                      self.SET-SELF(shape,to)
                    )
                }
                method new(Mu \shape, Mu \to, Mu \from) {
                    nqp::create(self).INIT(shape,to,from)
                }
                method result(--> Nil) {
                    nqp::bindposnd_#postfix#($!list,$!indices,
                      nqp::atposnd_#postfix#($!from,$!indices))
                }
            }.new(shape,to,from).sink-all;
            to
        }

        multi method STORE(::?CLASS:D: ::?CLASS:D \in) {
            nqp::if(
              in.shape eqv (my \shape := self.shape),
              MEMCPY(shape,self,in),
              X::Assignment::ArrayShapeMismatch.new(
                source-shape => in.shape,
                target-shape => shape
              ).throw
            )
        }
    }  # end of shaped#type#array role

    role shaped1#type#array does shaped#type#array {
        multi method AT-POS(::?CLASS:D: int \one) is raw {
           nqp::atposref_#postfix#(self,one)
        }
        multi method AT-POS(::?CLASS:D: Int:D \one) is raw {
           nqp::atposref_#postfix#(self,one)
        }

        multi method ASSIGN-POS(::?CLASS:D: int \one, #type# \value) {
            nqp::bindpos_#postfix#(self,one,value)
        }
        multi method ASSIGN-POS(::?CLASS:D: Int:D \one, #type# \value) {
            nqp::bindpos_#postfix#(self,one,value)
        }
        multi method ASSIGN-POS(::?CLASS:D: int \one, #Type#:D \value) {
            nqp::bindpos_#postfix#(self,one,value)
        }
        multi method ASSIGN-POS(::?CLASS:D: Int:D \one, #Type#:D \value) {
            nqp::bindpos_#postfix#(self,one,value)
        }

        multi method EXISTS-POS(::?CLASS:D: int \one) {
            nqp::p6bool(
              nqp::isge_i(one,0) && nqp::islt_i(one,nqp::elems(self))
            )
        }
        multi method EXISTS-POS(::?CLASS:D: Int:D \one) {
            nqp::p6bool(
              nqp::isge_i(one,0) && nqp::islt_i(one,nqp::elems(self))
            )
        }

        multi method STORE(::?CLASS:D: ::?CLASS:D \from) {
            nqp::if(
              nqp::iseq_i((my int $elems = nqp::elems(self)),nqp::elems(from)),
              nqp::stmts(
                (my int $i = -1),
                nqp::while(
                  nqp::islt_i(($i = nqp::add_i($i,1)),$elems),
                  nqp::bindpos_#postfix#(self,$i,nqp::atpos_#postfix#(from,$i))
                ),
                self
              ),
              X::Assignment::ArrayShapeMismatch.new(
                source-shape => from.shape,
                target-shape => self.shape
              ).throw
            )
        }
        multi method STORE(::?CLASS:D: Iterable:D \in) {
            nqp::stmts(
              (my \iter := in.iterator),
              (my int $elems = nqp::elems(self)),
              (my int $i = -1),
              nqp::until(
                nqp::eqaddr((my $pulled := iter.pull-one),IterationEnd)
                  || nqp::iseq_i(($i = nqp::add_i($i,1)),$elems),
                nqp::bindpos_#postfix#(self,$i,$pulled)
              ),
              nqp::unless(
                nqp::islt_i($i,$elems) || iter.is-lazy,
                nqp::atpos_#postfix#(list,$i) # too many values on non-lazy it
              ),
              self
            )
        }
        multi method STORE(::?CLASS:D: #Type#:D \item) {
            nqp::stmts(
              nqp::bindpos_#postfix#(self,0,item),
              self
            )
        }
    } # end of shaped1#type#array role

    role shaped2#type#array does shaped#type#array {
        multi method AT-POS(::?CLASS:D: int \one, int \two) is raw {
            nqp::atpos2d_#postfix#(self,one,two)
        }
        multi method AT-POS(::?CLASS:D: Int:D \one, Int:D \two) is raw {
            nqp::atpos2d_#postfix#(self,one,two)
        }

        multi method ASSIGN-POS(::?CLASS:D: int \one, int \two, #Type#:D \value) {
            nqp::bindpos2d_#postfix#(self,one,two,value)
        }
        multi method ASSIGN-POS(::?CLASS:D: Int:D \one, Int:D \two, #Type#:D \value) {
            nqp::bindpos2d_#postfix#(self,one,two,value)
        }

        multi method EXISTS-POS(::?CLASS:D: int \one, int \two) {
            nqp::p6bool(
              nqp::isge_i(one,0)
                && nqp::isge_i(two,0)
                && nqp::islt_i(one,nqp::atpos_i(nqp::dimensions(self),0))
                && nqp::islt_i(two,nqp::atpos_i(nqp::dimensions(self),1))
            )
        }
        multi method EXISTS-POS(::?CLASS:D: Int:D \one, Int:D \two) {
            nqp::p6bool(
              nqp::isge_i(one,0)
                && nqp::isge_i(two,0)
                && nqp::islt_i(one,nqp::atpos_i(nqp::dimensions(self),0))
                && nqp::islt_i(two,nqp::atpos_i(nqp::dimensions(self),1))
            )
        }
    } # end of shaped2#type#array role

    role shaped3#type#array does shaped#type#array {
        multi method AT-POS(::?CLASS:D: int \one, int \two, int \three) is raw {
            nqp::atpos3d_#postfix#(self,one,two,three)
        }
        multi method AT-POS(::?CLASS:D: Int:D \one, Int:D \two, Int:D \three) is raw {
            nqp::atpos3d_#postfix#(self,one,two,three)
        }

        multi method ASSIGN-POS(::?CLASS:D: int \one, int \two, int \three, #Type#:D \value) {
            nqp::bindpos3d_#postfix#(self,one,two,three,value)
        }
        multi method ASSIGN-POS(::?CLASS:D: Int:D \one, Int:D \two, Int:D \three, #Type#:D \value) {
            nqp::bindpos3d_#postfix#(self,one,two,three,value)
        }

        multi method EXISTS-POS(::?CLASS:D: int \one, int \two, int \three) {
            nqp::p6bool(
              nqp::isge_i(one,0)
                && nqp::isge_i(two,0)
                && nqp::isge_i(three,0)
                && nqp::islt_i(one,nqp::atpos_i(nqp::dimensions(self),0))
                && nqp::islt_i(two,nqp::atpos_i(nqp::dimensions(self),1))
                && nqp::islt_i(three,nqp::atpos_i(nqp::dimensions(self),2))
            )
        }
        multi method EXISTS-POS(::?CLASS:D: Int:D \one, Int:D \two, Int:D \three) {
            nqp::p6bool(
              nqp::isge_i(one,0)
                && nqp::isge_i(two,0)
                && nqp::isge_i(three,0)
                && nqp::islt_i(one,nqp::atpos_i(nqp::dimensions(self),0))
                && nqp::islt_i(two,nqp::atpos_i(nqp::dimensions(self),1))
                && nqp::islt_i(three,nqp::atpos_i(nqp::dimensions(self),2))
            )
        }
    } # end of shaped3#type#array role
SOURCE

    # we're done for this role
    say "#- PLEASE DON'T CHANGE ANYTHING ABOVE THIS LINE";
    say $end ~ $type ~ "array role -------------------------------";
}
