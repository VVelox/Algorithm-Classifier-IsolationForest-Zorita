#!perl
# Roll-ups and read-back sources, previously untested end to end: combine_hour
# merges writer files under one fresh header (dropping junk lines, REPLACING
# rather than appending), combine_day concatenates the hours' combined.csv
# files (skipping hours that have none), and read_back prefers combined.csv
# over live writer files, uses daily.csv only for fully-passed days, and
# honors the hours window.
use 5.006;
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec;

use Algorithm::Classifier::IsolationForest::Zorita;
use Algorithm::Classifier::IsolationForest::Zorita::Writer;

my $WRITER_CLASS = 'Algorithm::Classifier::IsolationForest::Zorita::Writer';

# One fixed "now": every write and read_back below passes time explicitly, so
# nothing here can flake on an hour rolling over mid-test.
my $NOW = time;

my $z = Algorithm::Classifier::IsolationForest::Zorita->new( basedir => tempdir( CLEANUP => 1 ) );
$z->write_info(
	slug => 'myapp',
	set  => 'logs',
	info => { tags => [qw(a b)], 'days_back' => 7 },
);

my ( $DATE, $HOUR ) = ( $z->datestamp($NOW), $z->hourstamp($NOW) );

sub slurp_lines {
	my ($file) = @_;
	open my $fh, '<', $file or die "cannot read $file: $!";
	my @lines = <$fh>;
	close $fh;
	chomp @lines;
	return @lines;
}

sub drop_raw {
	my ( $path, $content ) = @_;
	open my $fh, '>', $path or die "cannot write $path: $!";
	print {$fh} $content;
	close $fh;
}

sub sorted_rows {
	return [ sort { $a->[0] <=> $b->[0] || $a->[1] <=> $b->[1] } @{ $_[0] } ];
}

# ---- combine_hour: one fresh header over every writer file ------------------
{
	for my $w (qw(w1 w2)) {
		my $writer = $WRITER_CLASS->new(
			zorita => $z,
			slug   => 'myapp',
			set    => 'logs',
			writer => $w
		);
		$writer->write( [ 1, 2 ], time => $NOW ) if $w eq 'w1';
		$writer->write( [ 3, 4 ], time => $NOW ) if $w eq 'w1';
		$writer->write( [ 5, 6 ], time => $NOW ) if $w eq 'w2';
	} ## end for my $w (qw(w1 w2))

	my $combined = $z->combine_hour(
		slug => 'myapp',
		set  => 'logs',
		date => $DATE,
		hour => $HOUR
	);
	ok( -f $combined, 'combine_hour writes combined.csv' );
	is_deeply(
		[ slurp_lines($combined) ],
		[ 'a,b', '1,2', '3,4', '5,6' ],
		'one fresh header, then every writer row, per-file headers dropped'
	);

	# A rogue writer file full of junk: only its clean numeric line survives,
	# and re-running REPLACES the output (no duplicated rows from the first
	# pass) -- combined.csv is rebuilt, not appended to.
	my $hdir = $z->hour_dir(
		slug => 'myapp',
		set  => 'logs',
		date => $DATE,
		hour => $HOUR
	);
	drop_raw( File::Spec->catfile( $hdir, 'w.rogue.csv' ), "a,b\nnot,numeric\n7, 8\n\n9,9\n" );
	$z->combine_hour( slug => 'myapp', set => 'logs', date => $DATE, hour => $HOUR );
	is_deeply(
		[ slurp_lines($combined) ],
		[ 'a,b', '9,9', '1,2', '3,4', '5,6' ],
		'junk lines are dropped and the rebuild replaces, never appends'
	);

	eval { $z->combine_hour( slug => 'myapp', set => 'logs', date => '1999-01-01', hour => '00' ) };
	like( $@, qr/hour dir does not exist/, 'combine_hour croaks on a missing hour dir' );
}

# ---- combine_day: hours with a combined.csv, in order, others skipped -------
# A fully synthetic past date keeps this independent of the wall clock.
{
	my $ddir = $z->date_dir( slug => 'myapp', set => 'logs', date => '2000-01-01' );
	for my $h (qw(05 06 07)) {
		make_path( File::Spec->catdir( $ddir, $h ) );
	}
	drop_raw( File::Spec->catfile( $ddir, '05', 'combined.csv' ), "a,b\n10,10\n" );
	drop_raw( File::Spec->catfile( $ddir, '06', 'combined.csv' ), "a,b\n11,11\n" );
	# hour 07 has only a live writer file -- combine_day must skip it, since
	# rolling up live files is combine_hour's job.
	drop_raw( File::Spec->catfile( $ddir, '07', 'w.live.csv' ), "a,b\n12,12\n" );

	my $daily = $z->combine_day( slug => 'myapp', set => 'logs', date => '2000-01-01' );
	is_deeply(
		[ slurp_lines($daily) ],
		[ 'a,b', '10,10', '11,11' ],
		'combine_day concatenates hour combined.csv files and skips hours without one'
	);

	# an hour dir that exists but is empty contributes nothing and breaks nothing
	make_path( File::Spec->catdir( $ddir, '08' ) );
	$z->combine_hour( slug => 'myapp', set => 'logs', date => '2000-01-01', hour => '08' );
	is_deeply( [ slurp_lines( File::Spec->catfile( $ddir, '08', 'combined.csv' ) ) ],
		['a,b'], 'combine_hour on an empty hour yields a header-only combined.csv' );
}

