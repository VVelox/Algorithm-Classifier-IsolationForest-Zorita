package Algorithm::Classifier::IsolationForest::Zorita::Cmd;

use 5.006;
use strict;
use warnings;

use App::Cmd::Setup -app;
use Algorithm::Classifier::IsolationForest::Zorita ();

=head1 NAME

Algorithm::Classifier::IsolationForest::Zorita::Cmd - L<App::Cmd> application backing the C<zorita> command.

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

=head1 SYNOPSIS

    use Algorithm::Classifier::IsolationForest::Zorita::Cmd;
    Algorithm::Classifier::IsolationForest::Zorita::Cmd->run;

That two-liner is the whole of the installed C<zorita> executable (see
F<src_bin/zorita>). The subcommands live under the C<::Command::> namespace and
are dispatched by L<App::Cmd>:

    zorita commands            # list available subcommands
    zorita slugs               # list slugs under the base directory
    zorita sets myapp          # list the sets a slug has

    zorita rebuild myapp http-logs   # rebuild one set's model
    zorita rebuild-slug myapp        # rebuild every set under a slug
    zorita rebuild-all               # rebuild every set under every slug

    zorita templates                 # list the available set templates
    zorita get-template http         # print a template's JSON
    zorita create-set myapp http-logs http   # create a set from a template
    zorita get-set myapp http-logs   # print a set's info.json

    zorita streamd myapp stream      # serve an online set's model (daemon)
    zorita streamc myapp stream --ping       # talk to a serving daemon

=head1 DESCRIPTION

This is a thin L<App::Cmd> subclass. Its only jobs are to declare the global
options shared by every subcommand -- C<--basedir> and C<--type> -- and to hand
each subcommand a ready-made
L<Algorithm::Classifier::IsolationForest::Zorita> object built from them (see
L</zorita>). All real work lives in the utility class and the individual command
modules.

=head1 GLOBAL OPTIONS

=head2 global_opt_spec

Declares the options accepted before the subcommand name:

=over 4

=item * C<--basedir>, C<-b> - the Zorita base directory. Defaults to whatever
L<Algorithm::Classifier::IsolationForest::Zorita/new> uses (C</var/db/zorita/>)
when omitted.

=item * C<--type>, C<-t> - the model backend to operate on: C<batch> (the
default) or C<online>. Selects the C<$basedir/$type/...> tree every subcommand
works under. C<rebuild-all> is the one exception: with no C<--type> it rebuilds
B<both> trees, and C<--type> narrows it to one.

=back

=cut

sub global_opt_spec {
	return (
		[ 'basedir|b=s', 'zorita base directory (default: /var/db/zorita/)' ],
		[ 'type|t=s',    'backend type: batch or online (default: batch)' ],
	);
}

=head1 METHODS

=head2 zorita

    my $z = $self->app->zorita;

Returns a lazily-built, memoized
L<Algorithm::Classifier::IsolationForest::Zorita> configured from the
C<--basedir> global option. Subcommands call this rather than constructing their
own, so the base directory is resolved in exactly one place.

=cut

sub zorita {
	my ($self) = @_;
	return $self->zorita_for( $self->current_type );
}

=head2 current_type

    my $type = $self->app->current_type;

The backend type selected by the C<--type> global option, or C<batch> when it
was omitted. This is the type L</zorita> (and therefore every subcommand that
does not name a type explicitly) operates under.

=head2 zorita_for

    my $z = $self->app->zorita_for('online');

Like L</zorita> but for an explicitly named type, memoized per type. Subcommands
that must reach across types -- C<rebuild-all> walking both trees -- use this;
everything else just calls L</zorita>. The C<--basedir> resolution is shared, so
the only difference between the returned objects is their C<$type> root.

=cut

sub current_type {
	my ($self) = @_;
	return defined $self->global_options->type ? $self->global_options->type : 'batch';
}

sub zorita_for {
	my ( $self, $type ) = @_;

	return $self->{zorita_for}{$type} ||= Algorithm::Classifier::IsolationForest::Zorita->new(
		basedir => $self->global_options->basedir,
		type    => $type,
	);
}

=head2 rebuild_and_report

    $self->app->rebuild_and_report( \@targets, hours => $hours );

The shared engine behind the C<rebuild>, C<rebuild-slug>, and C<rebuild-all>
subcommands. C<@targets> is a list of C<[ $type, $slug, $set ]> triples; each is
rebuilt through the utility instance for its C<$type> (via L</zorita_for>), so a
single call can span both backends -- which is what lets C<rebuild-all> walk the
batch and online trees in one run. C<hours>, when defined, is passed through as
the training-window override (otherwise each set's C<days_back> from its
C<info.json> is used). C<from_csv>, when defined, is passed through to select the
low-memory streaming rebuild (see L<Algorithm::Classifier::IsolationForest::Zorita/rebuild_model>).

Rebuilds are independent: a failure (missing C<info.json>, an empty training
window, etc.) is caught, reported to C<STDERR> as C<FAILED ...>, and the run
continues to the next target -- one bad set never aborts a bulk rebuild. Each
success prints C<rebuilt $slug/$set> to C<STDOUT>, and a C<N rebuilt, M failed>
summary is always printed last. If any target failed the process exits C<1>, so
the exit status is scriptable.

=cut

sub rebuild_and_report {
	my ( $self, $targets, %opt ) = @_;

	my ( $ok, @failed ) = (0);

	for my $target (@$targets) {
		my ( $type, $slug, $set ) = @$target;
		my $z = $self->zorita_for($type);

		if (
			eval {
				$z->rebuild_model(
					slug => $slug,
					set  => $set,
					( defined $opt{hours}    ? ( hours    => $opt{hours} )    : () ),
					( defined $opt{from_csv} ? ( from_csv => $opt{from_csv} ) : () ),
				);
				1;
			}
			)
		{
			print "rebuilt $type/$slug/$set\n";
			$ok++;
		} else {
			( my $err = $@ ) =~ s/\s+\z//;
			$err =~ s/ at \S+ line \d+\.?\z//;                # drop croak's file/line tail
			warn "FAILED  $type/$slug/$set: $err\n";
			push @failed, "$type/$slug/$set";
		}
	} ## end for my $target (@$targets)

	printf "%d rebuilt, %d failed\n", $ok, scalar @failed;
	exit 1 if @failed;
	return;
} ## end sub rebuild_and_report

=head1 SEE ALSO

L<App::Cmd>, L<Algorithm::Classifier::IsolationForest::Zorita>

=head1 AUTHOR

Zane C. Bowers-Hadley, C<< <vvelox at vvelox.net> >>

=head1 LICENSE AND COPYRIGHT

This software is Copyright (c) 2026 by Zane C. Bowers-Hadley.

This is free software, licensed under:

  The GNU Lesser General Public License, Version 2.1, February 1999

=cut

1;    # End of Algorithm::Classifier::IsolationForest::Zorita::Cmd
