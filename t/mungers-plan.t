#!perl
use 5.006;
use strict;
use warnings;
use Test::More;

use Algorithm::Classifier::IsolationForest::Zorita::Mungers;
my $M = 'Algorithm::Classifier::IsolationForest::Zorita::Mungers';

my $FMT = '%Y-%m-%dT%H:%M:%S';

# A set with a sin/cos time expander, a scalar log column, and a raw column.
my $plan = $M->compile(
    tags    => [qw(time_sin time_cos bytes status)],
    mungers => {
        time_of_week => {
            munger => 'datetime', from => 'timestamp', format => $FMT,
            parts  => [qw(sin_week cos_week)],
            into   => [qw(time_sin time_cos)],
        },
        bytes => { munger => 'log', offset => 1 },
    },
);
isa_ok( $plan, 'Algorithm::Classifier::IsolationForest::Zorita::Mungers::Plan' );

# ---- apply_named: the expander fills both columns from one source -----------
{
    # 2026-07-05 is Sunday: midnight is frac_week 0 -> sin 0, cos 1.
    my $row = $plan->apply_named(
        { timestamp => '2026-07-05T00:00:00', bytes => 0, status => 200 } );
    is_deeply( $row, [ 0, 1, 0, 200 ],
        'apply_named: sin/cos pair + log1p(0) + raw status, in tag order' );

    eval { $plan->apply_named( { bytes => 0, status => 200 } ) };
    like( $@, qr/missing value for 'timestamp'/,
        'apply_named croaks when an expander source is missing' );
}

# ---- from-alias on a scalar munger -----------------------------------------
{
    my $al = $M->compile(
        tags    => ['x'],
        mungers => { x => { munger => 'log', offset => 1, from => 'src' } },
    );
    is( $al->apply_named( { src => 0 } )->[0], 0, 'scalar from-alias reads source' );
    eval { $al->apply_named( { x => 0 } ) };
    like( $@, qr/missing value for 'src'/, 'from-alias requires the source field' );
}

# ---- apply_positional: scalars only, no mutation ---------------------------
{
    my $p = $M->compile(
        tags => [qw(a b)], mungers => { a => { munger => 'log', offset => 1 } } );
    my $orig = [ 3, 5 ];
    my $out  = $p->apply_positional($orig);
    ok( abs( $out->[0] - log(4) ) < 1e-9, 'positional applies the scalar munger' );
    is( $out->[1], 5, 'positional passes a raw column through' );
    is_deeply( $orig, [ 3, 5 ], 'positional does not mutate the caller row' );

    eval { $p->apply_positional( [1] ) };
    like( $@, qr/declares 2/, 'positional arity check' );

    eval { $plan->apply_positional( [ 1, 2, 3, 4 ] ) };
    like( $@, qr/expanding mungers/,
        'positional is rejected when the set has expanders' );
}

# ---- a set with no mungers is all-raw --------------------------------------
{
    my $raw = $M->compile( tags => [qw(a b)] );
    is_deeply( $raw->apply_named( { a => 1, b => 2 } ), [ 1, 2 ], 'no-munger named' );
    is_deeply( $raw->apply_positional( [ 3, 4 ] ), [ 3, 4 ], 'no-munger positional' );
}

# ---- compile-time coverage validation --------------------------------------
{
    # two mungers claim the same column
    eval {
        $M->compile(
            tags    => ['x'],
            mungers => {
                x => { munger => 'log' },
                g => { munger => 'datetime', format => $FMT,
                    parts => ['epoch'], into => ['x'] },
            },
        );
    };
    like( $@, qr/two mungers write column 'x'/, 'rejects overlapping claims' );

    # into names an unknown column
    eval {
        $M->compile(
            tags    => ['a'],
            mungers => { g => { munger => 'datetime', format => $FMT,
                    parts => ['epoch'], into => ['nope'] } },
        );
    };
    like( $@, qr/unknown column 'nope'/, 'rejects into on an unknown column' );

    # a key that is neither a tag nor an expander
    eval { $M->compile( tags => ['a'], mungers => { zzz => { munger => 'log' } } ) };
    like( $@, qr/is not a declared tag and has no 'into'/, 'rejects orphan key' );

    # parts / into length mismatch
    eval {
        $M->compile(
            tags    => [qw(a b)],
            mungers => { g => { munger => 'datetime', format => $FMT,
                    parts => [qw(sin_week cos_week)], into => ['a'] } },
        );
    };
    like( $@, qr/produces 2 value\(s\) but 'into' lists 1/,
        'rejects parts/into arity mismatch' );

    # into on a munger that cannot fan out
    eval {
        $M->compile(
            tags    => ['a'],
            mungers => { g => { munger => 'log', into => ['a'] } },
        );
    };
    like( $@, qr/does not support multiple outputs/,
        'rejects into on a single-output munger' );

    # scalar build path refuses 'parts'
    eval { $M->build( { munger => 'datetime', format => $FMT, parts => ['epoch'] } ) };
    like( $@, qr/'parts' is for the multi-output form/,
        'scalar datetime rejects parts without into' );
}

done_testing;
