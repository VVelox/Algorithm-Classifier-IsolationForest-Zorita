package Algorithm::Classifier::IsolationForest::Zorita::Writer;

use 5.006;
use strict;
use warnings;

use Carp         qw(croak);
use Fcntl        qw(:flock);
use Scalar::Util qw(looks_like_number);
use Algorithm::Classifier::IsolationForest::Zorita;
use Algorithm::Classifier::IsolationForest::Zorita::Mungers;

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

A writer owns one C<w.$writer.csv> file and appends to it. It resolves the
current C<$date>/C<$hour> directory (creating it as needed) and caches that
path, only re-resolving it when the hour actually rolls over, then appends a
single CSV row. A long-lived writer therefore rolls onto a new file every hour
without extra bookkeeping, while steady-state writes skip the directory lookup.

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

The set's C<info.json> is read and verified at construction (see
L<Algorithm::Classifier::IsolationForest::Zorita/validate_info>): it must
exist, declare C<tags>, compile its munging plan, and carry model
hyper-parameters that C<< Algorithm::Classifier::IsolationForest->new >> will
accept at rebuild time. A writer aimed at a missing or misconfigured set can
never write successfully, so it croaks here -- at process start, while someone
is looking -- rather than when the first row arrives.

=cut

sub new {
	my ( $class, %args ) = @_;

	my $zorita = $args{zorita}
		|| Algorithm::Classifier::IsolationForest::Zorita->new( basedir => $args{basedir} );

	for my $field (qw(slug set writer)) {
		croak "new() requires '$field'" unless defined $args{$field};
	}

	# validate all three names up front using the shared rule.
	$zorita->assert_name( $args{slug},   'slug' );
	$zorita->assert_name( $args{set},    'set' );
	$zorita->assert_name( $args{writer}, 'writer' );

	# Verify the set at construction rather than first write: a writer aimed
	# at a missing or unusable info.json can never write successfully, and
	# the operator is watching at process start, not hours later when the
	# first row arrives. validate_info covers tags, mungers, and the model
	# hyper-parameters (see Zorita's POD).
	my $info = $zorita->read_info( slug => $args{slug}, set => $args{set} );
	croak "no info.json for set '$args{set}' under slug '$args{slug}'"
		unless $info;
	croak "info.json for set '$args{set}' under slug '$args{slug}' has no 'tags'"
		unless ref $info->{tags} eq 'ARRAY' && @{ $info->{tags} };
	$zorita->validate_info($info);

	my $self = {
		zorita   => $zorita,
		slug     => $args{slug},
		set      => $args{set},
		writer   => $args{writer},
		filename => 'w.' . $args{writer} . '.csv',                                      # built once, never changes
																						# tags and the munging plan are seeded from the info.json just
																						# validated, so the first write pays no extra read.
		tags     => $info->{tags},
		plan     => Algorithm::Classifier::IsolationForest::Zorita::Mungers->compile(
			tags    => $info->{tags},
			mungers => $info->{mungers},
		),
		slot => undef,                                                                  # "$date/$hour" the cached path is valid for
		file => undef,                                                                  # cached full path to the current hour's file
	};

	return bless $self, $class;
} ## end sub new

=head1 METHODS

=head2 tags

Returns the C<tags> arrayref from the set's C<info.json>, cached from the read
done (and validated) at construction.

=cut

sub tags {
	my ($self) = @_;
	$self->{tags} ||= $self->{zorita}->tags(
		slug => $self->{slug},
		set  => $self->{set},
	);
	return $self->{tags};
}

=head2 plan

Returns the compiled munging plan for this set -- the C<tags> and the optional
C<mungers> from C<info.json>, compiled at construction by
L<Algorithm::Classifier::IsolationForest::Zorita::Mungers/compile>. A set with no
C<mungers> yields an all-raw plan, so C<write>/C<write_named> behave exactly as
before. An invalid munger spec croaks in C<new> (see C<compile> for the
coverage rules).

=cut

sub plan {
	my ($self) = @_;
	return $self->{plan} ||= do {
		my $info = $self->{zorita}->read_info(
			slug => $self->{slug},
			set  => $self->{set},
		);
		croak "no info.json for set '$self->{set}' under slug '$self->{slug}'"
			unless $info;
		Algorithm::Classifier::IsolationForest::Zorita::Mungers->compile(
			tags    => $self->tags,
			mungers => $info->{mungers},
		);
	};
} ## end sub plan

=head2 filename

The bare C<w.$writer.csv> filename for this writer.

=head2 path

    my $file = $writer->path( time => $epoch );   # time optional

Full path to the file this writer would append to right now, i.e. inside the
current hour directory. Resolved fresh each call, independent of the cached
path C<write> uses, and does not create anything.

=cut

sub filename {
	my ($self) = @_;
	return $self->{filename};
}

sub path {
	my ( $self, %args ) = @_;
	my $dir = $self->{zorita}->hour_dir(
		slug => $self->{slug},
		set  => $self->{set},
		time => $args{time},
	);
	return $dir . '/' . $self->{filename};
}

