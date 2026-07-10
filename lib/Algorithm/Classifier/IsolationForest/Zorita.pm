package Algorithm::Classifier::IsolationForest::Zorita;

use 5.006;
use strict;
use warnings;

use Carp       qw(croak);
use POSIX      qw(strftime);
use File::Path qw(make_path);
use File::Spec;
use JSON::PP     ();
use Scalar::Util qw(looks_like_number);
use Algorithm::Classifier::IsolationForest;
use Algorithm::Classifier::IsolationForest::Zorita::Mungers;

=head1 NAME

Algorithm::Classifier::IsolationForest::Zorita - Structured on-disk storage of Isolation Forest training data.

=head1 VERSION

Version 0.0.1

=cut

our $VERSION = '0.0.1';

=head1 SYNOPSIS

    use Algorithm::Classifier::IsolationForest::Zorita;

    my $zorita = Algorithm::Classifier::IsolationForest::Zorita->new(
        basedir => '/var/db/zorita/',
    );

    # define a set
    $zorita->write_info(
        slug => 'myapp',
        set  => 'http-logs',
        info => {
            tags        => [ 'bytes', 'duration', 'status' ],
            'days_back' => 7,

            # hyper-parameters handed to the Isolation Forest module's new()
            n_trees         => 100,
            sample_size     => 256,
            max_depth       => undef,   # undef => derive from sample_size
            seed            => 42,
            extension_level => 0,
            contamination   => 0.01,
            missing         => 'nan',   # nan | zero | impute  (never 'die')
            impute_with     => 'mean',  # only used when missing => 'impute'
            voting          => 'majority',  # or 'mean' (the default)
        },
    );

    # roll up completed hours/days (see also the Writer for live appends)
    $zorita->combine_hour( slug => 'myapp', set => 'http-logs',
        date => '2026-07-04', hour => '13' );
    $zorita->combine_day(  slug => 'myapp', set => 'http-logs',
        date => '2026-07-04' );

    # (re)train the model from the stored data and render iforest_model.json
    my $model = $zorita->rebuild_model( slug => 'myapp', set => 'http-logs' );
    my $loaded = $zorita->load_model(   slug => 'myapp', set => 'http-logs' );

This module holds the B<utility> logic for laying out, reading, and rolling up
the data described in the project README. Individual data producers should use
L<Algorithm::Classifier::IsolationForest::Zorita::Writer> to append rows.

=head1 LAYOUT

    $basedir/$type/$slug/$set/$date/$hour/

See the README for the full description. In short:

=over 4

=item * C<$basedir> - root dir, default C</var/db/zorita/>.

=item * C<$type> - the model backend the tree holds: C<batch> (built with
L<Algorithm::Classifier::IsolationForest>) or C<online> (built with
L<Algorithm::Classifier::IsolationForest::Online>). Fixed per object at
construction, it is the first path segment, so the two backends live in
side-by-side trees (C<$basedir/batch/...> and C<$basedir/online/...>) that never
share slugs, sets, or templates.

=item * C<$slug>, C<$set> - organizational names, each must match
C<^[A-Za-z0-9\-\_\@\=\+]+$>. In particular the C<.> character is not allowed, so
a name can never begin with a dot (C<^\.>). Leading-dot names are B<reserved>
for control directories that live alongside the slugs under C<$basedir> -- at
present just C<.set_templates> (see L</SET TEMPLATES>) -- so those directories
can never collide with, or be mistaken for, a real slug or set.

=item * C<$date> - C<%Y-%m-%d>.

=item * C<$hour> - C<%H>.

=back

=cut

# The one place the name rule lives, so the Writer can reuse it. Note it forbids
# '.', which is deliberate: a slug/set can therefore never begin with a dot, and
# dot-prefixed control dirs like $TEMPLATE_DIR stay out of their namespace.
our $NAME_REGEXP = qr/\A[A-Za-z0-9\-\_\@\=\+]+\z/;

# Filenames used within the layout.
our $INFO_FILE     = 'info.json';
our $MODEL_FILE    = 'iforest_model.json';
our $COMBINED_FILE = 'combined.csv';
our $DAILY_FILE    = 'daily.csv';

# Online-only runtime files, all living directly in the set dir. An online set
# has no per-row storage and is never rebuilt: it is a live model served over a
# Unix socket (see L<Algorithm::Classifier::IsolationForest::Zorita::Online>),
# persisted streamd-style as timestamped saves under a $LATEST_FILE symlink
# rather than the single $MODEL_FILE a batch set renders.
our $SOCKET_FILE         = 'stream.sock';
our $PID_FILE            = 'stream.pid';
our $LOG_FILE            = 'streamd.log';
our $LATEST_FILE         = 'latest.json';
our $ONLINE_MODEL_PREFIX = 'oiforest-';

# Control directory (reserved, leading-dot name) holding set-template
# "$template.json" files under $basedir. See the SET TEMPLATES section.
our $TEMPLATE_DIR = '.set_templates';
our $TEMPLATE_EXT = '.json';

# The two backends a set can be built for. $type selects one; it is the first
# path segment ($basedir/$type/...) and is echoed into each set's info.json.
our %TYPE_CLASS = (
	batch  => 'Algorithm::Classifier::IsolationForest',
	online => 'Algorithm::Classifier::IsolationForest::Online',
);

# info.json keys forwarded verbatim to the backend's new() by iforest() -- and,
# because they are forwarded verbatim, dry-run through that same new() by
# validate_info(). The two backends take different hyper-parameters, so the
# forwarded slice is chosen per type. Declared up here so both can see it.
our %TYPE_PARAM_KEYS = (
	batch => [
		qw(n_trees sample_size max_depth seed mode extension_level
			contamination missing impute_with voting)
	],
	online => [
		qw(n_trees window_size max_leaf_samples growth subsample
			seed contamination missing)
	],
);

# Param keys whose value is not numeric, so validate_info's numeric-shape pass
# skips them (the backend's new() is the authority on their legal values, via
# the dry-run). Everything else in %TYPE_PARAM_KEYS must look_like_number.
our %NON_NUMERIC_PARAM = map { $_ => 1 } qw(mode missing impute_with voting growth);

