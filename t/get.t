#!perl
# Tests for the raw-JSON getters (info_json / template_json) and the two
# subcommands that expose them: `zorita get-set` and `zorita get-template`.
# The getters return the stored bytes verbatim; the commands print them.
use 5.006;
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP ();

use Algorithm::Classifier::IsolationForest::Zorita;

my %HTTP = (
    tags          => [qw(bytes duration status)],
    'days_back'   => 7,
    n_trees       => 100,
    contamination => 0.01,
    missing       => 'nan',
);

# Build a base dir with one template ('http') and one set (myapp/http-logs
# stamped out from it). Returns the zorita object and its basedir.
sub fresh {
    my $base = tempdir( CLEANUP => 1 );
    my $z = Algorithm::Classifier::IsolationForest::Zorita->new( basedir => $base );
    $z->write_template( template => 'http', info => {%HTTP} );
    $z->create_set( slug => 'myapp', set => 'http-logs', template => 'http' );
    return ( $z, $base );
}

# Read a file's raw bytes, for verbatim comparison against the getters/commands.
sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot read $path: $!";
    local $/;
    my $raw = <$fh>;
    close $fh;
    return $raw;
}

# ---------------------------------------------------------------------------
# info_json: raw text of a set's info.json
# ---------------------------------------------------------------------------
{
    my ( $z ) = fresh();

    my $json = $z->info_json( slug => 'myapp', set => 'http-logs' );
    is( $json, slurp( $z->info_path( slug => 'myapp', set => 'http-logs' ) ),
        'info_json returns the on-disk bytes verbatim' );
    is_deeply( JSON::PP->new->decode($json), {%HTTP},
        'info_json decodes back to the stored structure' );

    eval { $z->info_json( slug => 'myapp', set => 'ghost' ) };
    like( $@, qr/no info\.json for set 'ghost'/,
        'info_json croaks when the set has no info.json' );
}

# ---------------------------------------------------------------------------
# template_json: raw text of a template
# ---------------------------------------------------------------------------
{
    my ( $z ) = fresh();

    my $json = $z->template_json( template => 'http' );
    is( $json, slurp( $z->template_path( template => 'http' ) ),
        'template_json returns the on-disk bytes verbatim' );
    is_deeply( JSON::PP->new->decode($json), {%HTTP},
        'template_json decodes back to the stored structure' );

    # a template created from the same body yields the same JSON a set gets.
    is( $json, $z->info_json( slug => 'myapp', set => 'http-logs' ),
        'template and the set it created print identical JSON' );

    eval { $z->template_json( template => 'nope' ) };
    like( $@, qr/no template 'nope'/,
        'template_json croaks on an unknown template' );
}

# ---------------------------------------------------------------------------
# the subcommands
# ---------------------------------------------------------------------------
SKIP: {
    eval {
        require App::Cmd::Tester;
        App::Cmd::Tester->import('test_app');
        require Algorithm::Classifier::IsolationForest::Zorita::Cmd;
        1;
    } or skip "App::Cmd (and ::Tester) required: $@", 12;

    my $APP = 'Algorithm::Classifier::IsolationForest::Zorita::Cmd';
    my ( $z, $base ) = fresh();

    # commands are registered
    my $cmds = test_app( $APP, [ '--basedir', $base, 'commands' ] );
    like( $cmds->stdout, qr/\bget-set\b/,      'commands lists get-set' );
    like( $cmds->stdout, qr/\bget-template\b/, 'commands lists get-template' );

    # get-set prints the set's info.json verbatim
    my $gs = test_app( $APP, [ '--basedir', $base, 'get-set', 'myapp', 'http-logs' ] );
    is( $gs->exit_code, 0, 'get-set exits 0' );
    is( $gs->stdout, $z->info_json( slug => 'myapp', set => 'http-logs' ),
        'get-set prints the info.json verbatim' );
    is_deeply( JSON::PP->new->decode( $gs->stdout ), {%HTTP},
        'get-set output decodes to the stored structure' );

    my $gs_bad = test_app( $APP, [ '--basedir', $base, 'get-set', 'myapp', 'ghost' ] );
    isnt( $gs_bad->exit_code, 0, 'get-set on an unknown set fails' );

    my $gs_arity = test_app( $APP, [ '--basedir', $base, 'get-set', 'myapp' ] );
    isnt( $gs_arity->exit_code, 0, 'get-set with one arg fails' );
    like( $gs_arity->error, qr/<slug> and <set>/, 'get-set arity error explained' );

    # get-template prints the template JSON verbatim
    my $gt = test_app( $APP, [ '--basedir', $base, 'get-template', 'http' ] );
    is( $gt->exit_code, 0, 'get-template exits 0' );
    is( $gt->stdout, $z->template_json( template => 'http' ),
        'get-template prints the template JSON verbatim' );

    my $gt_bad = test_app( $APP, [ '--basedir', $base, 'get-template', 'nope' ] );
    isnt( $gt_bad->exit_code, 0, 'get-template on an unknown template fails' );

    my $gt_arity = test_app( $APP, [ '--basedir', $base, 'get-template' ] );
    isnt( $gt_arity->exit_code, 0, 'get-template with no arg fails' );
}

done_testing();
