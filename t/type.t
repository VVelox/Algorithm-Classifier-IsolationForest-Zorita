#!perl
# Tests for the $type layer: the $basedir/$type/... path root, the type enum on
# the constructor, the per-type .set_templates directory, and the type key that
# write_info/write_template stamp into (and validate_info asserts against) each
# stored body. The online-backend behaviours -- validating and rebuilding an
# online set -- need Algorithm::Classifier::IsolationForest::Online, which is an
# optional dependency, so they live in a SKIP block that runs only when it loads.
use 5.006;
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;

use Algorithm::Classifier::IsolationForest::Zorita;
use Algorithm::Classifier::IsolationForest::Zorita::Writer;

# ---------------------------------------------------------------------------
# the type enum on the constructor
# ---------------------------------------------------------------------------
{
	my $base = tempdir( CLEANUP => 1 );

	my $z = Algorithm::Classifier::IsolationForest::Zorita->new( basedir => $base );
	is( $z->{type}, 'batch', 'type defaults to batch' );

	my $on = Algorithm::Classifier::IsolationForest::Zorita->new( basedir => $base, type => 'online' );
	is( $on->{type}, 'online', 'type => online is accepted' );

	eval { Algorithm::Classifier::IsolationForest::Zorita->new( basedir => $base, type => 'bogus' ) };
	like( $@, qr/invalid type 'bogus'/, 'an unknown type croaks at construction' );
}

# ---------------------------------------------------------------------------
# $type is the first path segment: $basedir/$type/$slug/$set/...
# ---------------------------------------------------------------------------
{
	my $base = tempdir( CLEANUP => 1 );

	for my $type (qw(batch online)) {
		my $z = Algorithm::Classifier::IsolationForest::Zorita->new( basedir => $base, type => $type );

		is(
			$z->slug_dir( slug => 'myapp' ),
			File::Spec->catdir( $base, $type, 'myapp' ),
			"$type: slug_dir is basedir/$type/slug"
		);
		is(
			$z->set_dir( slug => 'myapp', set => 'http-logs' ),
			File::Spec->catdir( $base, $type, 'myapp', 'http-logs' ),
			"$type: set_dir nests under the type root"
		);
		is(
			$z->template_dir,
			File::Spec->catdir( $base, $type, '.set_templates' ),
			"$type: .set_templates is per-type"
		);
	} ## end for my $type (qw(batch online))

	# The two roots are genuinely disjoint, so a batch and an online tree under
	# the same basedir never see each other's slugs or templates.
	my $b = Algorithm::Classifier::IsolationForest::Zorita->new( basedir => $base, type => 'batch' );
	my $o = Algorithm::Classifier::IsolationForest::Zorita->new( basedir => $base, type => 'online' );
	$b->write_template( template => 'http', info => { tags => [qw(a b)] } );
	is_deeply( [ $b->templates ], ['http'], 'batch tree lists its own template' );
	is_deeply( [ $o->templates ], [],       'online tree does not see the batch template' );
}

