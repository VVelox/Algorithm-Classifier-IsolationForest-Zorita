package Algorithm::Classifier::IsolationForest::Zorita;

use 5.006;
use strict;
use warnings;

use Carp qw(croak);
use POSIX qw(strftime);
use File::Path qw(make_path);
use File::Spec;
use JSON::PP ();
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
            voting          => 'soft',
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

    $basedir/$slug/$set/$date/$hour/

See the README for the full description. In short:

=over 4

=item * C<$basedir> - root dir, default C</var/db/zorita/>.

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

# Control directory (reserved, leading-dot name) holding set-template
# "$template.json" files under $basedir. See the SET TEMPLATES section.
our $TEMPLATE_DIR = '.set_templates';
our $TEMPLATE_EXT = '.json';

=head1 CONSTRUCTOR

=head2 new

    my $zorita = Algorithm::Classifier::IsolationForest::Zorita->new(
        basedir => '/var/db/zorita/',   # optional
    );

=cut

sub new {
    my ( $class, %args ) = @_;

    my $self = {
        basedir => defined $args{basedir} ? $args{basedir} : '/var/db/zorita/',
        json    => JSON::PP->new->utf8->canonical->pretty,
    };

    return bless $self, $class;
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
    croak "invalid $what '" . ( defined $name ? $name : '[undef]' )
        . "' (must match $NAME_REGEXP)"
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

Each validates the names it is handed, then returns a path string. None of
these touch the filesystem except C<hour_dir($..., mkdir => 1)>.

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
    return File::Spec->catdir( $self->{basedir}, $args{slug} );
}

sub set_dir {
    my ( $self, %args ) = @_;
    $self->assert_name( $args{set}, 'set' );
    return File::Spec->catdir( $self->slug_dir(%args), $args{set} );
}

sub date_dir {
    my ( $self, %args ) = @_;
    my $date = defined $args{date} ? $args{date} : $self->datestamp( $args{time} );
    return File::Spec->catdir( $self->set_dir(%args), $date );
}

sub hour_dir {
    my ( $self, %args ) = @_;
    my $hour = defined $args{hour} ? $args{hour} : $self->hourstamp( $args{time} );
    my $dir  = File::Spec->catdir( $self->date_dir(%args), $hour );
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
    return $self->_child_dirs( $self->{basedir} );
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
    my @names = sort grep {
        $self->valid_name($_) && -d File::Spec->catdir( $dir, $_ )
    } readdir $dh;
    closedir $dh;

    return @names;
}

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

The remaining keys are passed straight through to the Isolation Forest module's
C<new> when a model is (re)built:

=over 4

=item * C<n_trees> - number of trees in the forest.

=item * C<sample_size> - subsample size drawn per tree.

=item * C<max_depth> - maximum tree depth (C<undef> to derive from
C<sample_size>).

=item * C<seed> - RNG seed, for reproducible builds.

=item * C<mode> - C<axis> (classic Isolation Forest) or C<extended> (Extended
Isolation Forest). Required as C<extended> for C<extension_level> to take
effect.

=item * C<extension_level> - extended-isolation-forest extension level (only
meaningful when C<mode> is C<extended>).

=item * C<contamination> - expected proportion of anomalies.

=item * C<missing> - how missing values are handled: one of C<nan>, C<zero>, or
C<impute>. Note that C<die> is B<not> a valid choice here.

=item * C<impute_with> - imputation strategy/value, used only when C<missing>
is C<impute>.

=item * C<voting> - voting strategy used when scoring.

=back

The rendered model itself lives alongside C<info.json> as C<iforest_model.json>.

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

The info body is sanity-checked before anything is written, so a misconfigured
set croaks here at creation time rather than much later: C<tags> must each match
the standard name rule (see L</NAME VALIDATION>; among other things that keeps
the comma-joined CSV header well-formed) with no duplicates; a C<mungers> key
has its whole plan compiled (and discarded),
catching unknown munger names, bad parameters, and broken C<into> coverage that
would otherwise croak on a writer's first row; and C<missing> may not be C<die>
(the constraint L</iforest> would enforce at rebuild time). L</write_template>
runs the same check, and L</create_set> instantiates templates through this
method, so template bodies are covered both when written and when instantiated.

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
# before anything lands on disk. Catches what would otherwise only surface much
# later: a corrupt CSV header from a bad tag name, a munging plan that cannot
# compile (a writer's first row), or a 'missing' policy the model builder
# refuses (rebuild time). Keys it does not know about pass through untouched --
# the hyper-parameters stay the forest module's job to validate.
sub _validate_info {
    my ( $self, $info ) = @_;

    croak 'info must be a hashref' unless ref $info eq 'HASH';

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
    }

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

    # Mirror iforest()'s constraint so the one forbidden policy fails at write
    # time; iforest() keeps its own check for hand-edited info.json files.
    croak "info 'missing' may not be 'die' (use nan, zero, or impute)"
        if defined $info->{missing} && $info->{missing} eq 'die';

    return 1;
}