=head1 CONSTRUCTOR

=head2 new

    my $zorita = Algorithm::Classifier::IsolationForest::Zorita->new(
        basedir => '/var/db/zorita/',   # optional, default /var/db/zorita/
        type    => 'batch',             # optional, batch (default) or online
    );

C<type> selects the model backend for every set this object touches and fixes
the C<$basedir/$type/...> root (see L</LAYOUT>). It is C<batch> or C<online>;
any other value croaks. To work across both backends, hold one object per type.

=cut

sub new {
	my ( $class, %args ) = @_;

	my $type = defined $args{type} ? $args{type} : 'batch';
	croak "invalid type '$type' (must be one of: " . join( ', ', sort keys %TYPE_CLASS ) . ')'
		unless exists $TYPE_CLASS{$type};

	my $self = {
		basedir => defined $args{basedir} ? $args{basedir} : '/var/db/zorita/',
		type    => $type,
		json    => JSON::PP->new->utf8->canonical->pretty,
	};

	return bless $self, $class;
} ## end sub new

# The root under which this object's slugs (and its per-type .set_templates)
# live: $basedir/$type. Every path builder and the template directory hang off
# this, so inserting the type segment happens in exactly one place.
sub _root {
	my ($self) = @_;
	return File::Spec->catdir( $self->{basedir}, $self->{type} );
}

# Load the backend class for this object's type on demand and return its name.
# The batch class is used at compile time; the online class is optional (it may
# not be installed), so it is required lazily -- only a caller that actually
# builds or validates an online set pays for, or needs, it.
sub _type_class {
	my ($self) = @_;
	if ( $self->{type} eq 'online' ) {
		require Algorithm::Classifier::IsolationForest::Online;
	}
	return $TYPE_CLASS{ $self->{type} };
}

# Guards for the operations that only make sense for one backend. The batch
# data flow (hourly writer files, roll-ups, windowed read-back, rebuild) has no
# meaning for an online set, which stores no rows and learns continuously; the
# online runtime files (socket/pid/log) have no meaning for a batch set. Each
# names the caller so the croak points at what was actually attempted.
sub _assert_batch {
	my ( $self, $what ) = @_;
	croak "$what is not available for online sets (they store no rows and are served, not rebuilt)"
		if $self->{type} eq 'online';
	return 1;
}

sub _assert_online {
	my ( $self, $what ) = @_;
	croak "$what is only available for online sets"
		unless $self->{type} eq 'online';
	return 1;
}

=head1 NAME VALIDATION

=head2 valid_name

    if ( $zorita->valid_name($name) ) { ... }

Returns true if C<$name> is a legal C<$slug> / C<$set> / writer / template name,
i.e. it matches C<$NAME_REGEXP>. Because that pattern excludes C<.>, a valid
name can never begin with a dot -- names matching C<^\.> are always rejected,
keeping the reserved C<.set_templates> control directory out of the slug/set
namespace.

=head2 assert_name

    $zorita->assert_name( $name, 'slug' );

Croaks with a useful message if C<$name> is not legal. C<$what> is only used
for the error text.

=cut

sub valid_name {
	my ( $self, $name ) = @_;
	return ( defined $name && $name =~ $NAME_REGEXP ) ? 1 : 0;
}

sub assert_name {
	my ( $self, $name, $what ) = @_;
	$what = 'name' unless defined $what;
	croak "invalid $what '" . ( defined $name ? $name : '[undef]' ) . "' (must match $NAME_REGEXP)"
		unless $self->valid_name($name);
	return 1;
}

=head1 TIME HELPERS

Given an epoch time (defaulting to now) these return the C<$date> and C<$hour>
components used in the path. Localtime is used so that "hour" matches wall clock.

=head2 datestamp

=head2 hourstamp

=cut

sub datestamp {
	my ( $self, $time ) = @_;
	$time = time unless defined $time;
	return strftime( '%Y-%m-%d', localtime($time) );
}

sub hourstamp {
	my ( $self, $time ) = @_;
	$time = time unless defined $time;
	return strftime( '%H', localtime($time) );
}

=head1 PATH BUILDERS

Each validates the names it is handed, then returns a path string. An explicit
C<date> or C<hour> must match the exact shape the stamps render (C<%Y-%m-%d> /
C<%H>, i.e. C<\d{4}-\d{2}-\d{2}> and C<\d{2}>) -- the same shapes the roll-up
and read-back greps expect, and, since neither admits C</> or C<.>, what keeps
a mistyped or hostile value from escaping the set directory. None of these
touch the filesystem except C<hour_dir($..., mkdir => 1)>.

=head2 slug_dir

=head2 set_dir

=head2 date_dir

=head2 hour_dir

    my $dir = $zorita->hour_dir(
        slug => 'myapp', set => 'http-logs',
        time => time,          # optional; or pass date+hour explicitly
        mkdir => 1,            # optional, create it
    );

=cut

sub slug_dir {
	my ( $self, %args ) = @_;
	$self->assert_name( $args{slug}, 'slug' );
	return File::Spec->catdir( $self->_root, $args{slug} );
}

sub set_dir {
	my ( $self, %args ) = @_;
	$self->assert_name( $args{set}, 'set' );
	return File::Spec->catdir( $self->slug_dir(%args), $args{set} );
}

sub date_dir {
	my ( $self, %args ) = @_;
	my $date = defined $args{date} ? $args{date} : $self->datestamp( $args{time} );
	croak "invalid date '$date' (must be YYYY-MM-DD)"
		unless $date =~ /\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/;
	return File::Spec->catdir( $self->set_dir(%args), $date );
}

sub hour_dir {
	my ( $self, %args ) = @_;
	my $hour = defined $args{hour} ? $args{hour} : $self->hourstamp( $args{time} );
	croak "invalid hour '$hour' (must be two-digit HH)"
		unless $hour =~ /\A[0-9]{2}\z/;
	my $dir = File::Spec->catdir( $self->date_dir(%args), $hour );
	make_path($dir) if $args{mkdir} && !-d $dir;
	return $dir;
}

