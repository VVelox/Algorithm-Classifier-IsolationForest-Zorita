#!perl
use 5.006;
use strict;
use warnings;
use Test::More;

use Algorithm::Classifier::IsolationForest::Zorita::Mungers;
my $M = 'Algorithm::Classifier::IsolationForest::Zorita::Mungers';

# ---- registry -------------------------------------------------------------
ok( $M->has_munger('enum'), 'enum is a known munger' );
ok( !$M->has_munger('nope'), 'unknown munger is not known' );
is_deeply(
    [ $M->known_mungers ],
    [
        qw(bool bucket char clamp count datetime entropy enum eps freq_map
            ftp_enum hash http_enum length log scale sip_enum smtp_enum zscore)
    ],
    'known_mungers is the full sorted set',
);

# ---- enum -----------------------------------------------------------------
{
    my $c = $M->build( { munger => 'enum', map => { GET => 0, POST => 1 } } );
    is( $c->('GET'),  0, 'enum maps GET' );
    is( $c->('POST'), 1, 'enum maps POST' );
    eval { $c->('HEAD') };
    like( $@, qr/no mapping for 'HEAD'/, 'enum croaks on unmapped without default' );

    my $d = $M->build(
        { munger => 'enum', map => { GET => 0 }, default => -1 } );
    is( $d->('WAT'),  -1, 'enum default for unmapped' );
    is( $d->(undef),  -1, 'enum default for undef' );
}

# ---- http_enum ------------------------------------------------------------
{
    my $c = $M->build( { munger => 'http_enum' } );
    is( $c->(100), 1, 'http_enum 1xx -> 1' );
    is( $c->(200), 2, 'http_enum 2xx -> 2' );
    is( $c->(301), 3, 'http_enum 3xx -> 3' );
    is( $c->(404), 4, 'http_enum 4xx -> 4' );
    is( $c->(503), 5, 'http_enum 5xx -> 5' );
    is( $c->('200'), 2, 'http_enum accepts a numeric string' );
    is( $c->(700), 7, 'http_enum lax lets out-of-range through' );
    eval { $c->('nope') };
    like( $@, qr/not a numeric status code/, 'http_enum croaks on non-numeric' );

    my $s = $M->build( { munger => 'http_enum', strict => 1 } );
    is( $s->(404), 4, 'http_enum strict passes an in-range code' );
    is( $s->(100), 1, 'http_enum strict passes the low boundary' );
    is( $s->(599), 5, 'http_enum strict passes the high boundary' );
    eval { $s->(700) };
    like( $@, qr/out of range/, 'http_enum strict rejects a high code' );
    eval { $s->(99) };
    like( $@, qr/out of range/, 'http_enum strict rejects a low code' );
}

# ---- smtp_enum ------------------------------------------------------------
{
    my $c = $M->build( { munger => 'smtp_enum' } );
    is( $c->(220), 2, 'smtp_enum 2yz -> 2' );
    is( $c->(354), 3, 'smtp_enum 3yz -> 3' );
    is( $c->(450), 4, 'smtp_enum 4yz -> 4' );
    is( $c->(550), 5, 'smtp_enum 5yz -> 5' );
    is( $c->(700), 7, 'smtp_enum lax lets out-of-range through' );
    eval { $c->('nope') };
    like( $@, qr/smtp_enum munger.*not a numeric status code/,
        'smtp_enum croaks on non-numeric' );

    my $s = $M->build( { munger => 'smtp_enum', strict => 1 } );
    is( $s->(200), 2, 'smtp_enum strict passes the low boundary' );
    is( $s->(599), 5, 'smtp_enum strict passes the high boundary' );
    eval { $s->(150) };
    like( $@, qr/out of range \(200-599\)/,
        'smtp_enum strict rejects 1xx (unused in SMTP)' );
    eval { $s->(700) };
    like( $@, qr/out of range \(200-599\)/, 'smtp_enum strict rejects a high code' );
}

