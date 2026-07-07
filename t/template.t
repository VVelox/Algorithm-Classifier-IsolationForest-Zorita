#!perl
# Tests for set templates: the utility-class methods (template_dir/template_path/
# templates/read_template/write_template/create_set), the reserved-directory /
# leading-dot naming rule, and the two subcommands that expose them
# (zorita templates, zorita create-set) driven through App::Cmd::Tester.
use 5.006;
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;

use Algorithm::Classifier::IsolationForest::Zorita;

my $TEMPLATE_DIR = $Algorithm::Classifier::IsolationForest::Zorita::TEMPLATE_DIR;

# A representative template body -- the same shape a set's info.json takes.
my %HTTP = (
	tags          => [qw(bytes duration status)],
	'days_back'   => 7,
	n_trees       => 100,
	sample_size   => 256,
	seed          => 42,
	contamination => 0.01,
	missing       => 'nan',
	voting        => 'majority',
);

# ---------------------------------------------------------------------------
# leading-dot / reserved name rule
# ---------------------------------------------------------------------------
{
	my $z = Algorithm::Classifier::IsolationForest::Zorita->new( basedir => tempdir( CLEANUP => 1 ) );

	ok( !$z->valid_name('.set_templates'), 'a leading-dot name is not a valid name' );
	ok( !$z->valid_name('.hidden'),        'any ^\\. name is rejected' );
	ok( $z->valid_name('http-logs'),       'an ordinary name is still valid' );

	eval { $z->assert_name( '.nope', 'set' ) };
	like( $@, qr/invalid set/, 'assert_name croaks on a leading-dot set name' );
}

# ---------------------------------------------------------------------------
# template_dir / template_path
# ---------------------------------------------------------------------------
{
	my $base = tempdir( CLEANUP => 1 );
	my $z    = Algorithm::Classifier::IsolationForest::Zorita->new( basedir => $base );

	is( $z->template_dir, File::Spec->catdir( $base, $TEMPLATE_DIR ), 'template_dir is .set_templates under basedir' );
	is(
		$z->template_path( template => 'http' ),
		File::Spec->catfile( $base, $TEMPLATE_DIR, 'http.json' ),
		'template_path appends <name>.json'
	);

	eval { $z->template_path( template => '.bad' ) };
	like( $@, qr/invalid template/, 'template_path validates the template name' );
}

# ---------------------------------------------------------------------------
# write_template / read_template / templates listing
# ---------------------------------------------------------------------------
{
	my $base = tempdir( CLEANUP => 1 );
	my $z    = Algorithm::Classifier::IsolationForest::Zorita->new( basedir => $base );

	is_deeply( [ $z->templates ], [], 'templates() is empty before any template dir exists' );

	my $path = $z->write_template( template => 'http', info => {%HTTP} );
	ok( -f $path, 'write_template created the file' );
	is( $path, $z->template_path( template => 'http' ), 'write_template returns the template path' );

	$z->write_template( template => 'ssh', info => { tags => [qw(a b)] } );

	is_deeply( [ $z->templates ], [qw(http ssh)], 'templates() lists names sorted, extension stripped' );

	is_deeply( $z->read_template( template => 'http' ), {%HTTP}, 'read_template round-trips the JSON body' );

	eval { $z->read_template( template => 'missing' ) };
	like( $@, qr/no template 'missing'/, 'read_template croaks on unknown name' );

	# a stray non-template file and a dot-file must be ignored by templates().
	open my $fh, '>', File::Spec->catfile( $z->template_dir, 'README.txt' ) or die $!;
	close $fh;
	open my $dh, '>', File::Spec->catfile( $z->template_dir, '.keep.json' ) or die $!;
	close $dh;
	is_deeply( [ $z->templates ], [qw(http ssh)], 'templates() ignores non-.json and leading-dot files' );
}