=head1 DISCOVERY

These enumerate what already exists on disk, so tooling (see the C<zorita>
command) can list slugs and the sets under a slug without knowing the names in
advance. Both return a plain B<list> of names (not an arrayref), sorted, and:

=over 4

=item * skip anything that is not a directory, or whose name does not satisfy
L</valid_name> (so C<.>, C<..>, and stray files are ignored);

=item * return the empty list when the parent directory does not exist yet.

=back

=head2 slugs

    my @slugs = $zorita->slugs;

The name of every slug directory directly under C<basedir>. The reserved
C<.set_templates> control directory is skipped for free: its leading dot fails
L</valid_name>, so it is never mistaken for a slug.

=head2 sets

    my @sets = $zorita->sets( slug => 'myapp' );

The name of every set directory directly under the given slug. The slug name is
validated (via C<slug_dir>) before the directory is read.

=cut

sub slugs {
	my ($self) = @_;
	return $self->_child_dirs( $self->_root );
}

sub sets {
	my ( $self, %args ) = @_;
	return $self->_child_dirs( $self->slug_dir(%args) );
}

# Sorted, name-validated immediate subdirectories of $dir; empty list if $dir is
# absent. Shared by slugs()/sets() so the "valid directory child" rule lives in
# exactly one place. '.'/'..' -- and the reserved '.set_templates' control dir --
# fall out for free since a leading dot cannot match the name regexp.
sub _child_dirs {
	my ( $self, $dir ) = @_;
	return () unless defined $dir && -d $dir;

	opendir my $dh, $dir or croak "cannot read $dir: $!";
	my @names = sort grep { $self->valid_name($_) && -d File::Spec->catdir( $dir, $_ ) } readdir $dh;
	closedir $dh;

	return @names;
} ## end sub _child_dirs

=head1 INFO / MODEL

Each set carries an C<info.json> describing both its CSV shape and the
hyper-parameters used to build its model. The recognized keys are:

=over 4

=item * C<tags> - arrayref of column names, in the order rows are stored.

=item * C<days_back> - default training window in days (see C<read_back>).
Usually a multiple of 7.

=item * C<mungers> - optional hashref mapping a tag name to its input munger (see
L</INPUT MUNGING>). Tags absent from this hash - or the key being absent
entirely - are raw and stored unchanged.

=back

The remaining keys are passed straight through to the backend's C<new> when a
model is (re)built. B<Which keys apply depends on the tree's C<$type>>, since
the two backends take different hyper-parameters; a key the backend does not
recognize is simply not forwarded. C<n_trees>, C<seed>, and C<contamination> are
common to both.

Shared by both backends:

=over 4

=item * C<n_trees> - number of trees in the forest.

=item * C<seed> - RNG seed, for reproducible builds.

=item * C<contamination> - expected proportion of anomalies.

=back

C<batch> only (L<Algorithm::Classifier::IsolationForest>):

=over 4

=item * C<sample_size> - subsample size drawn per tree.

=item * C<max_depth> - maximum tree depth (C<undef> to derive from
C<sample_size>).

=item * C<mode> - C<axis> (classic Isolation Forest) or C<extended> (Extended
Isolation Forest). Required as C<extended> for C<extension_level> to take
effect.

=item * C<extension_level> - extended-isolation-forest extension level (only
meaningful when C<mode> is C<extended>).

=item * C<impute_with> - imputation strategy/value, used only when C<missing>
is C<impute>.

=item * C<voting> - voting strategy used when scoring: C<mean> (the default)
or C<majority>.

=back

C<online> only (L<Algorithm::Classifier::IsolationForest::Online>):

=over 4

=item * C<window_size> - how many most-recent points the model reflects before
it starts forgetting the oldest.

=item * C<max_leaf_samples> - points a leaf accumulates before it splits.

=item * C<growth> - how the split requirement scales with depth: C<adaptive> or
C<fixed>.

=item * C<subsample> - per-tree probability, in C<(0, 1]>, that a tree learns a
given point.

=back

And C<missing>, whose legal values B<differ by type>:

=over 4

=item * C<batch> - one of C<nan>, C<zero>, or C<impute>.

=item * C<online> - only C<zero>. (The backend also accepts C<die>, but the
storage contract forbids it, leaving C<zero> as the sole legal online value;
C<nan> and C<impute> are not online policies at all.)

=back

In neither case is C<die> a valid choice.

The rendered model itself lives alongside C<info.json> as C<iforest_model.json>.
A set is self-describing: L</write_info> stamps the tree's C<$type> into the
stored body as a C<type> key, and L</validate_info> rejects a body whose C<type>
disagrees with the tree it is written into.

=head2 INPUT MUNGING

The stored CSV is raw numeric data, but the values a writer is handed are not
always numeric to begin with (an HTTP method is a string, a timestamp is a
formatted date, and so on). B<Input munging> is how such a value is turned into
the number written to the CSV. It happens on the input side, at write time,
before a row is appended.

A munger is attached to a tag through the optional C<mungers> key. It is a
hashref keyed by tag name; each value selects a B<named built-in munger> by name
and carries whatever parameters that munger needs:

    {
        tags    => [ 'bytes', 'status', 'method' ],
        mungers => {
            method => { munger => 'enum', map => { GET => 0, POST => 1, PUT => 2 } },
        },
    }

Here C<method>'s incoming string is mapped to a number by the C<enum> munger
before it lands in the CSV. C<bytes> and C<status> have no entry in C<mungers>,
so they are B<raw>: their values are passed through untouched and are expected
to already be clean numeric data.

The rule is simple: B<any tag without a munger is raw>. If C<mungers> is absent
entirely, every tag is raw. A raw value is inserted into the CSV verbatim, with
no transformation - the behavior this module had before mungers existed. Only
tags that name a munger are transformed, and only by the built-in the munger
names.

=head2 info_path

