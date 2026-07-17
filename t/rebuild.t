#!perl
# Functional tests for the model side of the utility class: iforest() building
# an unfitted classifier from info.json's hyper-parameters, rebuild_model()
# reading the training window back and fitting+persisting it, and load_model()
# reconstructing an identical model from the rendered iforest_model.json.
use 5.006;
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);

use Algorithm::Classifier::IsolationForest::Zorita;
use Algorithm::Classifier::IsolationForest::Zorita::Writer;

# A fixed "now" so read_back's window is deterministic and independent of the
# wall clock; every write below is stamped with the same epoch.
my $NOW = 1_751_808_000;

my @TAGS = qw(x y);

# info.json carrying both the CSV shape (tags/days_back) and a full set of
# hyper-parameters. seed makes the fit reproducible; contamination gives the
# model a learned decision threshold; missing => nan is the storage-legal
# handling (never 'die').
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

# Build a fresh basedir with one set, and populate it with 40 tightly-clustered
# rows plus one blatant outlier, all in the current hour so read_back sees them.
sub fresh_populated {
	my $basedir = tempdir( CLEANUP => 1 );
	my $zorita  = Algorithm::Classifier::IsolationForest::Zorita->new( basedir => $basedir );
	$zorita->write_info( slug => 'myapp', set => 'http-logs', info => {%INFO} );

	my $writer = Algorithm::Classifier::IsolationForest::Zorita::Writer->new(
		zorita => $zorita,
		slug   => 'myapp',
		set    => 'http-logs',
		writer => 'web01',
	);
	$writer->write( [ $_ % 5, ( $_ * 2 ) % 7 ], time => $NOW ) for 1 .. 40;
	$writer->write( [ 999, 999 ], time => $NOW );    # the anomaly

	return $zorita;
} ## end sub fresh_populated

# ----------------------------------------------------------------------------
# iforest(): an unfitted classifier reflecting info.json.
# ----------------------------------------------------------------------------
{
	my $zorita = fresh_populated();
	my $if     = $zorita->iforest( slug => 'myapp', set => 'http-logs' );

	isa_ok( $if, 'Algorithm::Classifier::IsolationForest', 'iforest()' );
	is_deeply( $if->feature_names, [@TAGS], 'tags forwarded as feature_names' );
	is( $if->decision_threshold, undef, 'unfitted model has no decision threshold yet' );

	# Hyper-parameters from info.json are forwarded verbatim to new().
	is( $if->{n_trees},     50,     'n_trees forwarded' );
	is( $if->{sample_size}, 64,     'sample_size forwarded' );
	is( $if->{seed},        42,     'seed forwarded' );
	is( $if->{missing},     'nan',  'missing forwarded' );
	is( $if->{voting},      'mean', 'voting forwarded' );
}

# The one 'missing' value the storage contract forbids is refused twice over:
# eagerly by write_info, and by iforest() itself for a hand-edited info.json
# that never went through write_info.
{
	my $basedir = tempdir( CLEANUP => 1 );
	my $zorita  = Algorithm::Classifier::IsolationForest::Zorita->new( basedir => $basedir );

	eval { $zorita->write_info( slug => 'myapp', set => 'http-logs',
			info => { tags => [@TAGS], missing => 'die' }, ); };
	like( $@, qr/may not be 'die'/, "write_info refuses missing => 'die'" );

	# simulate a hand-edited info.json that bypassed write_info
	require File::Path;
	require File::Spec;
	my $dir = File::Spec->catdir( $basedir, 'batch', 'myapp', 'http-logs' );
	File::Path::make_path($dir);
	open my $fh, '>', File::Spec->catfile( $dir, $Algorithm::Classifier::IsolationForest::Zorita::INFO_FILE )
		or die "cannot write info.json fixture: $!";
	print {$fh} '{"tags":["' . join( '","', @TAGS ) . '"],"missing":"die"}';
	close $fh;

	eval { $zorita->iforest( slug => 'myapp', set => 'http-logs' ) };
	like( $@, qr/may not be 'die'/, "iforest() croaks on a hand-edited missing => 'die'" );
}

# ----------------------------------------------------------------------------
# rebuild_model(): read the window, fit, and persist.
# ----------------------------------------------------------------------------
{
	my $zorita = fresh_populated();

	ok( !-f $zorita->model_path( slug => 'myapp', set => 'http-logs' ), 'no model file before rebuild' );

	my $model = $zorita->rebuild_model(
		slug => 'myapp',
		set  => 'http-logs',
		time => $NOW
	);

	isa_ok( $model, 'Algorithm::Classifier::IsolationForest', 'rebuild_model() returns a fitted model' );
	ok( defined $model->decision_threshold, 'fitted model learned a decision threshold from contamination' );
	ok( -f $zorita->model_path( slug => 'myapp', set => 'http-logs' ), 'iforest_model.json written to disk' );

	# The obvious outlier (last row read back) must score as an anomaly.
	my $rows   = $zorita->read_back( slug => 'myapp', set => 'http-logs', time => $NOW );
	my $labels = $model->predict($rows);
	is( $labels->[-1], 1, 'the [999,999] outlier is flagged anomalous' );
}

