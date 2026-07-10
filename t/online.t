#!perl
# Integration test for the online serving daemon (Zorita::Online): fork a
# foreground daemon around a real online set, drive its JSON-lines socket
# protocol from the parent, and confirm it scores/learns, answers the control
# commands, persists a model, and resumes. Needs the optional online model
# class, so the whole file skips when it is not installed.
use 5.006;
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use IO::Socket::UNIX ();
use POSIX            ();
use JSON::PP         ();

BEGIN {
	eval { require Algorithm::Classifier::IsolationForest::Online; 1 }
		or plan skip_all => 'Algorithm::Classifier::IsolationForest::Online not installed';
}

use Algorithm::Classifier::IsolationForest::Zorita         ();
use Algorithm::Classifier::IsolationForest::Zorita::Online ();

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

my $sock = $z->socket_path(%W);

# --- fork a foreground daemon -------------------------------------------------
my $pid = fork();
defined $pid or plan skip_all => "fork failed: $!";
if ( !$pid ) {
	# child: run the daemon, logging to a file so it does not spew into the
	# test output, and never returning until the parent sends SIGTERM.
	my $daemon = Algorithm::Classifier::IsolationForest::Zorita::Online->new(
		%W,
		zorita        => $z,
		foreground    => 1,
		save_interval => 3600,                                    # no periodic save during the test
		log           => File::Spec->catfile( $base, 'd.log' ),
	);
	eval { $daemon->run; 1 } or do { print {*STDERR} "daemon died: $@"; POSIX::_exit(1); };
	POSIX::_exit(0);
} ## end if ( !$pid )

# --- parent: connect once the daemon has bound --------------------------------
my $client;
for ( 1 .. 50 ) {
	$client = IO::Socket::UNIX->new( Peer => $sock ) and last;
	select undef, undef, undef, 0.1;    ## no critic (ProhibitSleepViaSelect)
}

my $json = JSON::PP->new->utf8->canonical;

# One request line -> one reply, decoded.
my $req = sub {
	my ($obj) = @_;
	print {$client} $json->encode($obj) . "\n";
	my $line = <$client>;
	return defined $line ? $json->decode($line) : undef;
};

SKIP: {
	skip "could not connect to daemon socket $sock", 10 unless $client;

	is_deeply( $req->( { cmd => 'ping' } ), { ok => 'pong' }, 'ping -> pong' );

	my $r = $req->( { row => [ 0.1, 0.2 ] } );
	ok( exists $r->{score} && exists $r->{label}, 'prequential row returns score + label' );

	my $batch = $req->( { rows => [ [ 0.1, 0.2 ], [ 0.3, 0.4 ] ], mode => 'learn' } );
	is_deeply( $batch, { ok => { learned => 2 } }, 'learn batch acknowledges the count' );

	my $tagged = $req->( { row => { x => 0.5, y => 0.6 }, tag => 'r1' } );
	is( $tagged->{tag}, 'r1', 'tagged row echoes the correlation tag' );

	my $stats = $req->( { cmd => 'stats' } );
	ok( $stats->{ok}{seen} >= 3, 'stats reports the seen count' );
	is( $stats->{ok}{set}, 's', 'stats reports the set name' );

	my $save = $req->( { cmd => 'save' } );
	like( $save->{ok}{saved}, qr/\Aoiforest-.*\.json\z/, 'save returns a timestamped file name' );
	ok( -e $z->latest_path(%W), 'latest.json symlink exists after save' );

	my $bad = $req->( { foo => 1 } );
	like( $bad->{error}, qr/exactly one of/, 'a malformed request returns an error, not a crash' );

	my $unknown = $req->( { cmd => 'nope' } );
	like( $unknown->{error}, qr/unknown cmd/, 'an unknown command is reported' );
} ## end SKIP:

$client->close if $client;

# --- stop the daemon and confirm the saved model resumes ----------------------
kill 'TERM', $pid;
waitpid $pid, 0;
is( $? >> 8, 0, 'daemon exited cleanly on SIGTERM' );

ok( -e $z->latest_path(%W), 'latest.json persists after shutdown' );
my $loaded = $z->load_model(%W);
isa_ok( $loaded, 'Algorithm::Classifier::IsolationForest::Online', 'load_model reads the persisted online model' );

done_testing();