=head2 read_info

    my $info = $zorita->read_info( slug => 'myapp', set => 'http-logs' );
    #  { tags => [...], 'days_back' => 7 }

Returns undef if there is no C<info.json> yet.

=head2 info_json

    print $zorita->info_json( slug => 'myapp', set => 'http-logs' );

The set's C<info.json> as its raw on-disk JSON text (a string, trailing newline
and all). Unlike C<read_info>, which decodes to a hashref and returns undef when
absent, this returns exactly what is stored and B<croaks> if the set has no
C<info.json>.

=head2 write_info

    $zorita->write_info( slug => ..., set => ..., info => \%info );

The info body is sanity-checked with L</validate_info> before anything is
written, so a misconfigured set croaks here at creation time rather than much
later. L</write_template> runs the same check, and L</create_set> instantiates
templates through this method, so template bodies are covered both when
written and when instantiated.

The file is written to a temp file and renamed into place, so a concurrent
reader (a writer daemon starting up, C<iforest> at rebuild time) can never
observe a half-written C<info.json>.

=head2 validate_info

    $zorita->validate_info( \%info );

The sanity check behind L</write_info> and L</write_template>, also run by
L<Algorithm::Classifier::IsolationForest::Zorita::Writer/new> at construction
time. Croaks unless the body can safely back a set:

=over 4

=item * C<tags> must each match the standard name rule (see
L</NAME VALIDATION>; among other things that keeps the comma-joined CSV header
well-formed) with no duplicates;

=item * a C<mungers> key has its whole plan compiled (and discarded), catching
unknown munger names, bad parameters, and broken C<into>/C<from>-list coverage
that would otherwise croak on a writer's first row;

=item * C<missing> may not be C<die> (the constraint L</iforest> would enforce
at rebuild time);

=item * the model hyper-parameters -- every key L</iforest> forwards -- are
checked for numeric shape and then dry-run through
C<< Algorithm::Classifier::IsolationForest->new >> itself, so a value the
forest would reject at rebuild time (a C<voting> method it does not have, a
C<contamination> outside C<(0, 0.5]>, ...) croaks while someone is still
looking. The dry-run keeps the forest module the single authority on what it
accepts; this class does not re-state those rules.

=back

Keys the check does not know about pass through untouched. Returns 1 on
success.

=head2 tags

Convenience: returns the C<tags> arrayref from C<info.json>. Croaks if info is
missing, since a writer cannot order its columns without it.

=head2 days_back

Convenience: returns the C<days_back> value.

=cut

sub info_path {
	my ( $self, %args ) = @_;
	return File::Spec->catfile( $self->set_dir(%args), $INFO_FILE );
}

sub read_info {
	my ( $self, %args ) = @_;
	my $path = $self->info_path(%args);
	return undef unless -f $path;
	return $self->{json}->decode( $self->_slurp($path) );
}

sub info_json {
	my ( $self, %args ) = @_;
	my $path = $self->info_path(%args);
	croak "no $INFO_FILE for set '$args{set}' under slug '$args{slug}'"
		unless -f $path;
	return $self->_slurp($path);
}

# _slurp's counterpart: write a whole string to $path atomically, via a temp
# file in the same directory renamed into place, so a concurrent reader can
# never observe a half-written file (the same pattern _rebuild_csv uses for
# combined/daily CSVs). Shared by write_info and write_template. Croaks on any
# I/O failure, removing the temp file first.
sub _write_atomic {
	my ( $self, $path, $data ) = @_;
	my $tmp = "$path.tmp.$$";
	open my $fh, '>', $tmp or croak "cannot write $tmp: $!";
	unless ( print {$fh} $data ) {
		close $fh;
		unlink $tmp;
		croak "cannot write to $tmp: $!";
	}
	unless ( close $fh ) {
		unlink $tmp;
		croak "cannot close $tmp: $!";
	}
	unless ( rename $tmp, $path ) {
		my $err = $!;
		unlink $tmp;
		croak "cannot rename $tmp -> $path: $err";
	}
	return $path;
} ## end sub _write_atomic

# Slurp a whole file into a string. Shared by the JSON readers so the
# open/local-$//read/close incantation lives in one place; croaks on open error.
sub _slurp {
	my ( $self, $path ) = @_;
	open my $fh, '<', $path or croak "cannot read $path: $!";
	local $/;
	my $raw = <$fh>;
	close $fh;
	return $raw;
}

