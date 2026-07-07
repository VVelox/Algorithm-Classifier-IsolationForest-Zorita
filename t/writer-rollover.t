#!perl
# Hourly rollover + path caching behavior. Uses the write(time => ...) override
# to drive the writer across hour boundaries deterministically, and pins the
# timezone to UTC so the expected $date/$hour path components are stable.
use 5.006;
use strict;
use warnings;

BEGIN { $ENV{TZ} = 'UTC'; }
use POSIX qw(tzset);
BEGIN { tzset() }

use Test::More;
use File::Temp qw(tempdir);

use Algorithm::Classifier::IsolationForest::Zorita;
use Algorithm::Classifier::IsolationForest::Zorita::Writer;

my $WRITER_CLASS = 'Algorithm::Classifier::IsolationForest::Zorita::Writer';
my @TAGS         = qw(bytes duration status);

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

sub slurp_lines {
	my $file = shift;
	open my $fh, '<', $file or die "cannot read $file: $!";
	my @lines = <$fh>;
	close $fh;
	chomp @lines;
	return @lines;
}

# Three moments under UTC:
#   $t_h10   2026-07-06 10:00:00  -> hour "10"
#   $t_h10b  2026-07-06 10:59:00  -> same hour "10", 59 minutes later
#   $t_h11   2026-07-06 11:00:00  -> hour "11"
my $t_h10  = 1783332000;       # 2026-07-06T10:00:00Z
my $t_h10b = $t_h10 + 3540;    # +59 min, still hour 10
my $t_h11  = $t_h10 + 3600;    # +60 min, hour 11

{
	my $zorita = fresh_zorita();
	my $writer = new_writer($zorita);

	my $file10  = $writer->write( [ 1, 0.1, 200 ], time => $t_h10 );
	my $file10b = $writer->write( [ 2, 0.2, 200 ], time => $t_h10b );
	my $file11  = $writer->write( [ 3, 0.3, 200 ], time => $t_h11 );

	like( $file10, qr{/2026-07-06/10/w\.web01\.csv\z}, 'first write lands in the 10:00 hour directory' );
	is( $file10b, $file10, 'a later write in the same hour reuses the cached path' );
	like( $file11, qr{/2026-07-06/11/w\.web01\.csv\z}, 'a write in the next hour rolls onto a new directory' );
	isnt( $file11, $file10, 'the new hour is a different file' );

	# each hour file carries its own single header + only its own rows
	is_deeply(
		[ slurp_lines($file10) ],
		[ 'bytes,duration,status', '1,0.1,200', '2,0.2,200' ],
		'hour 10 file has one header and both of its rows'
	);
	is_deeply(
		[ slurp_lines($file11) ],
		[ 'bytes,duration,status', '3,0.3,200' ],
		'hour 11 file has its own fresh header and row'
	);

	# rolling BACK to an earlier hour (out-of-order time) must re-resolve the
	# cache and append to the existing file without re-emitting the header.
	my $again = $writer->write( [ 4, 0.4, 200 ], time => $t_h10 );
	is( $again, $file10, 'an out-of-order earlier time resolves back to hour 10' );
	is_deeply(
		[ slurp_lines($file10) ],
		[ 'bytes,duration,status', '1,0.1,200', '2,0.2,200', '4,0.4,200' ],
		'rolling back appends without a duplicate header'
	);
}

# A fresh writer object (simulating a process restart) pointed at an hour whose
# file already exists must NOT re-add the header.
{
	my $zorita = fresh_zorita();

	my $w1   = new_writer($zorita);
	my $file = $w1->write( [ 1, 0.1, 200 ], time => $t_h10 );

	my $w2 = new_writer($zorita);
	$w2->write( [ 2, 0.2, 200 ], time => $t_h10 );

	is_deeply(
		[ slurp_lines($file) ],
		[ 'bytes,duration,status', '1,0.1,200', '2,0.2,200' ],
		'a second writer object appends without re-adding the header'
	);
}

done_testing();
