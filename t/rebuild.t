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
use File::Spec;

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

# A from_csv rebuild whose iforest() croaks (here a hand-edited missing => 'die'
# that write_info would have refused) must not orphan the streaming temp file:
# the model is built -- and thus validated -- before the window is streamed, so
# a validation failure never leaves a .train file behind.
{
	my $zorita = fresh_populated();    # 41 rows in the current hour

	# smuggle missing => 'die' straight into info.json, bypassing write_info.
	my $info = File::Spec->catfile(
		$zorita->set_dir( slug => 'myapp', set => 'http-logs' ),
		$Algorithm::Classifier::IsolationForest::Zorita::INFO_FILE
	);
	open my $fh, '>', $info or die "cannot rewrite info.json fixture: $!";
	print {$fh} '{"tags":["x","y"],"days_back":7,"n_trees":50,"sample_size":64,"seed":42,"missing":"die"}';
	close $fh;

	eval { $zorita->rebuild_model( slug => 'myapp', set => 'http-logs', time => $NOW, from_csv => 1 ); };
	like( $@, qr/may not be 'die'/, 'from_csv rebuild croaks on a hand-edited missing => die' );

	is_deeply( [ train_csv_litter( $zorita, slug => 'myapp', set => 'http-logs' ) ],
		[], 'a croaking iforest() during from_csv rebuild leaves no temp file behind' );
}

# The streaming path must feed fit_from_csv exactly the rows read_back hands the
# in-RAM path: same files, same header strip, same numeric filter. _window_to_csv
# reports the row count it wrote; assert it matches read_back, then clean up the
# temp file it created. Returns ($streamed_count, $in_ram_count) for the caller.
sub window_counts {
	my ( $zorita, %args ) = @_;
	my ( $tmp,    $n )    = $zorita->_window_to_csv(%args);
	my $ram = scalar @{ $zorita->read_back(%args) };
	unlink $tmp if defined $tmp && -f $tmp;
	return ( $n, $ram );
}

{
	my $zorita = fresh_populated();    # 41 rows in the current hour
	my ( $streamed, $in_ram ) = window_counts( $zorita, slug => 'myapp', set => 'http-logs', time => $NOW );
	is( $in_ram,   41,      'read_back sees all 41 current-hour rows' );
	is( $streamed, $in_ram, 'streaming window count matches read_back over live hour files' );
}

# ----------------------------------------------------------------------------
# The whole-day branch of the window walk: rows rolled up into a past day's
# daily.csv must be read back -- and streamed -- from that daily.csv rather than
# the live hour files. Exercises the daily/combined path both rebuilds share (the
# current-hour tests above only ever touch live w.*.csv files).
# ----------------------------------------------------------------------------
{
	my $basedir = tempdir( CLEANUP => 1 );
	my $zorita  = Algorithm::Classifier::IsolationForest::Zorita->new( basedir => $basedir );
	$zorita->write_info( slug => 'myapp', set => 'http-logs', info => {%INFO} );

	my $writer = Algorithm::Classifier::IsolationForest::Zorita::Writer->new(
		zorita => $zorita,
		slug   => 'myapp',
		set    => 'http-logs',
		writer => 'web01',
	);
	my $YESTERDAY = $NOW - 86400;                          # one day before "now", still inside days_back
	$writer->write( [ $_ % 5, ( $_ * 2 ) % 7 ], time => $YESTERDAY ) for 1 .. 40;
	$writer->write( [ 999, 999 ], time => $YESTERDAY );    # the anomaly, written last

	# roll the hour up into combined.csv, then the day up into daily.csv.
	my $date = $zorita->datestamp($YESTERDAY);
	my $hour = $zorita->hourstamp($YESTERDAY);
	$zorita->combine_hour( slug => 'myapp', set => 'http-logs', date => $date, hour => $hour );
	$zorita->combine_day( slug => 'myapp', set => 'http-logs', date => $date );

	my $daily = File::Spec->catfile(
		$zorita->date_dir( slug => 'myapp', set => 'http-logs', date => $date ),
		$Algorithm::Classifier::IsolationForest::Zorita::DAILY_FILE
	);
	ok( -f $daily, 'combine_day rolled the past day up into daily.csv' );

	# time => $NOW makes yesterday a whole past day, so the window walk uses
	# daily.csv; both readers must pull all 41 rows from it.
	my ( $streamed, $in_ram ) = window_counts( $zorita, slug => 'myapp', set => 'http-logs', time => $NOW );
	is( $in_ram,   41,      'read_back pulls all 41 rows from the past day daily.csv' );
	is( $streamed, $in_ram, 'streaming window count matches read_back over daily.csv' );

	# and both rebuild paths train from daily.csv and still flag the outlier.
	for my $from_csv ( 0, 1 ) {
		my $model = $zorita->rebuild_model(
			slug     => 'myapp',
			set      => 'http-logs',
			time     => $NOW,
			from_csv => $from_csv,
		);
		my $rows = $zorita->read_back( slug => 'myapp', set => 'http-logs', time => $NOW );
		is( $model->predict($rows)->[-1],
			1, ( $from_csv ? 'from_csv' : 'in-RAM' ) . ' rebuild over daily.csv flags the [999,999] outlier' );
	} ## end for my $from_csv ( 0, 1 )
}

# ----------------------------------------------------------------------------
# The --hours override narrows the window: data older than the window is
# excluded, so a too-small --hours turns a populated set into an empty-window
# croak -- for both the in-RAM and streaming paths.
# ----------------------------------------------------------------------------
for my $from_csv ( 0, 1 ) {
	my $label = $from_csv ? 'from_csv' : 'in-RAM';

	my $basedir = tempdir( CLEANUP => 1 );
	my $zorita  = Algorithm::Classifier::IsolationForest::Zorita->new( basedir => $basedir );
	$zorita->write_info( slug => 'myapp', set => 'http-logs', info => {%INFO} );

	my $writer = Algorithm::Classifier::IsolationForest::Zorita::Writer->new(
		zorita => $zorita,
		slug   => 'myapp',
		set    => 'http-logs',
		writer => 'web01',
	);
	my $OLD = $NOW - 10 * 3600;    # ten hours before "now"
	$writer->write( [ $_ % 5, ( $_ * 2 ) % 7 ], time => $OLD ) for 1 .. 40;

	# the default days_back (7d) window still sees the ten-hour-old rows...
	my $rows = $zorita->read_back( slug => 'myapp', set => 'http-logs', time => $NOW );
	is( scalar @$rows, 40, "$label: default days_back window includes the 10-hour-old data" );

	# ...but a one-hour window excludes them, leaving nothing to train on.
	eval {
		$zorita->rebuild_model(
			slug     => 'myapp',
			set      => 'http-logs',
			time     => $NOW,
			hours    => 1,
			from_csv => $from_csv,
		);
	};
	like( $@, qr/no training data in window/, "$label: hours => 1 narrows the window to empty" );
} ## end for my $from_csv ( 0, 1 )

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