# Shared sanity check for an info body, run by write_info and write_template
# before anything lands on disk, and by Writer->new before a first row can be
# attempted. Catches what would otherwise only surface much later: a corrupt
# CSV header from a bad tag name, a munging plan that cannot compile (a
# writer's first row), a 'missing' policy the model builder refuses, or a
# hyper-parameter Algorithm::Classifier::IsolationForest->new would reject
# (rebuild time). Keys it does not know about pass through untouched.
sub validate_info {
	my ( $self, $info ) = @_;

	croak 'info must be a hashref' unless ref $info eq 'HASH';

	# A set is self-describing: if the body records a 'type', it must be the
	# type of the tree it is being written into. write_info stamps this in, so
	# a template stamped (via create_set) into the wrong-type tree is caught.
	croak "info 'type' ('$info->{type}') does not match this tree's type '$self->{type}'"
		if defined $info->{type} && $info->{type} ne $self->{type};

	if ( defined $info->{tags} ) {
		croak "info 'tags' must be a non-empty arrayref"
			unless ref $info->{tags} eq 'ARRAY' && @{ $info->{tags} };
		my %seen;
		for my $tag ( @{ $info->{tags} } ) {
			# Tags obey the same name rule as slugs and sets. Beyond
			# consistency, this is what keeps the CSV header well-formed: the
			# regexp admits no commas, whitespace, or quoting.
			$self->assert_name( $tag, 'tag' );
			croak "duplicate tag '$tag'" if $seen{$tag}++;
		}
	} ## end if ( defined $info->{tags} )

	# Eager munger validation: compiling the plan runs the full coverage rules
	# (unknown names, bad parameters, broken 'into'); the result is discarded.
	if ( $info->{mungers} ) {
		croak "info with 'mungers' requires a non-empty 'tags' arrayref"
			unless ref $info->{tags} eq 'ARRAY' && @{ $info->{tags} };
		Algorithm::Classifier::IsolationForest::Zorita::Mungers->compile(
			tags    => $info->{tags},
			mungers => $info->{mungers},
		);
	}

	# Mirror iforest()'s constraint so a forbidden 'missing' policy fails at
	# write time; iforest() keeps its own check for hand-edited info.json files.
	# This must stay ahead of the dry-run below, which would happily accept a
	# policy each backend allows but the storage contract does not. The two
	# backends differ: batch takes nan|zero|impute (die is the forest default,
	# which we forbid); online takes only die|zero, so with die forbidden the
	# sole legal online policy is zero.
	if ( defined $info->{missing} ) {
		if ( $self->{type} eq 'online' ) {
			croak "info 'missing' for an online set must be 'zero' (not '$info->{missing}')"
				unless $info->{missing} eq 'zero';
		} else {
			croak "info 'missing' may not be 'die' (use nan, zero, or impute)"
				if $info->{missing} eq 'die';
		}
	}

	# Hyper-parameter sanity, in two layers. First a thin numeric pass over the
	# backend's numeric keys -- the ones its new() silently coerces (a bogus
	# 'seed' is int()'d to 0) or does not examine until fit()/learn()
	# ('max_depth') -- then a dry-run of new() itself on exactly the slice
	# iforest() forwards, object discarded, so what write time accepts can never
	# drift from what rebuild_model does. Both are keyed off the type, so an
	# online body is judged by online's parameters and class, not batch's.
	my $type = $self->{type};
	for my $key ( @{ $TYPE_PARAM_KEYS{$type} } ) {
		next if $NON_NUMERIC_PARAM{$key};
		next unless defined $info->{$key};
		croak "info '$key' ('$info->{$key}') is not numeric"
			unless looks_like_number( $info->{$key} );
	}
	croak "info 'max_depth' must be >= 1"
		if defined $info->{max_depth} && $info->{max_depth} < 1;

	my %params;
	for my $key ( @{ $TYPE_PARAM_KEYS{$type} } ) {
		$params{$key} = $info->{$key} if exists $info->{$key};
	}
	my $class = $self->_type_class;
	eval { $class->new(%params); 1 }
		or croak "info model parameters unusable by ${class}->new: $@";

	return 1;
} ## end sub validate_info

sub write_info {
	my ( $self, %args ) = @_;
	my $info = $args{info} or croak 'write_info requires info => \%info';

	# Stamp the tree's type into the body so the stored set is self-describing;
	# a body that already names a (matching) type keeps it, a conflicting one is
	# rejected by validate_info below.
	$info->{type} = $self->{type} unless defined $info->{type};
	$self->validate_info($info);

	my $dir = $self->set_dir(%args);
	make_path($dir) unless -d $dir;

	my $path = File::Spec->catfile( $dir, $INFO_FILE );
	return $self->_write_atomic( $path, $self->{json}->encode($info) );
} ## end sub write_info

sub tags {
	my ( $self, %args ) = @_;
	my $info = $self->read_info(%args)
		or croak "no $INFO_FILE for set '$args{set}' under slug '$args{slug}'";
	croak "$INFO_FILE has no 'tags'" unless ref $info->{tags} eq 'ARRAY';
	return $info->{tags};
}

sub days_back {
	my ( $self, %args ) = @_;
	my $info = $self->read_info(%args) or return undef;
	return $info->{'days_back'};
}

=head1 SET TEMPLATES

A B<set template> is a ready-made C<info.json> body kept under the reserved
control directory C<$basedir/$type/.set_templates/> as C<$template$TEMPLATE_EXT>
(i.e. C<$template.json>). Because a slug/set name may never begin with a dot
(see L</NAME VALIDATION>), this directory can never collide with a real slug,
and C<slugs()> never reports it. It sits inside the per-type root, so C<batch>
and C<online> keep separate template sets -- which matters because a template
body valid for one backend (a C<voting> policy, C<missing =E<gt> nan>) is not
necessarily valid for the other.

Templates let you stamp out consistently-configured sets: pick a template by
name and L</create_set> writes its JSON verbatim as the new set's C<info.json>
under the chosen slug. Template names obey the same rule as slugs and sets.

    # one-time: drop a template on disk (or write the file yourself)
    $zorita->write_template(
        template => 'http',
        info     => { tags => [qw(bytes duration status)], 'days_back' => 7, ... },
    );

    my @have = $zorita->templates;                 # ('http', ...)

    # instantiate: myapp/http-logs/info.json becomes a copy of http.json
    $zorita->create_set(
        slug => 'myapp', set => 'http-logs', template => 'http' );

=head2 template_dir

    my $dir = $zorita->template_dir;

Path to the C<.set_templates> directory under C<basedir>. Does not create it.

=head2 template_path

    my $path = $zorita->template_path( template => 'http' );

Path to a single template's JSON file. The template name is validated.

=head2 templates

    my @names = $zorita->templates;

Sorted list of the template names available (the C<.json> files in
C<template_dir>, with the extension stripped). Files whose stripped name is not
a L</valid_name> are ignored, and the list is empty when C<template_dir> does
not exist.

=head2 read_template

    my $info = $zorita->read_template( template => 'http' );

Decodes and returns a template's JSON as a hashref. Croaks if the template does
not exist.

=head2 template_json

    print $zorita->template_json( template => 'http' );

A template's raw on-disk JSON text (a string). Like L</read_template> but
returns the stored text verbatim instead of a decoded hashref; croaks if the
template does not exist.

=head2 write_template

    $zorita->write_template( template => 'http', info => \%info );