sub write_info {
    my ( $self, %args ) = @_;
    my $info = $args{info} or croak 'write_info requires info => \%info';
    $self->_validate_info($info);

    my $dir = $self->set_dir(%args);
    make_path($dir) unless -d $dir;

    my $path = File::Spec->catfile( $dir, $INFO_FILE );
    open my $fh, '>', $path or croak "cannot write $path: $!";
    print {$fh} $self->{json}->encode($info);
    close $fh;

    return $path;
}

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
control directory C<$basedir/.set_templates/> as C<$template$TEMPLATE_EXT> (i.e.
C<$template.json>). Because a slug/set name may never begin with a dot (see
L</NAME VALIDATION>), this directory can never collide with a real slug, and
C<slugs()> never reports it.

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
if needed. Returns the path written. The body gets the same sanity check as
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
    return File::Spec->catdir( $self->{basedir}, $TEMPLATE_DIR );
}

sub template_path {
    my ( $self, %args ) = @_;
    $self->assert_name( $args{template}, 'template' );
    return File::Spec->catfile( $self->template_dir,
        $args{template} . $TEMPLATE_EXT );
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
    return sort @names;
}

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
    $self->_validate_info($info);

    my $dir = $self->template_dir;
    make_path($dir) unless -d $dir;

    my $path = $self->template_path(%args);
    open my $fh, '>', $path or croak "cannot write $path: $!";
    print {$fh} $self->{json}->encode($info);
    close $fh;

    return $path;
}

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
}

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
    my $dir = $self->hour_dir(%args);
    croak "hour dir does not exist: $dir" unless -d $dir;

    opendir my $dh, $dir or croak "cannot read $dir: $!";
    my @writer_files = sort grep { /\Aw\..+\.csv\z/ } readdir $dh;
    closedir $dh;

    my $out = File::Spec->catfile( $dir, $COMBINED_FILE );
    $self->_rebuild_csv(
        $out,
        $self->tags(%args),
        map { File::Spec->catfile( $dir, $_ ) } @writer_files
    );
    return $out;
}

sub combine_day {
    my ( $self, %args ) = @_;
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
}

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
}

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
        my $daily = File::Spec->catfile(
            $self->date_dir( %args, date => $date ), $DAILY_FILE );

        if ( $whole_day && -f $daily ) {
            push @rows, @{ $self->_read_csv_data($daily) };
        }
        else {
            # Partial day (or no daily.csv yet): read the specific hours. This
            # is exactly what the hourly dir buys us -- topping up part of a day
            # instead of swallowing or dropping a whole daily.csv.
            for my $hour (@hours) {
                push @rows, @{
                    $self->_read_hour_rows( %args, date => $date, hour => $hour )
                };
            }
        }
    }

    return \@rows;
}

# A raw-numeric CSV data line is plain numbers separated by commas: no header,
# no quotes, no spaces, no empty fields. Returns the cleaned line (EOL stripped)
# if it qualifies, else undef -- callers use that to drop bad lines.
sub _numeric_line {
    my ( $self, $line ) = @_;
    return undef unless defined $line;
    $line =~ s/\r?\n\z//;
    return undef if $line eq '';
    for my $field ( split /,/, $line, -1 ) {
        return undef if $field =~ /\s/;                # no spaces/tabs/etc
        return undef unless looks_like_number($field); # numeric (incl nan/inf)
    }
    return $line;
}

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
}

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
        push @rows,
            @{ $self->_read_csv_data( File::Spec->catfile( $dir, $wf ) ) };
    }
    return \@rows;
}

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

# info.json keys forwarded verbatim to Algorithm::Classifier::IsolationForest->new.
our @MODEL_PARAM_KEYS = qw(
    n_trees sample_size max_depth seed mode extension_level
    contamination missing impute_with voting
);

sub model_path {
    my ( $self, %args ) = @_;
    return File::Spec->catfile( $self->set_dir(%args), $MODEL_FILE );
}

sub iforest {
    my ( $self, %args ) = @_;

    my $info = $self->read_info(%args)
        or croak "no $INFO_FILE for set '$args{set}' under slug '$args{slug}'";

    croak "info.json 'missing' may not be 'die' (use nan, zero, or impute)"
        if defined $info->{missing} && $info->{missing} eq 'die';

    my %params;
    for my $key (@MODEL_PARAM_KEYS) {
        $params{$key} = $info->{$key} if exists $info->{$key};
    }

    # the column tags double as the model's per-feature labels.
    $params{feature_names} = $info->{tags} if ref $info->{tags} eq 'ARRAY';

    return Algorithm::Classifier::IsolationForest->new(%params);
}

sub rebuild_model {
    my ( $self, %args ) = @_;

    my $rows = $self->read_back(%args);
    croak "no training data in window for set '$args{set}' under slug '$args{slug}'"
        unless @$rows;

    my $model = $self->iforest(%args);
    $model->fit($rows);
    $model->save( $self->model_path(%args) );    # atomic write

    return $model;
}

sub load_model {
    my ( $self, %args ) = @_;

    my $path = $self->model_path(%args);
    croak "no model at $path" unless -f $path;

    return Algorithm::Classifier::IsolationForest->load($path);
}

=head1 SEE ALSO

L<Algorithm::Classifier::IsolationForest::Zorita::Writer>

=head1 AUTHOR

Zane C. Bowers-Hadley, C<< <vvelox at vvelox.net> >>

=head1 LICENSE AND COPYRIGHT

This software is Copyright (c) 2026 by Zane C. Bowers-Hadley.

This is free software, licensed under:

  The GNU Lesser General Public License, Version 2.1, February 1999

=cut

1;    # End of Algorithm::Classifier::IsolationForest::Zorita
