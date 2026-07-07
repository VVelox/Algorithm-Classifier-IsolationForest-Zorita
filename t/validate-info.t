#!perl
# Hyper-parameter sanity checking of an info body: anything that
# Algorithm::Classifier::IsolationForest->new would reject at rebuild time
# must instead croak at write time (write_info / write_template / create_set)
# and at Writer->new -- days earlier, while someone is looking.
use 5.006;
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

use Algorithm::Classifier::IsolationForest::Zorita;
use Algorithm::Classifier::IsolationForest::Zorita::Writer;

my $WRITER_CLASS = 'Algorithm::Classifier::IsolationForest::Zorita::Writer';

sub fresh_zorita {
	return Algorithm::Classifier::IsolationForest::Zorita->new( basedir => tempdir( CLEANUP => 1 ) );
}

# drop raw JSON at a path, bypassing every write-time check
sub drop_raw {
	my ( $path, $json ) = @_;
	open my $fh, '>', $path or die "cannot write $path: $!";
	print {$fh} $json;
	close $fh;
}

# A fully-loaded valid body exercising every key iforest() forwards.
my %GOOD = (
	tags            => [qw(bytes duration status)],
	'days_back'     => 7,
	n_trees         => 100,
	sample_size     => 256,
	max_depth       => 12,
	seed            => 42,
	mode            => 'extended',
	extension_level => 1,
	contamination   => 0.01,
	missing         => 'impute',
	impute_with     => 'median',
	voting          => 'majority',
);

# key => [ bad value, what the croak must carry ]. The first group is rejected
# by the dry-run (the forest's own croak text, so these double as drift
# detectors for its accepted surface); the last two are the keys new()
# silently coerces or defers, caught by the numeric pre-pass instead.
my %BAD = (
	voting          => [ 'soft',     qr/voting must be 'mean' or 'majority'/ ],
	mode            => [ 'diagonal', qr/mode must be 'axis' or 'extended'/ ],
	impute_with     => [ 'mode',     qr/impute_with must be 'mean' or 'median'/ ],
	missing         => [ 'ignore',   qr/missing must be one of/ ],
	contamination   => [  0.9,       qr/contamination must be a number/ ],
	n_trees         => [  0,         qr/n_trees must be >= 1/ ],
	sample_size     => [  0,         qr/sample_size must be >= 1/ ],
	extension_level => [ -1,         qr/extension_level must be >= 0/ ],
	seed            => [ 'banana',   qr/'seed' \('banana'\) is not numeric/ ],
	max_depth       => [ 'deep',     qr/'max_depth' \('deep'\) is not numeric/ ],
);

# ---- validate_info / write_info ---------------------------------------------
{
	my $z = fresh_zorita();

	ok( $z->validate_info( {%GOOD} ), 'validate_info passes a maximal good body' );
	ok( -f $z->write_info( slug => 'myapp', set => 'good', info => {%GOOD} ), 'write_info accepts the same body' );

	for my $key ( sort keys %BAD ) {
		my ( $value, $err ) = @{ $BAD{$key} };
		eval { $z->write_info( slug => 'myapp', set => "bad-$key", info => { %GOOD, $key => $value } ); };
		like( $@, $err, "write_info rejects $key => '$value'" );
		ok( !-f $z->info_path( slug => 'myapp', set => "bad-$key" ), "...and no info.json landed on disk for $key" );
	}

	# numeric but senseless: new() never looks at max_depth, fit() would
	eval { $z->write_info( slug => 'myapp', set => 'bad-depth0', info => { %GOOD, max_depth => 0 } ) };
	like( $@, qr/'max_depth' must be >= 1/, 'write_info rejects max_depth => 0' );

	# undef (a JSON null) means "auto" to the forest and must stay accepted
	ok(
		-f $z->write_info(
			slug => 'myapp',
			set  => 'null-depth',
			info => { %GOOD, max_depth => undef, seed => undef }
		),
		'undef (JSON null) hyper-parameters are still accepted'
	);

	# Zorita's own 'die' prohibition outranks the dry-run, which would accept
	# it (die is the forest's default): the message must stay the specific one.
	eval { $z->write_info( slug => 'myapp', set => 'bad-die', info => { %GOOD, missing => 'die' } ) };
	like( $@, qr/may not be 'die'/, "missing => 'die' keeps its specific message" );

	# a body with none of the model keys (all defaults) is fine
	ok( $z->validate_info( { tags => [qw(a b)] } ), 'a body with no hyper-parameters at all validates' );
}

# ---- write_template -----------------------------------------------------------
{
	my $z = fresh_zorita();

	eval { $z->write_template( template => 'bad', info => { %GOOD, voting => 'soft' } ) };
	like( $@, qr/voting must be 'mean' or 'majority'/, "write_template rejects voting => 'soft'" );
	ok( !-f $z->template_path( template => 'bad' ), 'no template file written' );

	ok( -f $z->write_template( template => 'http', info => {%GOOD} ), 'write_template accepts a good body' );
}

# ---- create_set from a hand-dropped rogue template ----------------------------
{
	my $z = fresh_zorita();
	make_path( $z->template_dir );
	drop_raw( $z->template_path( template => 'rogue' ), '{"tags":["bytes"],"voting":"soft"}' );

	eval { $z->create_set( slug => 'myapp', set => 'from-rogue', template => 'rogue' ) };
	like( $@, qr/voting must be 'mean' or 'majority'/, 'create_set rejects a template that bypassed write_template' );
	ok( !-f $z->info_path( slug => 'myapp', set => 'from-rogue' ), 'the rogue template instantiated no set' );
}

# ---- Writer->new verifies the set at construction ------------------------------
{
	my $z = fresh_zorita();
	my %W = ( zorita => $z, slug => 'myapp', writer => 'web01' );

	eval { $WRITER_CLASS->new( %W, set => 'absent' ) };
	like( $@, qr/no info\.json for set 'absent'/, 'Writer->new croaks when the set does not exist' );

	# hand-edited info.json that never went through write_info
	$z->write_info( slug => 'myapp', set => 'edited', info => {%GOOD} );
	drop_raw( $z->info_path( slug => 'myapp', set => 'edited' ), '{"tags":["bytes"],"voting":"soft"}' );
	eval { $WRITER_CLASS->new( %W, set => 'edited' ) };
	like( $@, qr/voting must be 'mean' or 'majority'/, 'Writer->new catches a hand-edited bad hyper-parameter' );

	# tags are required at construction (a writer cannot order columns)
	$z->write_info( slug => 'myapp', set => 'tagless', info => {%GOOD} );
	drop_raw( $z->info_path( slug => 'myapp', set => 'tagless' ), '{"days_back":7}' );
	eval { $WRITER_CLASS->new( %W, set => 'tagless' ) };
	like( $@, qr/has no 'tags'/, 'Writer->new croaks on a tagless set' );

	# a good set constructs, with tags/plan seeded from the validated read
	$z->write_info( slug => 'myapp', set => 'good', info => {%GOOD} );
	my $w = $WRITER_CLASS->new( %W, set => 'good' );
	isa_ok( $w, $WRITER_CLASS, 'Writer->new on a good set' );
	is_deeply( $w->tags, $GOOD{tags}, 'tags cache seeded at construction' );
	my $row = $w->plan->apply_named( { bytes => 1, duration => 2, status => 3 } );
	is_deeply( $row, [ 1, 2, 3 ], 'plan cache seeded and usable' );
}

done_testing;