Writes C<\%info> as C<$template.json> in C<template_dir>, creating the directory
if needed (atomically, like L</write_info>). Returns the path written. The body
gets the same sanity check as
L</write_info> (tag names, munger plan, C<missing> policy), so a broken template
is refused at write time instead of poisoning every set stamped from it. Handy
for seeding templates programatically; you may equally just drop a JSON file
into C<.set_templates> by hand -- hand-dropped files skip this check but are
still validated when L</create_set> instantiates them.

=head2 create_set

    $zorita->create_set( slug => 'myapp', set => 'http-logs', template => 'http' );

Creates the set C<$slug/$set> by writing the named template's JSON as its
C<info.json> (via L</write_info>). Croaks if the template is missing, or if the
set already has an C<info.json> (it will not clobber an existing set). Returns
the path to the written C<info.json>.

=cut

sub template_dir {
	my ($self) = @_;
	return File::Spec->catdir( $self->_root, $TEMPLATE_DIR );
}

sub template_path {
	my ( $self, %args ) = @_;
	$self->assert_name( $args{template}, 'template' );
	return File::Spec->catfile( $self->template_dir, $args{template} . $TEMPLATE_EXT );
}

sub templates {
	my ($self) = @_;
	my $dir = $self->template_dir;
	return () unless -d $dir;

	opendir my $dh, $dir or croak "cannot read $dir: $!";
	my @files = readdir $dh;
	closedir $dh;

	my $ext = quotemeta $TEMPLATE_EXT;
	my @names;
	for my $file (@files) {
		next unless $file =~ /\A(.+)$ext\z/;
		my $name = $1;
		push @names, $name if $self->valid_name($name);
	}
	# sort into a named array: a bare 'return sort ...' is undefined in
	# scalar context (perlcritic ProhibitReturnSort).
	my @sorted = sort @names;
	return @sorted;
} ## end sub templates

sub read_template {
	my ( $self, %args ) = @_;
	return $self->{json}->decode( $self->template_json(%args) );
}

sub template_json {
	my ( $self, %args ) = @_;
	my $path = $self->template_path(%args);
	croak "no template '$args{template}' at $path" unless -f $path;
	return $self->_slurp($path);
}

sub write_template {
	my ( $self, %args ) = @_;
	my $info = $args{info} or croak 'write_template requires info => \%info';

	# Templates live in a per-type .set_templates dir, so they carry the tree's
	# type too -- create_set stamps them into a same-type set, and the type
	# travels with the body rather than being re-derived at instantiation.
	$info->{type} = $self->{type} unless defined $info->{type};
	$self->validate_info($info);

	my $dir = $self->template_dir;
	make_path($dir) unless -d $dir;

	my $path = $self->template_path(%args);
	return $self->_write_atomic( $path, $self->{json}->encode($info) );
} ## end sub write_template

sub create_set {
	my ( $self, %args ) = @_;
	croak 'create_set requires template => $name'
		unless defined $args{template};

	my $existing = $self->info_path(%args);    # validates slug/set names too
	croak "set '$args{set}' already exists under slug '$args{slug}'"
		if -f $existing;

	my $info = $self->read_template( template => $args{template} );
	return $self->write_info(
		slug => $args{slug},
		set  => $args{set},
		info => $info,
	);
} ## end sub create_set

=head1 ROLL-UPS

These aggregate the finer-grained files into coarser ones. Per the README they
should only run once the window in question has fully passed, so the caller
(cron, a reaper, etc.) is responsible for I<when>; these just do the work.

=head2 combine_hour

    $zorita->combine_hour(
        slug => ..., set => ..., date => '2026-07-04', hour => '13' );

Concatenates every C<w.*.csv> in the hour directory into C<combined.csv> in the
same directory. Rows are assumed already column-ordered by each writer (the
Writer guarantees this from C<info.json>).

=head2 combine_day

    $zorita->combine_day( slug => ..., set => ..., date => '2026-07-04' );

Concatenates every hour's C<combined.csv> under C<$date> into C<daily.csv> in
the date directory.

=cut

sub combine_hour {
	my ( $self, %args ) = @_;
	$self->_assert_batch('combine_hour');
	my $dir = $self->hour_dir(%args);
	croak "hour dir does not exist: $dir" unless -d $dir;

	opendir my $dh, $dir or croak "cannot read $dir: $!";
	my @writer_files = sort grep { /\Aw\..+\.csv\z/ } readdir $dh;
	closedir $dh;

	my $out = File::Spec->catfile( $dir, $COMBINED_FILE );
	$self->_rebuild_csv( $out, $self->tags(%args), map { File::Spec->catfile( $dir, $_ ) } @writer_files );
	return $out;
} ## end sub combine_hour

sub combine_day {
	my ( $self, %args ) = @_;
	$self->_assert_batch('combine_day');
	my $dir = $self->date_dir(%args);
	croak "date dir does not exist: $dir" unless -d $dir;

	opendir my $dh, $dir or croak "cannot read $dir: $!";
	my @hours = sort grep { /\A\d{2}\z/ && -d File::Spec->catdir( $dir, $_ ) } readdir $dh;
	closedir $dh;

	my @combined = grep { -f $_ }
		map { File::Spec->catfile( $dir, $_, $COMBINED_FILE ) } @hours;

	my $out = File::Spec->catfile( $dir, $DAILY_FILE );
	$self->_rebuild_csv( $out, $self->tags(%args), @combined );
	return $out;
} ## end sub combine_day

# Rebuild "$header + all data rows from @inputs" into $out, atomically.
#
# The data is raw numeric CSV -- plain numbers separated by commas, with no
# quoting, spaces, or escaping -- so we handle it with join/split rather than a
# CSV parser. Every input (writer files, and the combined.csv files fed to
# combine_day) carries its own single header row; those per-input headers are
# dropped and one fresh header ($tags) is emitted. Any data line that is not
# clean numeric is dropped here (see _numeric_line). The result is written to a
# temp file and renamed into place, so a reader (e.g. read_back) never observes
# a half-written combined/daily file -- these are atomically REPLACED, not
# appended to.
sub _rebuild_csv {
	my ( $self, $out, $tags, @inputs ) = @_;

	my $tmp = "$out.tmp.$$";
	open my $ofh, '>', $tmp or croak "cannot write $tmp: $!";
	print {$ofh} join( ',', @$tags ), "\n";    # fresh header

	for my $in (@inputs) {
		print {$ofh} $_, "\n" for @{ $self->_read_data_lines($in) };
	}
	close $ofh or croak "cannot close $tmp: $!";

	rename $tmp, $out or croak "cannot rename $tmp -> $out: $!";
	return $out;
} ## end sub _rebuild_csv