# ---- sip_enum -------------------------------------------------------------
{
    my $c = $M->build( { munger => 'sip_enum' } );
    is( $c->(100), 1, 'sip_enum 1xx -> 1' );
    is( $c->(200), 2, 'sip_enum 2xx -> 2' );
    is( $c->(302), 3, 'sip_enum 3xx -> 3' );
    is( $c->(404), 4, 'sip_enum 4xx -> 4' );
    is( $c->(503), 5, 'sip_enum 5xx -> 5' );
    is( $c->(603), 6, 'sip_enum 6xx -> 6 (global failure)' );

    my $s = $M->build( { munger => 'sip_enum', strict => 1 } );
    is( $s->(699), 6, 'sip_enum strict passes the 6xx high boundary' );
    eval { $s->(700) };
    like( $@, qr/out of range \(100-699\)/, 'sip_enum strict rejects >= 700' );
    eval { $s->(99) };
    like( $@, qr/out of range \(100-699\)/, 'sip_enum strict rejects < 100' );
}

# ---- freq_map -------------------------------------------------------------
{
    # defaults: neg_log_prob, smoothing 1, unseen 'rare'. counts a:3 b:1,
    # total 4, V 2 => denom = 4 + 1*(2+1) = 7.
    my $r = $M->build( { munger => 'freq_map', counts => { a => 3, b => 1 } } );
    ok( $r->('b') > $r->('a'), 'freq_map: rarer value is more surprising' );
    ok( $r->('zzz') > $r->('b'), 'freq_map: unseen is the most surprising' );
    ok( abs( $r->('zzz') - log(7) ) < 1e-9, 'freq_map unseen surprisal = -ln(1/7)' );
    ok( abs( $r->('a') - -log( 4 / 7 ) ) < 1e-9, 'freq_map seen surprisal value' );

    my $cnt = $M->build(
        { munger => 'freq_map', counts => { a => 3, b => 1 }, mode => 'count' } );
    is( $cnt->('a'),   3, 'freq_map count mode' );
    is( $cnt->('zzz'), 0, 'freq_map count mode: unseen -> 0' );

    # raw probability (no smoothing): a:3 b:1 total 4 => p(a)=0.75.
    my $freq = $M->build( {
        munger => 'freq_map', counts => { a => 3, b => 1 },
        mode   => 'freq', smoothing => 0,
    } );
    ok( abs( $freq->('a') - 0.75 ) < 1e-9, 'freq_map raw freq, no smoothing' );
    is( $freq->('zzz'), 0, 'freq_map freq: unseen with no smoothing -> 0' );

    my $num = $M->build( {
        munger => 'freq_map', counts => { a => 3 }, unseen => -1, mode => 'count',
    } );
    is( $num->('zzz'), -1, 'freq_map numeric unseen default' );

    # explicit total (pruned tail) larger than the sum is honored.
    my $pruned = $M->build(
        { munger => 'freq_map', counts => { a => 3 }, total => 100 } );
    ok( $pruned->('zzz') > $pruned->('a'),
        'freq_map with pruned tail still ranks unseen rarest' );

    # validation
    eval { $M->build( { munger => 'freq_map', counts => {} } ) };
    like( $@, qr/non-empty 'counts'/, 'freq_map rejects empty counts' );
    eval { $M->build( { munger => 'freq_map', counts => { a => 3 }, total => 1 } ) };
    like( $@, qr/must be >= sum/, 'freq_map rejects total < sum' );
    eval { $M->build( { munger => 'freq_map', counts => { a => 3 }, mode => 'bogus' } ) };
    like( $@, qr/unknown mode 'bogus'/, 'freq_map rejects bad mode' );
    eval {
        $M->build( { munger => 'freq_map', counts => { a => 3 }, smoothing => 0 } );
    };
    like( $@, qr/needs smoothing > 0/,
        'freq_map neg_log_prob + rare + no smoothing croaks' );

    # size guard warns
    my @warn;
    local $SIG{__WARN__} = sub { push @warn, "@_" };
    local $Algorithm::Classifier::IsolationForest::Zorita::Mungers::FREQ_MAP_WARN_KEYS
        = 1;
    $M->build(
        { munger => 'freq_map', counts => { a => 1, b => 2 }, mode => 'count' } );
    ok( ( grep { /bloats info\.json/ } @warn ), 'freq_map warns on oversized table' );
}

# ---- bool -----------------------------------------------------------------
{
    my $c = $M->build( { munger => 'bool' } );
    is( $c->('anything'), 1, 'bool truthy' );
    is( $c->(0),          0, 'bool falsey' );

    my $t = $M->build( { munger => 'bool', true => [qw(yes Y 1)] } );
    is( $t->('yes'), 1, 'bool true-list hit' );
    is( $t->('no'),  0, 'bool true-list miss' );
    is( $t->(undef), 0, 'bool true-list undef' );
}