# Resolve (and cache) the full path to the file this writer appends to right
# now, creating the hour dir on the first write of each hour. The cache is keyed
# by the "$date/$hour" stamp, so the expensive path build + make_path only runs
# when the hour actually rolls over; every other write is a single string
# compare. The date/hour are computed here and handed to hour_dir so it does not
# recompute the stamps.
sub _current_file {
	my ( $self, $time ) = @_;

	my $zorita = $self->{zorita};
	my $date   = $zorita->datestamp($time);
	my $hour   = $zorita->hourstamp($time);
	my $slot   = "$date/$hour";

	if ( !defined $self->{slot} || $self->{slot} ne $slot ) {
		my $dir = $zorita->hour_dir(
			slug  => $self->{slug},
			set   => $self->{set},
			date  => $date,
			hour  => $hour,
			mkdir => 1,
		);
		$self->{file} = $dir . '/' . $self->{filename};
		$self->{slot} = $slot;
	} ## end if ( !defined $self->{slot} || $self->{slot...})

	return $self->{file};
} ## end sub _current_file

=head2 write

    $writer->write( \@row );

Append one already-ordered positional row. Any scalar mungers the set declares
are applied by position first (via the set's L</plan>); the result must be the
right length and every field clean numeric data (a number, no spaces or quotes)
or C<write> croaks -- this keeps files as raw comma-separated numbers and avoids
any CSV-encoding overhead. A set with B<expanding> (multi-column) mungers cannot
be written positionally, since a shared source has no single position -- use
C<write_named> for those. An exclusive C<flock> keeps concurrent processes
writing the same file row-atomic.

=cut

sub write {
	my ( $self, $row, %args ) = @_;
	croak 'write() requires an arrayref row' unless ref $row eq 'ARRAY';
	return $self->_emit( $self->plan->apply_positional($row), %args );
}

=head2 write_named

    $writer->write_named( { field => value, ... } );

Takes a hashref keyed by field name, applies the set's mungers -- including
multi-column expanders such as a C<datetime> sin/cos pair -- and assembles the
row in C<tags> order for you. Fields with no munger are read straight from the
hash under their tag name; a munger may read a different field via its C<from>.
Croaks if any required source field is missing.

=cut

sub write_named {
	my ( $self, $hash, %args ) = @_;
	croak 'write_named() requires a hashref' unless ref $hash eq 'HASH';
	return $self->_emit( $self->plan->apply_named($hash), %args );
}

=head2 write_rows

    $writer->write_rows( [ \%rec, \%rec, \@row, ... ] );

Append a batch of records in one call: each element is either a hashref (handled
like C<write_named>) or an arrayref (like C<write>). The per-row C<open>/C<flock>
/C<close> is by far the most expensive part of a write, so batching amortizes it
-- one lock and one append for the whole batch.

Every record is munged and validated B<before> anything is written: a bad record
croaks the whole call with nothing appended. The batch is written to the hour
file resolved once at call time (or C<< time => $epoch >>), so a batch never
straddles an hourly rollover. An empty batch is a no-op and returns undef.

=cut

sub write_rows {
	my ( $self, $records, %args ) = @_;
	croak 'write_rows() requires an arrayref of records'
		unless ref $records eq 'ARRAY';
	return undef unless @$records;

	my $plan = $self->plan;
	my @rows = map {
			  ref $_ eq 'HASH'  ? $plan->apply_named($_)
			: ref $_ eq 'ARRAY' ? $plan->apply_positional($_)
			: croak 'write_rows(): each record must be a hashref or an arrayref'
	} @$records;

	return $self->_emit_many( \@rows, %args );
} ## end sub write_rows

# Single-row emit -- the shared tail of write()/write_named().
sub _emit {
	my ( $self, $row, %args ) = @_;
	return $self->_emit_many( [$row], %args );
}

# Validate fully-assembled, tag-ordered numeric rows and append them under one
# exclusive lock. Mungers (if any) have already run, so the numeric check here
# is the post-munge backstop that keeps writer files clean comma-separated
# numbers; it runs over the whole batch before the file is touched, so a bad
# row aborts with nothing written.
sub _emit_many {
	my ( $self, $rows, %args ) = @_;

	my $tags = $self->tags;
	my $many = @$rows > 1;

	for my $r ( 0 .. $#$rows ) {
		my $row = $rows->[$r];
		my $at  = $many ? "row $r: " : '';
		croak $at . 'row has ' . scalar(@$row) . ' fields but info.json declares ' . scalar(@$tags)
			unless @$row == @$tags;
		for my $i ( 0 .. $#$row ) {
			my $v = $row->[$i];
			croak $at . "field $i (" . ( defined $v ? "'$v'" : 'undef' ) . ") is not clean numeric data"
				if !defined $v || $v =~ /\s/ || !looks_like_number($v);
		}
	} ## end for my $r ( 0 .. $#$rows )

	# Resolve this writer's file for the current hour. Cached across writes and
	# only rebuilt (with the hour dir created) when the hour rolls over.
	my $file = $self->_current_file( $args{time} );

	open my $fh, '>>', $file or croak "cannot append to $file: $!";
	flock( $fh, LOCK_EX ) or croak "cannot lock $file: $!";

	# Header goes in ONLY when the file is brand new. Every later append sees a
	# non-empty file and must never re-emit it. The size is checked through the
	# locked filehandle so a concurrent create/append cannot race the decision.
	# The batch goes out as one print so concurrent writers cannot interleave
	# rows inside it even beyond the lock's guarantee.
	my $out = join( '', map { join( ',', @$_ ) . "\n" } @$rows );
	$out = join( ',', @$tags ) . "\n" . $out if !-s $fh;
	print {$fh} $out
		or croak "cannot write to $file: $!";

	flock( $fh, LOCK_UN );
	close $fh or croak "cannot close $file: $!";

	return $file;
} ## end sub _emit_many

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
