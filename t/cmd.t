#!perl
# End-to-end tests for the App::Cmd front end (the `zorita` command) and its
# subcommands: slugs, sets, rebuild, rebuild-slug, and rebuild-all. Each case
# drives the real application object through App::Cmd::Tester -- exactly as the
# installed executable would -- and inspects stdout/stderr/exit_code.
#
# Rebuilds run against a freshly built, genuinely trainable tree so the model
# files really do get rendered. Data is written at wall-clock "now" (not a fixed
# epoch) precisely because the subcommands rebuild using the real current time;
# a fixed epoch would fall outside their training window.
use 5.006;
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;

# App::Cmd::Tester ships with App::Cmd; skip cleanly if the front end's deps are
# somehow unavailable so a bare install still passes its own test suite.
BEGIN {
	eval {
		require App::Cmd::Tester;
		App::Cmd::Tester->import('test_app');
		require Algorithm::Classifier::IsolationForest::Zorita::Cmd;
		1;
	} or plan skip_all => "App::Cmd (and ::Tester) required: $@";
}

use Algorithm::Classifier::IsolationForest::Zorita;
use Algorithm::Classifier::IsolationForest::Zorita::Writer;

my $APP = 'Algorithm::Classifier::IsolationForest::Zorita::Cmd';

my @TAGS = qw(x y);
my %INFO = (
	tags          => [@TAGS],
	'days_back'   => 7,
	n_trees       => 50,
	sample_size   => 64,
	seed          => 42,
	contamination => 0.1,
	missing       => 'nan',
	voting        => 'mean',
);

# Declare a set (write its info.json) and, unless $empty, fill it with enough
# clustered rows -- plus one outlier -- at "now" for rebuild_model to fit.
sub make_set {
	my ( $zorita, $slug, $set, %opt ) = @_;
	$zorita->write_info( slug => $slug, set => $set, info => {%INFO} );
	return if $opt{empty};

	my $writer = Algorithm::Classifier::IsolationForest::Zorita::Writer->new(
		zorita => $zorita,
		slug   => $slug,
		set    => $set,
		writer => 'w01'
	);
	$writer->write( [ $_ % 5, ( $_ * 2 ) % 7 ] ) for 1 .. 40;
	$writer->write( [ 999, 999 ] );    # the anomaly
} ## end sub make_set

# A base directory with:
#   appone/http-logs  (trainable)
#   appone/ssh-logs   (trainable)
#   apptwo/web-logs   (trainable)
#   apptwo/broken     (info.json but NO data -> rebuild fails)
# plus a loose file that discovery must ignore.
sub fresh_tree {
	my $base   = tempdir( CLEANUP => 1 );
	my $zorita = Algorithm::Classifier::IsolationForest::Zorita->new( basedir => $base );

	make_set( $zorita, 'appone', 'http-logs' );
	make_set( $zorita, 'appone', 'ssh-logs' );
	make_set( $zorita, 'apptwo', 'web-logs' );
	make_set( $zorita, 'apptwo', 'broken', empty => 1 );

	open my $fh, '>', File::Spec->catfile( $base, 'not-a-slug' ) or die $!;
	close $fh;

	return ( $base, $zorita );
} ## end sub fresh_tree

sub model_exists {
	my ( $zorita, $slug, $set ) = @_;
	return -f $zorita->model_path( slug => $slug, set => $set );
}

# ---------------------------------------------------------------------------
# commands: the app registers all five of our subcommands.
# ---------------------------------------------------------------------------
{
	my ($base) = fresh_tree();
	my $r = test_app( $APP, [ '--basedir', $base, 'commands' ] );
	for my $cmd (qw(slugs sets rebuild rebuild-slug rebuild-all)) {
		like( $r->stdout, qr/\b\Q$cmd\E\b/, "commands lists '$cmd'" );
	}
}