=head1 READING BACK FOR TRAINING

=head2 read_back

    my $rows = $zorita->read_back(
        slug  => 'myapp',
        set   => 'http-logs',
        hours => 168,          # optional; defaults to (days_back * 24)
        time  => time,         # optional "now"
    );

Returns an arrayref of rows (each an arrayref of column values in C<tags>
order) covering the last C<hours> hours up to C<time>. The header rows are
stripped; only data rows are returned.

This is the payoff of the hourly directory: rather than being forced to read
whole C<daily.csv> files (which would over-shoot the window by up to a day),
we read completed days from C<daily.csv> and top up the leading/trailing
partial days from the per-hour C<combined.csv> / C<w.*.csv> files. That way a
168h request really covers 168h instead of collapsing to 6 usable days.

Algorithm:

=over 4

=item 1. C<window_start = time - hours*3600>.

=item 2. Walk the window one hour at a time and record the C<(date, hour)>
slots it touches. Keying on the rendered strings dedupes the repeated hour at a
DST fall-back and skips the non-existent hour at spring-forward.

=item 3. For each date: if the window covers all 24 hours B<and> the day has
fully passed (not today), read the single C<daily.csv> fast path. Otherwise
read just the touched hours, preferring each hour's C<combined.csv> and falling
back to merging its live C<w.*.csv> files.

=back

Missing files are treated as empty, so a window extending before data existed
simply yields fewer rows.

=cut

sub read_back {
	my ( $self, %args ) = @_;
	$self->_assert_batch('read_back');

	my $now = defined $args{time} ? $args{time} : time;

	my $hours = $args{hours};
	if ( !defined $hours ) {
		my $db = $self->days_back(%args);
		croak "no 'hours' given and no 'days_back' in $INFO_FILE"
			unless defined $db;
		$hours = $db * 24;
	}

	my $window_start = $now - $hours * 3600;

	# Collect the (date, hour) slots the window touches.
	my %slots;
	for ( my $t = $window_start; $t <= $now; $t += 3600 ) {
		$slots{ $self->datestamp($t) }{ $self->hourstamp($t) } = 1;
	}

	my $today = $self->datestamp($now);

	my @rows;
	for my $date ( sort keys %slots ) {
		my @hours = sort keys %{ $slots{$date} };

		# daily.csv is only safe when the window spans the whole day and the day
		# has fully passed -- today's daily.csv does not exist / is incomplete.
		my $whole_day = ( @hours == 24 ) && ( $date ne $today );
		my $daily     = File::Spec->catfile( $self->date_dir( %args, date => $date ), $DAILY_FILE );

		if ( $whole_day && -f $daily ) {
			push @rows, @{ $self->_read_csv_data($daily) };
		} else {
			# Partial day (or no daily.csv yet): read the specific hours. This
			# is exactly what the hourly dir buys us -- topping up part of a day
			# instead of swallowing or dropping a whole daily.csv.
			for my $hour (@hours) {
				push @rows, @{ $self->_read_hour_rows( %args, date => $date, hour => $hour ) };
			}
		}
	} ## end for my $date ( sort keys %slots )

	return \@rows;
} ## end sub read_back

# A raw-numeric CSV data line is plain numbers separated by commas: no header,
# no quotes, no spaces, no empty fields. Returns the cleaned line (EOL stripped)
# if it qualifies, else undef -- callers use that to drop bad lines.
sub _numeric_line {
	my ( $self, $line ) = @_;
	return undef unless defined $line;
	$line =~ s/\r?\n\z//;
	return undef if $line eq '';
	for my $field ( split /,/, $line, -1 ) {
		return undef if $field =~ /\s/;                   # no spaces/tabs/etc
		return undef unless looks_like_number($field);    # numeric (incl nan/inf)
	}
	return $line;
} ## end sub _numeric_line

# Header-dropped, numeric-validated data lines (EOL stripped) from one file.
# Non-numeric lines are dropped. Returns [] if the file is absent.
sub _read_data_lines {
	my ( $self, $path ) = @_;
	return [] unless -f $path;

	open my $fh, '<', $path or croak "cannot read $path: $!";
	my @lines;
	my $first = 1;
	while ( my $line = <$fh> ) {
		if ($first) { $first = 0; next; }    # header
		my $clean = $self->_numeric_line($line);
		push @lines, $clean if defined $clean;
	}
	close $fh;
	return \@lines;
} ## end sub _read_data_lines

# Data rows (header dropped, non-numeric dropped) from one CSV file, each split
# into an arrayref of field values; [] if the file is absent.
sub _read_csv_data {
	my ( $self, $path ) = @_;
	return [ map { [ split /,/, $_, -1 ] } @{ $self->_read_data_lines($path) } ];
}

# Data rows for a single hour: prefer the rolled-up combined.csv, otherwise
# merge the live per-writer w.*.csv files (each of which carries its own header).
sub _read_hour_rows {
	my ( $self, %args ) = @_;
	my $dir = $self->hour_dir(%args);
	return [] unless -d $dir;

	my $combined = File::Spec->catfile( $dir, $COMBINED_FILE );
	return $self->_read_csv_data($combined) if -f $combined;

	opendir my $dh, $dir or croak "cannot read $dir: $!";
	my @writer_files = sort grep { /\Aw\..+\.csv\z/ } readdir $dh;
	closedir $dh;

	my @rows;
	for my $wf (@writer_files) {
		push @rows, @{ $self->_read_csv_data( File::Spec->catfile( $dir, $wf ) ) };
	}
	return \@rows;
} ## end sub _read_hour_rows

=head1 MODELS