# ---- length ---------------------------------------------------------------
{
    my $c = $M->build( { munger => 'length' } );
    is( $c->('abcd'),  4, 'length counts characters' );
    is( $c->(''),      0, 'length of empty string' );
    is( $c->(undef),   0, 'length of undef is 0' );
    is( $c->(12345),   5, 'length stringifies numbers' );
    # character length, not byte length: "cafe" with a combined e-acute is 4.
    is( $c->("caf\x{e9}"), 4, 'length is characters, not UTF-8 bytes' );
}

# ---- entropy --------------------------------------------------------------
{
    my $c = $M->build( { munger => 'entropy' } );
    is( $c->(''),     0, 'entropy of empty string is 0' );
    is( $c->('aaaa'), 0, 'entropy of a single repeated symbol is 0' );
    ok( abs( $c->('ab') - 1 ) < 1e-9,   'entropy of two equiprobable symbols is 1 bit' );
    ok( abs( $c->('abcd') - 2 ) < 1e-9, 'entropy of four equiprobable symbols is 2 bits' );
    # high-entropy DGA-ish name scores well above a real word.
    ok( $c->('x7f3q9zk2v') > $c->('google'), 'random string out-scores a word' );

    # XS and PP must agree (whichever built).
    no strict 'refs';
    my $ns = 'Algorithm::Classifier::IsolationForest::Zorita::Mungers';
    my $pp = \&{"${ns}::_entropy_pp"};
    for my $s ( '', 'a', 'ab', 'hello world', 'x7f3q9zk2v', "sn\x{f8}wman" ) {
        ok( abs( $c->($s) - $pp->($s) ) < 1e-12, "entropy XS==PP for '$s'" );
    }
}

# ---- char -----------------------------------------------------------------
{
    my $cnt = $M->build( { munger => 'char', class => 'non_ascii' } );
    is( $cnt->('abc'),        0, 'char non_ascii count on ASCII' );
    is( $cnt->("a\x{e9}b\x{ff}"), 2, 'char non_ascii counts codepoints > 127' );

    my $ratio = $M->build( { munger => 'char', class => 'non_alnum', mode => 'ratio' } );
    is( $ratio->('abcd'),      0,    'char non_alnum ratio, all alnum' );
    is( $ratio->('ab..'),      0.5,  'char non_alnum ratio, half punct' );
    is( $ratio->(''),          0,    'char ratio of empty string is 0' );

    my $dig = $M->build( { munger => 'char', class => 'digit' } );
    is( $dig->('a1b2c3'), 3, 'char digit count' );

    # space and punct ride the regex (not tr///) so their \s / [[:punct:]]
    # semantics are preserved -- cover that path.
    my $sp = $M->build( { munger => 'char', class => 'space' } );
    is( $sp->("a b\tc\nd"), 3, 'char space counts blank, tab, newline' );
    my $pu = $M->build( { munger => 'char', class => 'punct' } );
    is( $pu->('a,b.c!'), 3, 'char punct count' );

    eval { $M->build( { munger => 'char', class => 'bogus' } ) };
    like( $@, qr/unknown class 'bogus'/, 'char rejects unknown class' );
    eval { $M->build( { munger => 'char', class => 'digit', mode => 'nope' } ) };
    like( $@, qr/'mode' must be/, 'char rejects bad mode' );
}

# ---- count ----------------------------------------------------------------
{
    my $slashes = $M->build( { munger => 'count', of => '/' } );
    is( $slashes->('/a/b/c'), 3, 'count slashes (path depth)' );
    is( $slashes->('nopath'), 0, 'count with no matches' );

    my $labels = $M->build( { munger => 'count', of => '.', plus => 1 } );
    is( $labels->('a.b.evil.com'), 4, 'count dots + 1 (label_count)' );
    is( $labels->('localhost'),    1, 'count label_count of a single label' );

    # multi-char needles count non-overlapping occurrences (m//g semantics)
    my $aa = $M->build( { munger => 'count', of => 'aa' } );
    is( $aa->('aaaa'),  2, 'count is non-overlapping' );
    is( $aa->('aaaaa'), 2, 'count leftover tail does not match' );

    eval { $M->build( { munger => 'count' } ) };
    like( $@, qr/non-empty 'of'/, 'count requires of' );
}

