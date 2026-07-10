#!perl
# Drive a live online daemon through the client module (Zorita::Online::Client)
# rather than a hand-rolled socket, exercising its typed helpers and error
# surfacing. Needs the optional online model class, so it skips without it.
use 5.006;
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use POSIX ();

BEGIN {
	eval { require Algorithm::Classifier::IsolationForest::Online; 1 }
		or plan skip_all => 'Algorithm::Classifier::IsolationForest::Online not installed';
}

use Algorithm::Classifier::IsolationForest::Zorita                 ();
use Algorithm::Classifier::IsolationForest::Zorita::Online         ();
use Algorithm::Classifier::IsolationForest::Zorita::Online::Client ();

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

# --- a client resolves its socket from the online set -------------------------
my $c = Algorithm::Classifier::IsolationForest::Zorita::Online::Client->new( zorita => $z, %W );
is( $c->socket_path, $z->socket_path(%W), 'client resolves the set socket path' );

# connecting before the daemon is up is a clean croak, not a hang
eval { $c->ping };
like( $@, qr/failed to connect/, 'ping before the daemon is up croaks with connect failure' );

# a batch object cannot back an online client
my $bz = Algorithm::Classifier::IsolationForest::Zorita->new( basedir => $base, type => 'batch' );
eval { Algorithm::Classifier::IsolationForest::Zorita::Online::Client->new( zorita => $bz, %W ) };
like( $@, qr/type 'online'/, 'client refuses a batch zorita' );

# --- fork the daemon and drive it through the client --------------------------
my $pid = fork();
defined $pid or plan skip_all => "fork failed: $!";
if ( !$pid ) {
	my $daemon = Algorithm::Classifier::IsolationForest::Zorita::Online->new(
		%W,
		zorita        => $z,
		foreground    => 1,
		save_interval => 3600,
		log           => File::Spec->catfile( $base, 'd.log' ),
	);
	eval { $daemon->run; 1 } or do { print {*STDERR} "daemon died: $@"; POSIX::_exit(1); };
	POSIX::_exit(0);
} ## end if ( !$pid )

# wait for the socket, then talk through a fresh client
my $client = Algorithm::Classifier::IsolationForest::Zorita::Online::Client->new( zorita => $z, %W );
my $up;
for ( 1 .. 50 ) {
	$up = eval { $client->ping };
	last if defined $up;
	$client->disconnect;
	select undef, undef, undef, 0.1;    ## no critic (ProhibitSleepViaSelect)
}

SKIP: {
	skip 'daemon did not come up', 8 unless defined $up;

	is( $up, 'pong', 'ping returns pong' );

	my $r = $client->row( [ 0.1, 0.2 ] );
	ok( exists $r->{score} && exists $r->{label}, 'row() returns score + label' );

	my $learn = $client->rows( [ [ 0.1, 0.2 ], [ 0.3, 0.4 ] ], mode => 'learn' );
	is_deeply( $learn->{ok}, { learned => 2 }, 'rows(mode=>learn) reports the count' );

	my $tagged = $client->row( { x => 0.5, y => 0.6 }, tag => 'r1' );
	is( $tagged->{tag}, 'r1', 'tagged row echoes the correlation tag' );

	my $stats = $client->stats;
	ok( $stats->{seen} >= 3, 'stats() reports the seen count' );

	my $saved = $client->save;
	like( $saved, qr/\Aoiforest-.*\.json\z/, 'save() returns the saved file name' );
	ok( -e $z->latest_path(%W), 'latest.json exists after save()' );

	# request() hands a daemon error back as data; the typed helpers croak on it
	my $bad = $client->request( { foo => 1 } );
	like( $bad->{error}, qr/exactly one of/, 'request() hands back a daemon error as data' );
} ## end SKIP:

$client->disconnect;
kill 'TERM', $pid;
waitpid $pid, 0;

done_testing();