These tie the stored data together with L<Algorithm::Classifier::IsolationForest>:
build a classifier from a set's C<info.json>, (re)train it from the data
C<read_back> returns, and persist/load the rendered model as C<iforest_model.json>.

=head2 model_path

    my $path = $zorita->model_path( slug => ..., set => ... );

Path to the set's C<iforest_model.json>.

=head2 iforest

    my $if = $zorita->iforest( slug => 'myapp', set => 'http-logs' );

Builds a fresh (unfitted) L<Algorithm::Classifier::IsolationForest> from the
set's C<info.json>. The recognized hyper-parameter keys (see L</INFO / MODEL>)
are forwarded to its C<new>, and C<tags> becomes the model's C<feature_names>.

C<missing> may not be C<die> here (per the storage contract); it croaks if so.

=head2 rebuild_model

    my $if = $zorita->rebuild_model(
        slug  => 'myapp',
        set   => 'http-logs',
        hours => 168,          # optional; else 'days_back' * 24 from info.json
        time  => time,         # optional "now"
    );

Reads the training window with C<read_back>, builds the classifier with
C<iforest>, C<fit>s it, and atomically saves the result to
C<iforest_model.json>. Returns the fitted model. Croaks if the window contains
no rows (nothing to train on).

=head2 load_model

    my $if = $zorita->load_model( slug => 'myapp', set => 'http-logs' );

Loads the previously rendered model from C<iforest_model.json>. Croaks if it
does not exist yet.

=cut

sub model_path {
	my ( $self, %args ) = @_;

	# A batch set renders one iforest_model.json. An online set is persisted
	# streamd-style: timestamped saves under a latest.json symlink, so its
	# "model path" is that symlink -- which load_model follows to the newest
	# save. Following it also means load_model keeps returning the online object
	# (the batch loader auto-delegates on the format tag).
	my $file = $self->{type} eq 'online' ? $LATEST_FILE : $MODEL_FILE;
	return File::Spec->catfile( $self->set_dir(%args), $file );
} ## end sub model_path

=head2 socket_path

=head2 pid_path

=head2 log_path

=head2 latest_path

    my $sock = $zorita->socket_path( slug => 'myapp', set => 'stream' );

The online runtime files, each directly in the set dir: the Unix socket the
daemon listens on, its pid file, its log, and the C<latest.json> symlink the
timestamped saves are flipped through (an alias for L</model_path> on an online
set). All croak for a batch set, which has none of these. See
L<Algorithm::Classifier::IsolationForest::Zorita::Online>.

=cut

sub socket_path {
	my ( $self, %args ) = @_;
	$self->_assert_online('socket_path');
	return File::Spec->catfile( $self->set_dir(%args), $SOCKET_FILE );
}

sub pid_path {
	my ( $self, %args ) = @_;
	$self->_assert_online('pid_path');
	return File::Spec->catfile( $self->set_dir(%args), $PID_FILE );
}

sub log_path {
	my ( $self, %args ) = @_;
	$self->_assert_online('log_path');
	return File::Spec->catfile( $self->set_dir(%args), $LOG_FILE );
}

sub latest_path {
	my ( $self, %args ) = @_;
	$self->_assert_online('latest_path');
	return File::Spec->catfile( $self->set_dir(%args), $LATEST_FILE );
}

sub iforest {
	my ( $self, %args ) = @_;

	my $info = $self->read_info(%args)
		or croak "no $INFO_FILE for set '$args{set}' under slug '$args{slug}'";

	# die is forbidden for both backends here (the storage contract): batch
	# rejects it outright, and although online's own new() accepts die, a
	# hand-edited online info.json must not smuggle it back in.
	croak "info.json 'missing' may not be 'die' (use nan, zero, or impute)"
		if defined $info->{missing} && $info->{missing} eq 'die';

	my %params;
	for my $key ( @{ $TYPE_PARAM_KEYS{ $self->{type} } } ) {
		$params{$key} = $info->{$key} if exists $info->{$key};
	}

	# the column tags double as the model's per-feature labels.
	$params{feature_names} = $info->{tags} if ref $info->{tags} eq 'ARRAY';

	# An online set has no write-time Writer to pre-munge rows into numbers, so
	# the model itself carries the munging plan and applies it to tagged rows as
	# they stream in. A batch set's rows are already munged on disk, so its model
	# never needs it.
	$params{mungers} = $info->{mungers}
		if $self->{type} eq 'online' && ref $info->{mungers} eq 'HASH';

	return $self->_type_class->new(%params);
} ## end sub iforest

sub rebuild_model {
	my ( $self, %args ) = @_;

	# Only batch sets are rebuilt. An online set has no stored rows to read back
	# and learns continuously as its daemon runs, so there is nothing to rebuild
	# from -- run the daemon (Zorita::Online) instead.
	$self->_assert_batch('rebuild_model');

	my $rows = $self->read_back(%args);
	croak "no training data in window for set '$args{set}' under slug '$args{slug}'"
		unless @$rows;

	my $model = $self->iforest(%args);
	$model->fit($rows);
	$model->save( $self->model_path(%args) );    # atomic write

	return $model;
} ## end sub rebuild_model

sub load_model {
	my ( $self, %args ) = @_;

	my $path = $self->model_path(%args);
	croak "no model at $path" unless -f $path;

	return Algorithm::Classifier::IsolationForest->load($path);
}

=head1 SEE ALSO

L<Algorithm::Classifier::IsolationForest::Zorita::Writer> (appends rows to a
batch set), L<Algorithm::Classifier::IsolationForest::Zorita::Online> (serves an
online set's live model over a Unix socket).

=head1 AUTHOR

Zane C. Bowers-Hadley, C<< <vvelox at vvelox.net> >>

=head1 LICENSE AND COPYRIGHT

This software is Copyright (c) 2026 by Zane C. Bowers-Hadley.

This is free software, licensed under:

  The GNU Lesser General Public License, Version 2.1, February 1999

=cut

1;    # End of Algorithm::Classifier::IsolationForest::Zorita