# ---------------------------------------------------------------------------
# slugs
# ---------------------------------------------------------------------------
{
	my ($base) = fresh_tree();
	my $r = test_app( $APP, [ '--basedir', $base, 'slugs' ] );
	is( $r->exit_code, 0,                  'slugs exits 0' );
	is( $r->stdout,    "appone\napptwo\n", 'slugs lists slugs, sorted' );
	unlike( $r->stdout, qr/not-a-slug/, 'slugs ignores the loose file' );

	my $bad = test_app( $APP, [ '--basedir', $base, 'slugs', 'extra' ] );
	isnt( $bad->exit_code, 0, 'slugs with an argument fails' );
	like( $bad->error, qr/takes no arguments/, 'slugs arg error explained' );
}

# ---------------------------------------------------------------------------
# sets
# ---------------------------------------------------------------------------
{
	my ($base) = fresh_tree();
	my $r = test_app( $APP, [ '--basedir', $base, 'sets', 'appone' ] );
	is( $r->exit_code, 0,                       'sets exits 0' );
	is( $r->stdout,    "http-logs\nssh-logs\n", 'sets lists a slug\'s sets, sorted' );

	my $none = test_app( $APP, [ '--basedir', $base, 'sets', 'nope' ] );
	is( $none->exit_code, 0,  'sets on an unknown slug still exits 0' );
	is( $none->stdout,    '', 'sets on an unknown slug prints nothing' );

	my $bad = test_app( $APP, [ '--basedir', $base, 'sets' ] );
	isnt( $bad->exit_code, 0, 'sets with no slug fails' );
	like( $bad->error, qr/exactly one <slug>/, 'sets arity error explained' );
}

# ---------------------------------------------------------------------------
# rebuild: one specific set
# ---------------------------------------------------------------------------
{
	my ( $base, $zorita ) = fresh_tree();
	ok( !model_exists( $zorita, 'appone', 'http-logs' ), 'no model before rebuild' );

	my $r = test_app( $APP, [ '--basedir', $base, 'rebuild', 'appone', 'http-logs' ] );
	is( $r->exit_code, 0, 'rebuild of a good set exits 0' );
	like( $r->stdout, qr{rebuilt appone/http-logs}, 'rebuild reports the set' );
	like( $r->stdout, qr/1 rebuilt, 0 failed/,      'rebuild summary is right' );
	ok( model_exists( $zorita,  'appone', 'http-logs' ), 'model rendered to disk' );
	ok( !model_exists( $zorita, 'appone', 'ssh-logs' ),  'rebuild touched only the named set' );
}

# rebuild of the data-less set fails loudly and non-zero.
{
	my ( $base, $zorita ) = fresh_tree();
	my $r = test_app( $APP, [ '--basedir', $base, 'rebuild', 'apptwo', 'broken' ] );
	isnt( $r->exit_code, 0, 'rebuild of an empty set exits non-zero' );
	like( $r->stderr, qr{FAILED\s+apptwo/broken}, 'the failure is reported' );
	like( $r->stdout, qr/0 rebuilt, 1 failed/,    'summary counts the failure' );
	ok( !model_exists( $zorita, 'apptwo', 'broken' ), 'no model for the empty set' );
}

# rebuild arity errors.
{
	my ($base) = fresh_tree();
	my $bad = test_app( $APP, [ '--basedir', $base, 'rebuild', 'appone' ] );
	isnt( $bad->exit_code, 0, 'rebuild with one arg fails' );
	like( $bad->error, qr/<slug> and <set>/, 'rebuild arity error explained' );
}

