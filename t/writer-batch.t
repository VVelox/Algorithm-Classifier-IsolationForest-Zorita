#!perl
# write_rows(): batched appends -- one lock per batch, all-or-nothing
# validation, mixed named/positional records, munging applied.
use 5.006;
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);

use Algorithm::Classifier::IsolationForest::Zorita;
use Algorithm::Classifier::IsolationForest::Zorita::Writer;

my $WRITER_CLASS = 'Algorithm::Classifier::IsolationForest::Zorita::Writer';

my @TAGS = qw(bytes method status);

sub new_writer {
    my %info_extra = @_;
    my $zorita     = Algorithm::Classifier::IsolationForest::Zorita->new(
        basedir => tempdir( CLEANUP => 1 ) );
    $zorita->write_info(
        slug => 'myapp',
        set  => 'http-logs',
        info => { tags => [@TAGS], 'days_back' => 7, %info_extra },
    );
    return $WRITER_CLASS->new(
        zorita => $zorita, slug => 'myapp', set => 'http-logs', writer => 'web01' );
}

sub slurp_lines {
    my $file = shift;
    open my $fh, '<', $file or die "cannot read $file: $!";
    my @lines = <$fh>;
    close $fh;
    chomp @lines;
    return @lines;
}

# ---- a batch of named records, munged, header once --------------------------
{
    my $writer = new_writer(
        mungers => { method => { munger => 'enum', map => { GET => 0, POST => 1 } } },
    );
    my $file = $writer->write_rows( [
        { bytes => 100, method => 'GET',  status => 200 },
        { bytes => 250, method => 'POST', status => 201 },
        { bytes => 999, method => 'GET',  status => 404 },
    ] );

    my @lines = slurp_lines($file);
    is( scalar @lines, 4, 'header + three rows' );
    is( $lines[0], 'bytes,method,status', 'header is the tag names' );
    is_deeply(
        [ @lines[ 1 .. 3 ] ],
        [ '100,0,200', '250,1,201', '999,0,404' ],
        'batch rows munged and in order',
    );

    # a second batch must not re-emit the header
    $writer->write_rows( [ { bytes => 1, method => 'GET', status => 200 } ] );
    is( scalar( slurp_lines($file) ), 5, 'later batch appends without a header' );
}

# ---- mixed hashref / arrayref records ---------------------------------------
{
    my $writer = new_writer();
    my $file   = $writer->write_rows( [
        { bytes => 1, method => 2, status => 3 },
        [ 4, 5, 6 ],
    ] );
    my @lines = slurp_lines($file);
    is_deeply( [ @lines[ 1, 2 ] ], [ '1,2,3', '4,5,6' ],
        'named and positional records mix in one batch' );
}

# ---- all-or-nothing: a bad record aborts the whole batch --------------------
{
    my $writer = new_writer();
    my $file   = $writer->write_rows( [ [ 1, 2, 3 ] ] );    # seed one good row

    eval {
        $writer->write_rows( [
            [ 7, 8, 9 ],
            [ 10, 'not numeric', 12 ],
        ] );
    };
    like( $@, qr/row 1: field 1 .* is not clean numeric data/,
        'bad record croaks naming the row and field' );
    is( scalar( slurp_lines($file) ), 2,
        'nothing from the failed batch was appended' );

    eval { $writer->write_rows( [ [ 1, 2 ] ] ) };
    like( $@, qr/row has 2 fields/, 'arity is checked per record' );

    eval { $writer->write_rows( [ 'scalar' ] ) };
    like( $@, qr/each record must be a hashref or an arrayref/,
        'non-ref record rejected' );

    eval { $writer->write_rows( { not => 'an array' } ) };
    like( $@, qr/requires an arrayref of records/, 'non-arrayref batch rejected' );
}

# ---- empty batch is a no-op --------------------------------------------------
{
    my $writer = new_writer();
    is( $writer->write_rows( [] ), undef, 'empty batch returns undef' );
    ok( !-e $writer->path, 'empty batch creates no file' );
}

done_testing;
