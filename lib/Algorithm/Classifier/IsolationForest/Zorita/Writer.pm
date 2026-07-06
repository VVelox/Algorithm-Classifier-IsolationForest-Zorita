package Algorithm::Classifier::IsolationForest::Zorita::Writer;

use 5.006;
use strict;
use warnings;

use Carp qw(croak);
use Fcntl qw(:flock);
use File::Spec;
use Scalar::Util qw(looks_like_number);
use Algorithm::Classifier::IsolationForest::Zorita;

=head1 NAME

Algorithm::Classifier::IsolationForest::Zorita::Writer - Append rows to a Zorita data set.

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

=head1 SYNOPSIS

    use Algorithm::Classifier::IsolationForest::Zorita::Writer;

    my $writer = Algorithm::Classifier::IsolationForest::Zorita::Writer->new(
        basedir => '/var/db/zorita/',   # or pass an existing zorita => $z
        slug    => 'myapp',
        set     => 'http-logs',
        writer  => 'web01',
    );

    # ordered to match info.json 'tags'
    $writer->write( [ 1234, 0.08, 200 ] );

    # or by name; reordered to the tag order for you
    $writer->write_named( { bytes => 1234, duration => 0.08, status => 200 } );

=head1 DESCRIPTION

A writer owns one C<w.$writer.csv> file and appends to it. On each write it
resolves the current C<$date>/C<$hour> directory (creating it as needed) and
appends a single CSV row, so a long-lived writer naturally rolls onto a new
file every hour without extra bookkeeping.

Per the README, before writing a writer must honor the column order declared in
the set's C<info.json>. This class enforces that: rows are emitted in C<tags>
order, and C<write()> validates arity while C<write_named()> does the reorder.

The very first row written to a fresh C<w.$writer.csv> is a header of the tag
names. Subsequent appends B<never> re-add the header, so a writer file always
has exactly one header line even across process restarts and hourly rollover.

The heavier roll-up steps (C<combined.csv>, C<daily.csv>) are B<not> the
writer's job; they live in the utility class
L<Algorithm::Classifier::IsolationForest::Zorita> and run after the hour/day
has passed.

=head1 CONSTRUCTOR

=head2 new

    my $writer = ...->new(
        slug   => 'myapp',
        set    => 'http-logs',
        writer => 'web01',
        # one of:
        zorita  => $zorita_object,   # reuse an existing utility instance
        basedir => '/var/db/zorita/',# or let the writer build one
    );

The writer name must also match the standard name regexp.

=cut

sub new {
    my ( $class, %args ) = @_;

    my $zorita = $args{zorita}
        || Algorithm::Classifier::IsolationForest::Zorita->new(
        basedir => $args{basedir} );

    for my $field (qw(slug set writer)) {
        croak "new() requires '$field'" unless defined $args{$field};
    }

    # validate all three names up front using the shared rule.
    $zorita->assert_name( $args{slug},   'slug' );
    $zorita->assert_name( $args{set},    'set' );
    $zorita->assert_name( $args{writer}, 'writer' );

    my $self = {
        zorita => $zorita,
        slug   => $args{slug},
        set    => $args{set},
        writer => $args{writer},
        tags   => undef,    # lazily loaded from info.json on first write
    };

    return bless $self, $class;
}

=head1 METHODS

=head2 tags

Returns (and caches) the C<tags> arrayref from the set's C<info.json>. Croaks
if info.json is missing, since we cannot know the column order without it.

=cut

sub tags {
    my ($self) = @_;
    $self->{tags} ||= $self->{zorita}->tags(
        slug => $self->{slug},
        set  => $self->{set},
    );
    return $self->{tags};
}

=head2 filename

The bare C<w.$writer.csv> filename for this writer.

=head2 path

    my $file = $writer->path( time => $epoch );   # time optional

Full path to the file this writer would append to right now, i.e. inside the
current hour directory. Does not create anything.

=cut

sub filename {
    my ($self) = @_;
    return 'w.' . $self->{writer} . '.csv';
}

sub path {
    my ( $self, %args ) = @_;
    my $dir = $self->{zorita}->hour_dir(
        slug => $self->{slug},
        set  => $self->{set},
        time => $args{time},
    );
    return File::Spec->catfile( $dir, $self->filename );
}

=head2 write

    $writer->write( \@row );

Append one already-ordered row. The row length must equal the number of tags,
and every field must be clean numeric data (a number, no spaces or quotes) or
C<write> croaks -- this keeps files as raw comma-separated numbers and avoids
any CSV-encoding overhead. An exclusive C<flock> keeps concurrent processes
writing the same file row-atomic.

=cut

sub write {
    my ( $self, $row, %args ) = @_;
    croak 'write() requires an arrayref row' unless ref $row eq 'ARRAY';

    my $tags = $self->tags;
    croak 'row has ' . scalar(@$row) . ' fields but info.json declares '
        . scalar(@$tags)
        unless @$row == @$tags;

    # Rows are raw numeric CSV: plain numbers, comma separated, no quoting or
    # spaces. Enforce that at the source so writer files stay clean and never
    # need a heavyweight CSV encoder.
    for my $i ( 0 .. $#$row ) {
        my $v = $row->[$i];
        croak "field $i (" . ( defined $v ? "'$v'" : 'undef' )
            . ") is not clean numeric data"
            if !defined $v || $v =~ /\s/ || !looks_like_number($v);
    }

    my $zorita = $self->{zorita};

    # ensure the hour dir exists, then target this writer's file.
    my $dir = $zorita->hour_dir(
        slug  => $self->{slug},
        set   => $self->{set},
        time  => $args{time},
        mkdir => 1,
    );
    my $file = File::Spec->catfile( $dir, $self->filename );

    open my $fh, '>>', $file or croak "cannot append to $file: $!";
    flock( $fh, LOCK_EX ) or croak "cannot lock $file: $!";

    # Header goes in ONLY when the file is brand new. Every later append sees a
    # non-empty file and must never re-emit it. The size is checked through the
    # locked filehandle so a concurrent create/append cannot race the decision.
    print {$fh} join( ',', @$tags ), "\n" if !-s $fh;
    print {$fh} join( ',', @$row ), "\n"
        or croak "cannot write row to $file: $!";

    flock( $fh, LOCK_UN );
    close $fh or croak "cannot close $file: $!";

    return $file;
}

=head2 write_named

    $writer->write_named( { tag => value, ... } );

Same as C<write>, but takes a hashref keyed by tag name and reorders the values
into C<tags> order for you. Croaks on any tag missing from the hash.

=cut

sub write_named {
    my ( $self, $hash, %args ) = @_;
    croak 'write_named() requires a hashref' unless ref $hash eq 'HASH';

    my $tags = $self->tags;
    my @row;
    for my $tag (@$tags) {
        croak "missing value for tag '$tag'" unless exists $hash->{$tag};
        push @row, $hash->{$tag};
    }

    return $self->write( \@row, %args );
}

=head1 SEE ALSO

L<Algorithm::Classifier::IsolationForest::Zorita>

=head1 AUTHOR

Zane C. Bowers-Hadley, C<< <vvelox at vvelox.net> >>

=head1 LICENSE AND COPYRIGHT

This software is Copyright (c) 2026 by Zane C. Bowers-Hadley.

This is free software, licensed under:

  The GNU Lesser General Public License, Version 2.1, February 1999

=cut

1;    # End of Algorithm::Classifier::IsolationForest::Zorita::Writer