# ---------------------------------------------------------------------------
# write_info stamps the tree's type into the body; a mismatching type is
# rejected (this check precedes the backend dry-run, so it needs no backend).
# ---------------------------------------------------------------------------
{
	my $base = tempdir( CLEANUP => 1 );
	my $z    = Algorithm::Classifier::IsolationForest::Zorita->new( basedir => $base );

	$z->write_info( slug => 'myapp', set => 'http-logs', info => { tags => [qw(a b)] } );
	my $info = $z->read_info( slug => 'myapp', set => 'http-logs' );
	is( $info->{type}, 'batch', 'write_info stamped type => batch into the stored body' );

	# A body that already names the right type is kept, not doubled up.
	$z->write_info( slug => 'myapp', set => 'keep', info => { tags => [qw(a b)], type => 'batch' } );
	is( $z->read_info( slug => 'myapp', set => 'keep' )->{type}, 'batch', 'a matching type is preserved' );

	# A body naming the wrong type is refused before anything is written.
	eval { $z->write_info( slug => 'myapp', set => 'wrong', info => { tags => [qw(a b)], type => 'online' } ); };
	like( $@, qr/does not match this tree's type 'batch'/, 'a wrong-type body is rejected' );
	ok( !defined $z->read_info( slug => 'myapp', set => 'wrong' ), 'the rejected set was not written' );
}

# ---------------------------------------------------------------------------
# online: no row storage. The batch data-flow ops croak, and the set dir gains
# the runtime file helpers (socket/pid/log/latest). None of this needs the
# optional model class -- the ops croak before any model is touched.
# ---------------------------------------------------------------------------
{
	my $base = tempdir( CLEANUP => 1 );
	my $on   = Algorithm::Classifier::IsolationForest::Zorita->new( basedir => $base, type => 'online' );
	my %w    = ( slug => 'app', set => 's' );

	for my $method (qw(rebuild_model read_back combine_hour combine_day)) {
		eval { $on->$method(%w) };
		like( $@, qr/not available for online sets|not applicable/i, "$method croaks for an online set" );
	}

	my $setdir = $on->set_dir(%w);
	is(
		$on->socket_path(%w),
		File::Spec->catfile( $setdir, 'stream.sock' ),
		'socket_path is stream.sock in the set dir'
	);
	is( $on->pid_path(%w), File::Spec->catfile( $setdir, 'stream.pid' ),  'pid_path is stream.pid in the set dir' );
	is( $on->log_path(%w), File::Spec->catfile( $setdir, 'streamd.log' ), 'log_path is streamd.log in the set dir' );
	is(
		$on->latest_path(%w),
		File::Spec->catfile( $setdir, 'latest.json' ),
		'latest_path is latest.json in the set dir'
	);
	is( $on->model_path(%w), $on->latest_path(%w), 'online model_path is the latest.json symlink' );

	# The runtime helpers are online-only; a batch tree has none of them.
	my $b = Algorithm::Classifier::IsolationForest::Zorita->new( basedir => $base, type => 'batch' );
	eval { $b->socket_path(%w) };
	like( $@, qr/only available for online sets/, 'socket_path croaks for a batch set' );
}

# ---------------------------------------------------------------------------
# online backend: info validation + model construction. Needs the optional
# model class, so it is skip-guarded.
# ---------------------------------------------------------------------------
SKIP: {
	eval { require Algorithm::Classifier::IsolationForest::Online; 1 }
		or skip 'Algorithm::Classifier::IsolationForest::Online not installed', 4;

	# A storage-legal online body: online accepts only missing => zero (die is
	# forbidden by the contract, nan/impute are not online policies at all), plus
	# the online-only hyper-parameters window_size / growth.
	my %ONLINE = (
		tags          => [qw(x y)],
		n_trees       => 20,
		window_size   => 256,
		growth        => 'adaptive',
		seed          => 42,
		contamination => 0.1,
		missing       => 'zero',
	);

	my $base = tempdir( CLEANUP => 1 );
	my $z    = Algorithm::Classifier::IsolationForest::Zorita->new( basedir => $base, type => 'online' );

	# validate_info forks by type: a batch-only 'missing' policy is refused by
	# the missing fork, a bogus growth by the backend dry-run.
	eval { $z->write_info( slug => 'app', set => 's', info => { %ONLINE, missing => 'nan' } ) };
	like( $@, qr/online set must be 'zero'/, "online rejects missing => 'nan'" );

	eval { $z->write_info( slug => 'app', set => 's', info => { %ONLINE, growth => 'sideways' } ) };
	like( $@, qr/unusable by/, 'online rejects an out-of-range growth via the dry-run' );

	# A clean online body writes, is self-describing, and builds an online model.
	$z->write_info( slug => 'app', set => 's', info => {%ONLINE} );
	is( $z->read_info( slug => 'app', set => 's' )->{type}, 'online', 'online set records type => online' );

	my $if = $z->iforest( slug => 'app', set => 's' );
	isa_ok( $if, 'Algorithm::Classifier::IsolationForest::Online', 'iforest() builds the online class' );
} ## end SKIP:

done_testing();
