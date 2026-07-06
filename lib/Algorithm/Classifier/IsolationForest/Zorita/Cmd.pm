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

=head1 DESCRIPTION

This is a thin L<App::Cmd> subclass. Its only jobs are to declare the one
global option shared by every subcommand -- C<--basedir> -- and to hand each
subcommand a ready-made
L<Algorithm::Classifier::IsolationForest::Zorita> object built from it (see
L</zorita>). All real work lives in the utility class and the individual command
modules.

=head1 GLOBAL OPTIONS

=head2 global_opt_spec

Declares the options accepted before the subcommand name:

=over 4

=item * C<--basedir>, C<-b> - the Zorita base directory. Defaults to whatever
L<Algorithm::Classifier::IsolationForest::Zorita/new> uses (C</var/db/zorita/>)
when omitted.

=back

=cut

sub global_opt_spec {
    return (
        [ 'basedir|b=s', 'zorita base directory (default: /var/db/zorita/)' ],
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

    return $self->{zorita} ||=
        Algorithm::Classifier::IsolationForest::Zorita->new(
        basedir => $self->global_options->basedir,
        );
}

=head2 rebuild_and_report

    $self->app->rebuild_and_report( \@targets, hours => $hours );

The shared engine behind the C<rebuild>, C<rebuild-slug>, and C<rebuild-all>
subcommands. C<@targets> is a list of C<[ $slug, $set ]> pairs. Each is rebuilt
via L<Algorithm::Classifier::IsolationForest::Zorita/rebuild_model>; C<hours>,
when defined, is passed through as the training-window override (otherwise each
set's C<days_back> from its C<info.json> is used).

Rebuilds are independent: a failure (missing C<info.json>, an empty training
window, etc.) is caught, reported to C<STDERR> as C<FAILED ...>, and the run
continues to the next target -- one bad set never aborts a bulk rebuild. Each
success prints C<rebuilt $slug/$set> to C<STDOUT>, and a C<N rebuilt, M failed>
summary is always printed last. If any target failed the process exits C<1>, so
the exit status is scriptable.

=cut

sub rebuild_and_report {
    my ( $self, $targets, %opt ) = @_;

    my $z = $self->zorita;
    my ( $ok, @failed ) = (0);

    for my $target (@$targets) {
        my ( $slug, $set ) = @$target;

        if (
            eval {
                $z->rebuild_model(
                    slug => $slug,
                    set  => $set,
                    ( defined $opt{hours} ? ( hours => $opt{hours} ) : () ),
                );
                1;
            }
            )
        {
            print "rebuilt $slug/$set\n";
            $ok++;
        }
        else {
            ( my $err = $@ ) =~ s/\s+\z//;
            $err =~ s/ at \S+ line \d+\.?\z//;    # drop croak's file/line tail
            warn "FAILED  $slug/$set: $err\n";
            push @failed, "$slug/$set";
        }
    }

    printf "%d rebuilt, %d failed\n", $ok, scalar @failed;
    exit 1 if @failed;
    return;
}

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