# ---- bucket ---------------------------------------------------------------
{
    my $port = $M->build( { munger => 'bucket', bounds => [ 1024, 49152 ] } );
    is( $port->(80),    0, 'bucket well-known port' );
    is( $port->(1023),  0, 'bucket just below first bound' );
    is( $port->(1024),  1, 'bucket at first bound is registered' );
    is( $port->(8080),  1, 'bucket registered port' );
    is( $port->(49152), 2, 'bucket at second bound is ephemeral' );
    is( $port->(60000), 2, 'bucket ephemeral port' );

    eval { $M->build( { munger => 'bucket', bounds => [] } ) };
    like( $@, qr/non-empty 'bounds'/, 'bucket rejects empty bounds' );
    eval { $M->build( { munger => 'bucket', bounds => [ 5, 5 ] } ) };
    like( $@, qr/strictly ascending/, 'bucket rejects non-ascending bounds' );
}

# ---- ftp_enum -------------------------------------------------------------
{
    my $c = $M->build( { munger => 'ftp_enum' } );
    is( $c->(220), 2, 'ftp_enum 2yz -> 2' );
    is( $c->(530), 5, 'ftp_enum 5yz -> 5' );
    my $s = $M->build( { munger => 'ftp_enum', strict => 1 } );
    eval { $s->(700) };
    like( $@, qr/out of range \(100-599\)/, 'ftp_enum strict rejects >= 700' );
}

# ---- scale ----------------------------------------------------------------
{
    my $c = $M->build( { munger => 'scale', min => 0, max => 10 } );
    is( $c->(5),  0.5, 'scale midpoint' );
    is( $c->(15), 1.5, 'scale unclamped overshoot' );

    my $cl = $M->build( { munger => 'scale', min => 0, max => 10, clamp => 1 } );
    is( $cl->(15), 1, 'scale clamps high' );
    is( $cl->(-5), 0, 'scale clamps low' );

    eval { $M->build( { munger => 'scale', min => 3, max => 3 } ) };
    like( $@, qr/must differ/, 'scale rejects zero range' );
}

# ---- zscore ---------------------------------------------------------------
{
    my $c = $M->build( { munger => 'zscore', mean => 10, std => 2 } );
    is( $c->(12), 1,  'zscore +1 sd' );
    is( $c->(6),  -2, 'zscore -2 sd' );
    eval { $M->build( { munger => 'zscore', mean => 0, std => 0 } ) };
    like( $@, qr/non-zero/, 'zscore rejects zero std' );
}

# ---- log ------------------------------------------------------------------
{
    my $ln = $M->build( { munger => 'log' } );
    is( $ln->(1), 0, 'ln(1) == 0' );

    my $l1p = $M->build( { munger => 'log', offset => 1 } );
    is( $l1p->(0), 0, 'log offset lets 0 through' );

    my $l10 = $M->build( { munger => 'log', base => 10, offset => 0 } );
    ok( abs( $l10->(1000) - 3 ) < 1e-9, 'log base 10 of 1000 == 3' );

    eval { $ln->(0) };
    like( $@, qr/must be > 0/, 'log croaks on non-positive' );
}

# ---- clamp ----------------------------------------------------------------
{
    my $c = $M->build( { munger => 'clamp', min => 0, max => 100 } );
    is( $c->(-5),  0,   'clamp low' );
    is( $c->(250), 100, 'clamp high' );
    is( $c->(50),  50,  'clamp passthrough' );

    my $lo = $M->build( { munger => 'clamp', min => 0 } );
    is( $lo->(-1), 0, 'clamp one-sided min' );
    is( $lo->(999), 999, 'clamp one-sided leaves high alone' );

    eval { $M->build( { munger => 'clamp' } ) };
    like( $@, qr/at least one/, 'clamp needs a bound' );
}