# ---- read_back: the hours window includes and excludes correctly ------------
{
	my $old = $WRITER_CLASS->new(
		zorita => $z,
		slug   => 'myapp',
		set    => 'logs',
		writer => 'w1'
	);
	$old->write( [ 7, 7 ], time => $NOW - 3 * 3600 );

	my $near = $z->read_back(
		slug  => 'myapp',
		set   => 'logs',
		hours => 1,
		time  => $NOW
	);
	is_deeply(
		sorted_rows($near),
		[ [ 1, 2 ], [ 3, 4 ], [ 5, 6 ], [ 9, 9 ] ],
		'hours => 1 sees the current hour only (via its combined.csv)'
	);

	my $wide = $z->read_back(
		slug  => 'myapp',
		set   => 'logs',
		hours => 4,
		time  => $NOW
	);
	is_deeply(
		sorted_rows($wide),
		[ [ 1, 2 ], [ 3, 4 ], [ 5, 6 ], [ 7, 7 ], [ 9, 9 ] ],
		'hours => 4 adds the row from three hours ago'
	);
}

# ---- read_back: combined.csv is preferred, writer files are the fallback ----
{
	my $hdir = $z->hour_dir(
		slug => 'myapp',
		set  => 'logs',
		date => $DATE,
		hour => $HOUR
	);
	my $combined = File::Spec->catfile( $hdir, 'combined.csv' );

	# hand-edit combined.csv: if it is read at all, it is read INSTEAD of the
	# writer files that still hold the original rows.
	drop_raw( $combined, "a,b\n99,99\n" );
	my $rows = $z->read_back(
		slug  => 'myapp',
		set   => 'logs',
		hours => 1,
		time  => $NOW
	);
	is_deeply( $rows, [ [ 99, 99 ] ], 'an existing combined.csv shadows the live writer files' );

	# without it, the hour falls back to merging every w.*.csv
	unlink $combined or die "cannot unlink $combined: $!";
	$rows = $z->read_back(
		slug  => 'myapp',
		set   => 'logs',
		hours => 1,
		time  => $NOW
	);
	is_deeply(
		sorted_rows($rows),
		[ [ 1, 2 ], [ 3, 4 ], [ 5, 6 ], [ 9, 9 ] ],
		'no combined.csv: the hour merges its writer files (junk still dropped)'
	);
}

# ---- read_back: daily.csv fast path for fully-passed, fully-covered days ----
{
	my $d2   = $z->datestamp( $NOW - 2 * 86400 );
	my $ddir = $z->date_dir( slug => 'myapp', set => 'logs', date => $d2 );
	make_path( File::Spec->catdir( $ddir, '05' ) );
	drop_raw( File::Spec->catfile( $ddir, 'daily.csv' ), "a,b\n42,42\n" );
	drop_raw( File::Spec->catfile( $ddir, '05', 'combined.csv' ), "a,b\n66,66\n" );

	# Replicate read_back's slot walk for $d2: on a DST-transition day the
	# window covers fewer than 24 distinct hours and the daily fast path is
	# (correctly) not taken, so only assert it on a normal day.
	my %hours;
	for ( my $t = $NOW - 72 * 3600; $t <= $NOW; $t += 3600 ) {
		$hours{ $z->hourstamp($t) } = 1 if $z->datestamp($t) eq $d2;
	}

SKIP: {
		skip 'DST transition day: daily fast path not applicable', 2
			unless keys %hours == 24;

		my $rows = $z->read_back(
			slug  => 'myapp',
			set   => 'logs',
			hours => 72,
			time  => $NOW
		);
		my %seen = map { join( ',', @$_ ) => 1 } @$rows;
		ok( $seen{'42,42'},  'a fully-covered past day is read from daily.csv' );
		ok( !$seen{'66,66'}, '...and its hourly combined.csv is not read on top of it' );
	} ## end SKIP:
}

# ---- read_back: empty window and missing hours config -----------------------
{
	$z->write_info(
		slug => 'myapp',
		set  => 'fresh',
		info => { tags => [qw(a b)], 'days_back' => 7 },
	);
	is_deeply( $z->read_back( slug => 'myapp', set => 'fresh', hours => 5, time => $NOW ),
		[], 'a set with no data reads back an empty window' );

	$z->write_info( slug => 'myapp', set => 'nodays', info => { tags => [qw(a b)] } );
	eval { $z->read_back( slug => 'myapp', set => 'nodays', time => $NOW ) };
	like( $@, qr/no 'hours' given and no 'days_back'/, 'read_back croaks without hours or days_back' );
}

# ---- explicit date/hour arguments are shape-checked --------------------------
# datestamp/hourstamp always render these shapes; an explicit argument must
# match them too, so a mistyped ('2026-7-5') or hostile ('../..') value can
# never name a directory outside the set.
{
	for my $bad ( '../..', '2026-7-5', '2026-07-051', '2026-07-05/x' ) {
		eval { $z->date_dir( slug => 'myapp', set => 'logs', date => $bad ) };
		like( $@, qr/invalid date/, "date_dir rejects '$bad'" );
	}
	for my $bad ( '7', '..', 'xx', '070' ) {
		eval { $z->hour_dir( slug => 'myapp', set => 'logs', date => '2000-01-01', hour => $bad ); };
		like( $@, qr/invalid hour/, "hour_dir rejects '$bad'" );
	}

	eval { $z->combine_hour( slug => 'myapp', set => 'logs', date => '../../evil', hour => '00' ) };
	like( $@, qr/invalid date/, 'combine_hour cannot be aimed outside the set' );

	is(
		$z->date_dir( slug => 'myapp', set => 'logs', date => '2000-01-01' ),
		File::Spec->catdir( $z->set_dir( slug => 'myapp', set => 'logs' ), '2000-01-01' ),
		'a well-formed explicit date still resolves'
	);
}

done_testing;
