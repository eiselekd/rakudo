#!/usr/bin/env raku

# This script reads the Array/Slice.pm6 file, and generates the
# necessary classes for inclusion in the postcircumfix:<[ ]> table
# for assigning array slices, and writes it back to the file.
#
# NOTE: the usefulness of this script is limited: once the 50x
# performance penalty on calling a private method of a consuming
# class from a role is gone, the code can be simplified to making
# a role for lazy and a role for non-lazy, and have the generated
# classes be simple consumers of those roles.  This performance
# improvement is expected to occur with the merging of the RakuAST
# work.

# always use highest version of Raku
use v6.*;

my $generator = $*PROGRAM-NAME;
my $generated = DateTime.now.gist.subst(/\.\d+/,'');
my $start     = '#- start of generated part of array slice assignment';
my $end       = '#- end of generated part of array slice assignment';

# slurp the whole file and set up writing to it
my $filename = "src/core.c/Array/Slice.pm6";
my @lines = $filename.IO.lines;
$*OUT = $filename.IO.open(:w);

# hash of lazy code seen, to avoid duplications in !accept-lazy method sources
my %lazycode-seen;
my constant $prefix = 'same as lazy ';
my constant $offset = $prefix.chars;

# for all the lines in the source that don't need special handling
while @lines {
    my $line := @lines.shift;

    # nothing to do yet
    unless $line.starts-with($start) {
        say $line;
        next;
    }

    # found header
    say $start ~ " " ~ "-" x 79 - $start.chars;
    say "#- Generated on $generated by $generator";
    say "#- PLEASE DON'T CHANGE ANYTHING BELOW THIS LINE";

    # skip the old version of the code
    while @lines {
        last if @lines.shift.starts-with($end);
    }

    for (
      'no actionable adverbs',
      'none',
      Q:to/CODE/,
        nqp::push($!result,nqp::push($!lhs,$!iterable.AT-POS(pos)));
        nqp::push($!rhs,$!values.pull-one);
CODE
      Q:to/CODE/,
        if $!iterable.EXISTS-POS(pos) {
            nqp::push($!result,nqp::push($!lhs,$!iterable.AT-POS(pos)));
            nqp::push($!rhs,$!values.pull-one);
        }
        else {
            $!done = 1;
        }
CODE

    ) -> $comment, $class, $code, $lazycode is copy {

        # make sure we have the right lazy code
        if $lazycode.starts-with($prefix) {
            $lazycode = %lazycode-seen{$lazycode.substr($offset)};
        }
        else {
            %lazycode-seen{$comment} = $lazycode;
        }

        # set up template values
        my %mapper =
          comment  => $comment,
          class    => $class,
          code     => $code.chomp,
          lazycode => $lazycode.chomp,
          delete    => ($comment.contains('delete')
            ?? Q:to/CODE/

    # Helper method for deleting elements, making sure that the total number
    # of elements is fixed from *before* the first deletion, so that relative
    # positions such as *-1 will continue to refer to the same position,
    # even if the last element of an array was removed (which shortens the
    # array).
    method !delete(\pos) {
        self!elems;
        $!iterable.DELETE-POS(pos)
    }
CODE
                !! ""),
            ;

            # spurt this class
            say Q:to/SOURCE/.subst(/ '#' (\w+) '#' /, -> $/ { %mapper{$0} }, :g).chomp;

# #comment#
my class Array::Slice::Assign::#class# is implementation-detail {
    has $!result;   # IterationBuffer with result
    has $!lhs;      # IterationBuffer with containers
    has $!rhs;      # IterationBuffer with values
    has $!iterable; # Iterable to assign to
    has $!elems;    # Number of elements in iterable
    has $!values;   # Iterator producing values to assign
    has int $!done; # flag to indicate we're done

    method !accept(\pos --> Nil) {
#code#
    }
    method !accept-lazy(\pos --> Nil) {
#lazycode#
    }

    method !SET-SELF(\iterable, \values) {
        $!result   := nqp::create(IterationBuffer);
        $!lhs      := nqp::create(IterationBuffer);
        $!rhs      := nqp::create(IterationBuffer);
        $!iterable := iterable;
        $!elems    := nqp::null;
        $!values   := values;
        self
    }
    method new(\iterable, \values) {
        nqp::create(self)!SET-SELF(iterable, values)
    }
    method !elems() {
        nqp::ifnull($!elems,$!elems := $!iterable.elems)
    }
#delete#
    # Handle iterator in the generated positions: this will add a List
    # with the elements pointed to by the iterator to the result.  Because
    # these positions can also be non-Int, some trickery needs to be
    # done to allow this being called recursively.
    method !handle-iterator(\iterator) {

        # basically push the current result on a stack
        my int $mark = nqp::elems($!result);

        # Lazy iterators should halt as soon as a non-existing element is seen
        if iterator.is-lazy {
            nqp::until(
              $!done
                || nqp::eqaddr((my \pos := iterator.pull-one),IterationEnd),
              nqp::if(
                nqp::istype(pos,Int),
                self!accept-lazy(pos),
                self!handle-nonInt-lazy(pos)
              )
            );
        }

        # Fast path for non-lazy iterators
        else {
            nqp::until(
              nqp::eqaddr((my \pos := iterator.pull-one),IterationEnd),
              nqp::if(
                nqp::istype(pos,Int),
                self!accept(pos),
                self!handle-nonInt(pos)
              )
            );
        }

        # Take what was added and push it as a List
        if nqp::isgt_i(nqp::elems($!result),$mark) {

            # Set up alternate result handling
            my $buffer;
            if $mark {
                $buffer :=
                  nqp::slice($!result,$mark,nqp::sub_i(nqp::elems($!result),1));
                nqp::setelems($!result,$mark);
            }
            else {
                $buffer  := $!result;
                $!result := nqp::create(IterationBuffer);
            }
            nqp::push($!result,$buffer.List);
        }
    }

    # Handle anything non-integer in the generated positions eagerly
    method !handle-nonInt(\pos) {
        nqp::istype(pos,Iterable)
          ?? nqp::iscont(pos)
            ?? self!accept(pos.Int)
            !! self!handle-iterator(pos.iterator)
          !! nqp::istype(pos,Callable)
            ?? nqp::istype((my \real := (pos)(self!elems)),Int)
              ?? self!accept(real)
              !! self!handle-nonInt(real)
            !! nqp::istype(pos,Whatever)
              ?? self!handle-iterator(
                   Rakudo::Iterator.IntRange(0,nqp::sub_i(self!elems,1))
                 )
              !! self!accept(pos.Int)
    }

    # Handle anything non-integer in the generated positions lazily
    method !handle-nonInt-lazy(\pos) {
        nqp::istype(pos,Iterable)
          ?? nqp::iscont(pos)
            ?? self!accept-lazy(pos.Int)
            !! self!handle-iterator(pos.iterator)
          !! nqp::istype(pos,Callable)
            ?? nqp::istype((my \real := (pos)(self!elems)),Int)
              ?? self!accept-lazy(real)
              !! self!handle-nonInt-lazy(real)
            !! nqp::istype(pos,Whatever)
              ?? self!handle-iterator(
                   Rakudo::Iterator.IntRange(0,nqp::sub_i(self!elems,1))
                 )
              !! self!accept-lazy(pos.Int)
    }

    # The actual building of the result
    method assign-slice(\iterator) {

        if iterator.is-lazy {
            nqp::until(
              $!done
                || nqp::eqaddr((my \pos := iterator.pull-one),IterationEnd),
              nqp::if(
                nqp::istype(pos,Int),
                self!accept-lazy(pos),
                self!handle-nonInt-lazy(pos)
              )
            );
        }
        else {
            nqp::until(
              nqp::eqaddr((my \pos := iterator.pull-one),IterationEnd),
              nqp::if(
                nqp::istype(pos,Int),
                self!accept(pos),
                self!handle-nonInt(pos)
              )
            );
        }

        # Do the actual assignments until there's nothing to assign anymore
        my $lhs := $!lhs;
        my $rhs := $!rhs;
        nqp::while(
          nqp::elems($lhs),
          nqp::assign(nqp::shift($lhs),nqp::shift($rhs))
        );

        $!result.List
    }
}
SOURCE
    }

    # we're done for this combination of adverbs
    say "";
    say "#- PLEASE DON'T CHANGE ANYTHING ABOVE THIS LINE";
    say $end ~ " " ~ "-" x 79 - $end.chars;
}

# close the file properly
$*OUT.close;

# vim: expandtab sw=4
