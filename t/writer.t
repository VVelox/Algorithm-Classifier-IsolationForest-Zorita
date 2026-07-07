#!perl
# Functional tests for the Writer: construction/validation, arity + numeric
# enforcement, header-once behavior, ordered vs named writes, and path().
use 5.006;
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);

use Algorithm::Classifier::IsolationForest::Zorita;
use Algorithm::Classifier::IsolationForest::Zorita::Writer;

my $WRITER_CLASS = 'Algorithm::Classifier::IsolationForest::Zorita::Writer';

# ----------------------------------------------------------------------------
# Fixture: a basedir with one set whose info.json declares three tags. The tag
# order (bytes, duration, status) is deliberately not alphabetical so we can
# tell an ordered write from a re-sorted one.
# ----------------------------------------------------------------------------
my @TAGS = qw(bytes duration status);

sub fresh_zorita {
	my $basedir = tempdir( CLEANUP => 1 );
	my $zorita  = Algorithm::Classifier::IsolationForest::Zorita->new( basedir => $basedir );
	$zorita->write_info(
		slug => 'myapp',
		set  => 'http-logs',
		info => { tags => [@TAGS], 'days_back' => 7 },
	);
	return $zorita;
} ## end sub fresh_zorita

sub new_writer {
	my $zorita = shift;
	return $WRITER_CLASS->new(
		zorita => $zorita,
		slug   => 'myapp',
		set    => 'http-logs',
		writer => 'web01',
	);
}

# read a writer file into a list of chomped lines
sub slurp_lines {
	my $file = shift;
	open my $fh, '<', $file or die "cannot read $file: $!";
	my @lines = <$fh>;
	close $fh;
	chomp @lines;
	return @lines;
}

# ----------------------------------------------------------------------------
# Construction and name validation
# ----------------------------------------------------------------------------
{
	my $zorita = fresh_zorita();
	my $writer = new_writer($zorita);
	isa_ok( $writer, $WRITER_CLASS, 'new() returns a writer' );

	is( $writer->filename, 'w.web01.csv', 'filename is w.$writer.csv' );
	is_deeply( $writer->tags, [@TAGS], 'tags come back in info.json order' );

	for my $field (qw(slug set writer)) {
		my %args = (
			zorita => $zorita,
			slug   => 'myapp',
			set    => 'http-logs',
			writer => 'web01'
		);
		delete $args{$field};
		eval { $WRITER_CLASS->new(%args) };
		like( $@, qr/requires '$field'/, "new() croaks without '$field'" );
	} ## end for my $field (qw(slug set writer))

	eval {
		$WRITER_CLASS->new(
			zorita => $zorita,
			slug   => 'myapp',
			set    => 'http-logs',
			writer => 'bad name',    # space is illegal
		);
	};
	like( $@, qr/invalid writer/, 'new() croaks on an illegal writer name' );
}

# ----------------------------------------------------------------------------
# write(): header-once, arity, numeric enforcement, return value
# ----------------------------------------------------------------------------
{
	my $zorita = fresh_zorita();
	my $writer = new_writer($zorita);

	my $file = $writer->write( [ 1234, 0.08, 200 ] );
	ok( defined $file && -f $file, 'write() returns the file path and it exists' );

	my @lines = slurp_lines($file);
	is_deeply( \@lines, [ 'bytes,duration,status', '1234,0.08,200' ], 'first write emits header then the row' );

	my $file2 = $writer->write( [ 5678, 0.5, 404 ] );
	is( $file2, $file, 'second write targets the same hour file' );

	@lines = slurp_lines($file);
	is( scalar( grep { $_ eq 'bytes,duration,status' } @lines ), 1, 'header is written exactly once' );
	is_deeply(
		\@lines,
		[ 'bytes,duration,status', '1234,0.08,200', '5678,0.5,404' ],
		'second row is appended after the first'
	);

	# arity
	eval { $writer->write( [ 1, 2 ] ) };
	like( $@, qr/row has 2 fields but info\.json declares 3/, 'write() croaks when the row is too short' );
	eval { $writer->write( [ 1, 2, 3, 4 ] ) };
	like( $@, qr/row has 4 fields/, 'write() croaks when the row is too long' );

	eval { $writer->write('not an arrayref') };
	like( $@, qr/requires an arrayref/, 'write() croaks on a non-arrayref' );

	# numeric enforcement: each bad field must be rejected
	my %bad = (
		undef_field  => [ 1234, undef,    200 ],
		text_field   => [ 1234, 'oops',   200 ],
		space_field  => [ 1234, '0.08 ',  200 ],
		quoted_field => [ 1234, '"0.08"', 200 ],
	);
	for my $case ( sort keys %bad ) {
		eval { $writer->write( $bad{$case} ) };
		like( $@, qr/is not clean numeric data/, "write() rejects $case" );
	}

	# a rejected write must not have altered the file
	@lines = slurp_lines($file);
	is( scalar(@lines), 3, 'rejected writes did not append anything' );
}

# ----------------------------------------------------------------------------
# write_named(): reordering and missing-key handling
# ----------------------------------------------------------------------------
{
	my $zorita = fresh_zorita();
	my $writer = new_writer($zorita);

	# keys given in a different order than tags; must come out in tag order
	my $file = $writer->write_named( { status => 200, bytes => 1234, duration => 0.08 } );

	my @lines = slurp_lines($file);
	is( $lines[-1], '1234,0.08,200', 'write_named() reorders values into tag order' );

	eval { $writer->write_named( { bytes => 1, duration => 2 } ) };
	like( $@, qr/missing value for 'status'/, 'write_named() croaks on a missing field' );

	eval { $writer->write_named( [ 1, 2, 3 ] ) };
	like( $@, qr/requires a hashref/, 'write_named() croaks on a non-hashref' );
}

# ----------------------------------------------------------------------------
# path(): resolves without creating anything
# ----------------------------------------------------------------------------
{
	my $zorita = fresh_zorita();
	my $writer = new_writer($zorita);

	my $path = $writer->path;
	like( $path, qr{/w\.web01\.csv\z}, 'path() ends in the writer filename' );
	ok( !-e $path, 'path() does not create the file' );
}

done_testing();