# ---------------------------------------------------------------------------
# create_set: template JSON becomes the new set's info.json
# ---------------------------------------------------------------------------
{
	my $base = tempdir( CLEANUP => 1 );
	my $z    = Algorithm::Classifier::IsolationForest::Zorita->new( basedir => $base );
	$z->write_template( template => 'http', info => {%HTTP} );

	ok( !defined $z->read_info( slug => 'myapp', set => 'http-logs' ), 'set does not exist before create_set' );

	my $info_path = $z->create_set(
		slug     => 'myapp',
		set      => 'http-logs',
		template => 'http'
	);

	is(
		$info_path,
		$z->info_path( slug => 'myapp', set => 'http-logs' ),
		'create_set returns the written info.json path'
	);
	is_deeply( $z->read_info( slug => 'myapp', set => 'http-logs' ),
		{%HTTP}, 'the set info.json is a copy of the template' );

	# ...and the machinery downstream can consume it.
	is_deeply( $z->tags( slug => 'myapp', set => 'http-logs' ),
		$HTTP{tags}, 'tags() reads through the templated info.json' );

	# refuses to clobber an existing set
	eval { $z->create_set( slug => 'myapp', set => 'http-logs', template => 'http' ); };
	like( $@, qr/already exists/, 'create_set will not overwrite an existing set' );

	# unknown template
	eval { $z->create_set( slug => 'myapp', set => 'other', template => 'nope' ); };
	like( $@, qr/no template 'nope'/, 'create_set croaks on an unknown template' );

	# template is required
	eval { $z->create_set( slug => 'myapp', set => 'other' ) };
	like( $@, qr/requires template/, 'create_set requires a template' );

	# the reserved template dir is not a slug
	unlike( join( ',', $z->slugs ), qr/\Q$TEMPLATE_DIR\E/, 'slugs() does not report the .set_templates control dir' );
}

# ---------------------------------------------------------------------------
# the subcommands: zorita templates / zorita create-set
# ---------------------------------------------------------------------------
SKIP: {
	eval {
		require App::Cmd::Tester;
		App::Cmd::Tester->import('test_app');
		require Algorithm::Classifier::IsolationForest::Zorita::Cmd;
		1;
	} or skip "App::Cmd (and ::Tester) required: $@", 12;

	my $APP  = 'Algorithm::Classifier::IsolationForest::Zorita::Cmd';
	my $base = tempdir( CLEANUP => 1 );
	my $z    = Algorithm::Classifier::IsolationForest::Zorita->new( basedir => $base );
	$z->write_template( template => 'http', info => {%HTTP} );
	$z->write_template( template => 'ssh',  info => { tags => [qw(a b)] } );

	# commands are registered
	my $cmds = test_app( $APP, [ '--basedir', $base, 'commands' ] );
	like( $cmds->stdout, qr/\btemplates\b/,  'commands lists templates' );
	like( $cmds->stdout, qr/\bcreate-set\b/, 'commands lists create-set' );

	# templates: lists names
	my $t = test_app( $APP, [ '--basedir', $base, 'templates' ] );
	is( $t->exit_code, 0,             'templates exits 0' );
	is( $t->stdout,    "http\nssh\n", 'templates lists sorted names' );

	my $tbad = test_app( $APP, [ '--basedir', $base, 'templates', 'x' ] );
	isnt( $tbad->exit_code, 0, 'templates rejects arguments' );

	# create-set: instantiates the set
	my $c = test_app( $APP, [ '--basedir', $base, 'create-set', 'myapp', 'http-logs', 'http' ] );
	is( $c->exit_code, 0, 'create-set exits 0' );
	like( $c->stdout, qr{created myapp/http-logs from template 'http'}, 'create-set reports what it made' );
	is_deeply( $z->read_info( slug => 'myapp', set => 'http-logs' ),
		{%HTTP}, 'create-set wrote the templated info.json' );

	# create-set: unknown template fails non-zero
	my $cbad = test_app( $APP, [ '--basedir', $base, 'create-set', 'myapp', 'x', 'nope' ] );
	isnt( $cbad->exit_code, 0, 'create-set with an unknown template fails' );
	like( $cbad->error, qr/no template 'nope'/, 'the failure is explained' );

	# create-set: wrong arity
	my $carity = test_app( $APP, [ '--basedir', $base, 'create-set', 'myapp', 'http-logs' ] );
	isnt( $carity->exit_code, 0, 'create-set with two args fails' );
	like( $carity->error, qr/<slug> <set> <template>/, 'create-set arity error explained' );
} ## end SKIP:

done_testing();