# ---------------------------------------------------------------------------
# rebuild-slug: every set under one slug
# ---------------------------------------------------------------------------
{
	my ( $base, $zorita ) = fresh_tree();
	my $r = test_app( $APP, [ '--basedir', $base, 'rebuild-slug', 'appone' ] );
	is( $r->exit_code, 0, 'rebuild-slug of an all-good slug exits 0' );
	like( $r->stdout, qr/2 rebuilt, 0 failed/, 'both sets rebuilt' );
	ok( model_exists( $zorita,  'appone', 'http-logs' ), 'http-logs model built' );
	ok( model_exists( $zorita,  'appone', 'ssh-logs' ),  'ssh-logs model built' );
	ok( !model_exists( $zorita, 'apptwo', 'web-logs' ),  'a different slug was left alone' );
}

# rebuild-slug keeps going past a failure: the good set still builds, and the
# run still exits non-zero because one set failed.
{
	my ( $base, $zorita ) = fresh_tree();
	my $r = test_app( $APP, [ '--basedir', $base, 'rebuild-slug', 'apptwo' ] );
	isnt( $r->exit_code, 0, 'rebuild-slug with a bad set exits non-zero' );
	like( $r->stdout, qr/1 rebuilt, 1 failed/,    'one built, one failed' );
	like( $r->stderr, qr{FAILED\s+apptwo/broken}, 'the bad set is named' );
	ok( model_exists( $zorita, 'apptwo', 'web-logs' ), 'the good set built despite its sibling failing' );
}

# rebuild-slug on a slug with no sets warns but does not fail.
{
	my ($base) = fresh_tree();
	my $r = test_app( $APP, [ '--basedir', $base, 'rebuild-slug', 'ghost' ] );
	is( $r->exit_code, 0, 'rebuild-slug of an empty slug exits 0' );
	like( $r->stderr, qr/has no sets/,         'the empty slug is called out' );
	like( $r->stdout, qr/0 rebuilt, 0 failed/, 'nothing rebuilt' );
}

# ---------------------------------------------------------------------------
# rebuild-all: every set under every slug
# ---------------------------------------------------------------------------
{
	my ( $base, $zorita ) = fresh_tree();
	my $r = test_app( $APP, [ '--basedir', $base, 'rebuild-all' ] );
	isnt( $r->exit_code, 0, 'rebuild-all exits non-zero because "broken" fails' );
	like( $r->stdout, qr/3 rebuilt, 1 failed/, 'three good sets, one failure' );

	ok( model_exists( $zorita,  'appone', 'http-logs' ), 'appone/http-logs built' );
	ok( model_exists( $zorita,  'appone', 'ssh-logs' ),  'appone/ssh-logs built' );
	ok( model_exists( $zorita,  'apptwo', 'web-logs' ),  'apptwo/web-logs built' );
	ok( !model_exists( $zorita, 'apptwo', 'broken' ),    'apptwo/broken not built' );

	my $bad = test_app( $APP, [ '--basedir', $base, 'rebuild-all', 'extra' ] );
	isnt( $bad->exit_code, 0, 'rebuild-all with an argument fails' );
	like( $bad->error, qr/takes no arguments/, 'rebuild-all arg error explained' );
}

# rebuild-all against an empty base directory warns but succeeds.
{
	my $base = tempdir( CLEANUP => 1 );
	my $r    = test_app( $APP, [ '--basedir', $base, 'rebuild-all' ] );
	is( $r->exit_code, 0, 'rebuild-all on an empty tree exits 0' );
	like( $r->stderr, qr/no sets found/,       'the empty tree is called out' );
	like( $r->stdout, qr/0 rebuilt, 0 failed/, 'nothing rebuilt' );
}

# ---------------------------------------------------------------------------
# --hours is accepted and forwarded (a good build still succeeds with it).
# ---------------------------------------------------------------------------
{
	my ( $base, $zorita ) = fresh_tree();
	my $r = test_app( $APP, [ '--basedir', $base, 'rebuild', '--hours', '48', 'appone', 'http-logs' ] );
	is( $r->exit_code, 0, 'rebuild --hours exits 0' );
	ok( model_exists( $zorita, 'appone', 'http-logs' ), 'rebuild --hours still renders the model' );
}

done_testing();
