#!perl
# End-to-end test of the two online subcommands: fork `zorita streamd` for an
# online set, then drive it with `zorita streamc` (command mode and stream mode)
# through App::Cmd::Tester. Needs the optional online model class and App::Cmd,
# so it skips without either.
use 5.006;
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use IO::Socket::UNIX ();
use POSIX            ();

BEGIN {
	eval { require Algorithm::Classifier::IsolationForest::Online; 1 }
		or plan skip_all => 'Algorithm::Classifier::IsolationForest::Online not installed';
	eval { require App::Cmd::Tester; App::Cmd::Tester->import('test_app'); 1 }
		or plan skip_all => "App::Cmd::Tester required: $@";
	require Algorithm::Classifier::IsolationForest::Zorita::Cmd;
}

use Algorithm::Classifier::IsolationForest::Zorita ();

my $APP  = 'Algorithm::Classifier::IsolationForest::Zorita::Cmd';
my $base = tempdir( CLEANUP => 1 );
my $z    = Algorithm::Classifier::IsolationForest::Zorita->new( basedir => $base, type => 'online' );
my %W    = ( slug => 'app', set => 's' );

$z->write_info(
	%W,
	info => {
		tags          => [qw(x y)],
		n_trees       => 20,
		window_size   => 128,
		growth        => 'adaptive',
		seed          => 42,
		contamination => 0.1,
		missing       => 'zero',
	},
);

# write a small helper file
sub spew {
	my ( $path, $text ) = @_;
	open my $fh, '>', $path or die "cannot write $path: $!";
	print {$fh} $text;
	close $fh;
	return $path;
}

# both subcommands are registered
my $cmds = test_app( $APP, ['commands'] );
like( $cmds->stdout, qr/\bstreamd\b/, 'commands lists streamd' );
like( $cmds->stdout, qr/\bstreamc\b/, 'commands lists streamc' );

# streamc against a daemon that is not running fails cleanly
my $down = test_app( $APP, [ '--basedir', $base, 'streamc', 'app', 's', '--ping' ] );
isnt( $down->exit_code, 0, 'streamc --ping fails when the daemon is down' );

# --- fork the daemon via `zorita streamd` -------------------------------------
my $log = File::Spec->catfile( $base, 'd.log' );
my $pid = fork();
defined $pid or plan skip_all => "fork failed: $!";
if ( !$pid ) {
	local @ARGV = ( '--basedir', $base, 'streamd', 'app', 's', '-f', '--log', $log, '--save-interval', '3600', );
	eval { $APP->run; 1 };
	POSIX::_exit(0);
}

# wait for the daemon to bind
my $sock = $z->socket_path(%W);
my $ready;
for ( 1 .. 50 ) {
	if ( -S $sock ) {
		my $probe = IO::Socket::UNIX->new( Peer => $sock );
		if ($probe) { $ready = 1; $probe->close; last; }
	}
	select undef, undef, undef, 0.1;    ## no critic (ProhibitSleepViaSelect)
}

SKIP: {
	skip 'daemon did not come up', 10 unless $ready;

	# command mode: ping / stats / save
	my $ping = test_app( $APP, [ '--basedir', $base, 'streamc', 'app', 's', '--ping' ] );
	is( $ping->exit_code, 0, 'streamc --ping exits 0' );
	like( $ping->stdout, qr/pong/, 'streamc --ping prints pong' );

	# stream mode: CSV in, "$score,$label" out, one line per row
	my $csv = spew( File::Spec->catfile( $base, 'rows.csv' ), "0.1,0.2\n0.3,0.4\n0.9,0.8\n" );
	my $sr  = test_app( $APP, [ '--basedir', $base, 'streamc', 'app', 's', '-i', $csv ] );
	is( $sr->exit_code, 0, 'streamc stream exits 0' );
	my @out = split /\n/, $sr->stdout;
	is( scalar @out, 3, 'one output line per input row' );
	like( $out[0], qr/\A[-\d.eE+]+,[01]\z/, 'each stream line is "score,label"' );

	my $stats = test_app( $APP, [ '--basedir', $base, 'streamc', 'app', 's', '--stats' ] );
	like( $stats->stdout, qr/seen/, 'streamc --stats reports seen' );

	my $save = test_app( $APP, [ '--basedir', $base, 'streamc', 'app', 's', '--save' ] );
	like( $save->stdout, qr/oiforest-.*\.json/, 'streamc --save prints the file name' );
	ok( -e $z->latest_path(%W), 'latest.json exists after --save' );

	# JSONL in, the daemon's reply JSON verbatim out
	my $jf = spew( File::Spec->catfile( $base, 'rows.jsonl' ), qq({"x":0.5,"y":0.6}\n[0.1,0.2]\n) );
	my $jr = test_app( $APP, [ '--basedir', $base, 'streamc', 'app', 's', '--jsonl', '-i', $jf ] );
	is( $jr->exit_code, 0, 'streamc --jsonl exits 0' );
	# both rows ride one batched request, so the reply is a "scores" array
	# emitted verbatim.
	like( $jr->stdout, qr/"scores"/, 'streamc --jsonl prints the reply JSON verbatim' );
} ## end SKIP:

kill 'TERM', $pid;
waitpid $pid, 0;

done_testing();