# rebuild_model() has nothing to train on when the window is empty.
{
	my $basedir = tempdir( CLEANUP => 1 );
	my $zorita  = Algorithm::Classifier::IsolationForest::Zorita->new( basedir => $basedir );
	$zorita->write_info( slug => 'myapp', set => 'http-logs', info => {%INFO} );

	eval { $zorita->rebuild_model( slug => 'myapp', set => 'http-logs', time => $NOW ); };
	like( $@, qr/no training data in window/, 'rebuild_model() croaks on an empty window' );
}

# ----------------------------------------------------------------------------
# rebuild_model( from_csv => 1 ): the low-memory streaming path. Trains through
# fit_from_csv from a temp CSV rather than reading the window into RAM. Not
# bit-identical to the default fit(), so this checks behavior, not tree equality:
# a fitted model with a learned threshold that still flags the obvious outlier,
# and -- the point of the streaming path -- no temp file left behind.
# ----------------------------------------------------------------------------
sub train_csv_litter {    # names of any leftover streaming temp files in a set dir
	my ( $zorita, %args ) = @_;
	my $dir = $zorita->set_dir(%args);
	return () unless -d $dir;
	opendir my $dh, $dir or die "cannot read $dir: $!";
	my @litter = sort grep { /\A\.train\./ } readdir $dh;
	closedir $dh;
	return @litter;
}

{
	my $zorita = fresh_populated();

	my $model = $zorita->rebuild_model(
		slug     => 'myapp',
		set      => 'http-logs',
		time     => $NOW,
		from_csv => 1,
	);

	isa_ok( $model, 'Algorithm::Classifier::IsolationForest', 'from_csv rebuild returns a fitted model' );
	ok( defined $model->decision_threshold, 'from_csv rebuild learned a decision threshold' );
	ok( -f $zorita->model_path( slug => 'myapp', set => 'http-logs' ), 'from_csv rebuild wrote iforest_model.json' );

	my $rows = $zorita->read_back( slug => 'myapp', set => 'http-logs', time => $NOW );
	is( $model->predict($rows)->[-1], 1, 'from_csv rebuild still flags the [999,999] outlier' );

	is_deeply( [ train_csv_litter( $zorita, slug => 'myapp', set => 'http-logs' ) ],
		[], 'from_csv rebuild leaves no .train temp file behind' );
}

# from_csv rebuild croaks on an empty window just like the in-RAM path, and does
# not litter a temp file when it bails.
{
	my $basedir = tempdir( CLEANUP => 1 );
	my $zorita  = Algorithm::Classifier::IsolationForest::Zorita->new( basedir => $basedir );
	$zorita->write_info( slug => 'myapp', set => 'http-logs', info => {%INFO} );

	eval { $zorita->rebuild_model( slug => 'myapp', set => 'http-logs', time => $NOW, from_csv => 1 ); };
	like( $@, qr/no training data in window/, 'from_csv rebuild croaks on an empty window' );

	is_deeply( [ train_csv_litter( $zorita, slug => 'myapp', set => 'http-logs' ) ],
		[], 'empty-window from_csv rebuild leaves no temp file behind' );
}

# ----------------------------------------------------------------------------
# load_model(): a faithful reconstruction of the rebuilt model.
# ----------------------------------------------------------------------------
{
	my $zorita = fresh_populated();
	my $built  = $zorita->rebuild_model(
		slug => 'myapp',
		set  => 'http-logs',
		time => $NOW
	);

	my $loaded = $zorita->load_model( slug => 'myapp', set => 'http-logs' );
	isa_ok( $loaded, 'Algorithm::Classifier::IsolationForest', 'load_model()' );
	is_deeply( $loaded->feature_names, [@TAGS], 'loaded model preserves feature_names' );
	is( $loaded->decision_threshold, $built->decision_threshold, 'loaded model preserves the decision threshold' );

	# The whole point: the persisted-then-loaded model scores identically to the
	# freshly rebuilt one, so a rebuild really does round-trip through disk.
	my $rows = $zorita->read_back( slug => 'myapp', set => 'http-logs', time => $NOW );
	is_deeply(
		$loaded->predict($rows),
		$built->predict($rows),
		'loaded model predicts identically to the rebuilt model'
	);
}

# load_model() with nothing rendered yet is an error, not silent undef.
{
	my $basedir = tempdir( CLEANUP => 1 );
	my $zorita  = Algorithm::Classifier::IsolationForest::Zorita->new( basedir => $basedir );
	$zorita->write_info( slug => 'myapp', set => 'http-logs', info => {%INFO} );

	eval { $zorita->load_model( slug => 'myapp', set => 'http-logs' ) };
	like( $@, qr/no model at/, 'load_model() croaks when no model exists' );
}

done_testing();