# ---- datetime -------------------------------------------------------------
SKIP: {
    eval { require Time::Piece; 1 }
        or skip 'Time::Piece not available', 3;

    my $ep = $M->build(
        { munger => 'datetime', format => '%Y-%m-%dT%H:%M:%S', part => 'epoch' } );
    # 2026-07-06T12:00:00 UTC via strptime (Time::Piece strptime is UTC)
    my $t = Time::Piece->strptime( '2026-07-06T12:00:00', '%Y-%m-%dT%H:%M:%S' );
    is( $ep->('2026-07-06T12:00:00'), $t->epoch, 'datetime epoch part' );

    my $hr = $M->build(
        { munger => 'datetime', format => '%Y-%m-%dT%H:%M:%S', part => 'hour' } );
    is( $hr->('2026-07-06T12:00:00'), 12, 'datetime hour part' );

    my $fd = $M->build(
        { munger => 'datetime', format => '%Y-%m-%dT%H:%M:%S', part => 'frac_day' } );
    is( $fd->('2026-07-06T12:00:00'), 0.5, 'datetime frac_day at noon' );

    my $fw = $M->build(
        { munger => 'datetime', format => '%Y-%m-%dT%H:%M:%S', part => 'frac_week' } );
    # 2026-07-05 is a Sunday (wday 0): midnight Sunday is the week origin.
    is( $fw->('2026-07-05T00:00:00'), 0, 'datetime frac_week at Sunday midnight' );
    # 2026-07-06 is Monday (wday 1) noon: (1*86400 + 43200)/604800.
    is( $fw->('2026-07-06T12:00:00'), ( 86400 + 43200 ) / 604800,
        'datetime frac_week at Monday noon' );

    # cyclic parts: noon is frac_day 0.5 -> sin(pi)=0, cos(pi)=-1.
    my $sd = $M->build(
        { munger => 'datetime', format => '%Y-%m-%dT%H:%M:%S', part => 'sin_day' } );
    my $cd = $M->build(
        { munger => 'datetime', format => '%Y-%m-%dT%H:%M:%S', part => 'cos_day' } );
    ok( abs( $sd->('2026-07-06T12:00:00') - 0 ) < 1e-9,  'sin_day at noon ~ 0' );
    ok( abs( $cd->('2026-07-06T12:00:00') + 1 ) < 1e-9,  'cos_day at noon ~ -1' );
    # continuity across midnight: sin/cos barely move over a one-minute wrap.
    # a 60s wrap moves sin by ~2*pi*(60/86400) ~ 0.0044, vs the ~1.0 jump
    # frac_day would show at the same seam.
    my $near_mid_a = $sd->('2026-07-06T23:59:30');
    my $near_mid_b = $sd->('2026-07-07T00:00:30');
    ok( abs( $near_mid_a - $near_mid_b ) < 1e-2,
        'sin_day is continuous across midnight' );

    my $cw = $M->build(
        { munger => 'datetime', format => '%Y-%m-%dT%H:%M:%S', part => 'cos_week' } );
    # Sunday midnight is frac_week 0 -> cos(0) = 1.
    ok( abs( $cw->('2026-07-05T00:00:00') - 1 ) < 1e-9, 'cos_week at week origin ~ 1' );
}

# ---- hash (XS or PP; both must agree with these fixed FNV-1a values) -------
{
    diag( 'hash munger path: HAVE_XS = '
            . $Algorithm::Classifier::IsolationForest::Zorita::Mungers::HAVE_XS );

    my $raw = $M->build( { munger => 'hash' } );
    # Known FNV-1a 32-bit vectors.
    is( $raw->(''),      2166136261, 'fnv1a empty string' );
    is( $raw->('a'),     3826002220, 'fnv1a "a"' );
    is( $raw->('foobar'), 3214735720, 'fnv1a "foobar"' );

    my $b = $M->build( { munger => 'hash', buckets => 100 } );
    ok( $b->('anything') >= 0 && $b->('anything') < 100, 'hash respects buckets' );

    # Same key + same bucket count is stable; seed decorrelates.
    my $s0 = $M->build( { munger => 'hash', buckets => 1_000_000, seed => 0 } );
    my $s7 = $M->build( { munger => 'hash', buckets => 1_000_000, seed => 7 } );
    isnt( $s0->('shared'), $s7->('shared'), 'seed changes the hash' );

    eval { $M->build( { munger => 'hash', buckets => 0 } ) };
    like( $@, qr/positive integer/, 'hash rejects zero buckets' );
}

# ---- build_all + error surface -------------------------------------------
{
    my $by_tag = $M->build_all(
        {
            method => { munger => 'enum', map => { GET => 0, POST => 1 } },
            bytes  => { munger => 'log', offset => 1 },
        }
    );
    is( $by_tag->{method}->('POST'), 1, 'build_all wires method' );
    is( $by_tag->{bytes}->(0),       0, 'build_all wires bytes' );

    is_deeply( $M->build_all(undef), {}, 'build_all(undef) is empty' );

    eval { $M->build( { munger => 'bogus' }, 'sometag' ) };
    like( $@, qr/unknown munger 'bogus' for tag 'sometag'/,
        'unknown munger names the tag' );
}

done_testing;
