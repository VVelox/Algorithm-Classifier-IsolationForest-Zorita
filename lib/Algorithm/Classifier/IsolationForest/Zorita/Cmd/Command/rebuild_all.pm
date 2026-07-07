package Algorithm::Classifier::IsolationForest::Zorita::Cmd::Command::rebuild_all;

use 5.006;
use strict;
use warnings;

use Algorithm::Classifier::IsolationForest::Zorita::Cmd -command;

=head1 NAME

Algorithm::Classifier::IsolationForest::Zorita::Cmd::Command::rebuild_all - C<zorita rebuild-all>: rebuild every model in the tree.

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

=head1 SYNOPSIS

    zorita rebuild-all
    zorita rebuild-all --hours 336
    zorita --basedir /srv/zorita rebuild-all

Rebuilds the model for every set under every slug in the base directory -- the
"rebuild the world" entry point, suitable for a nightly cron. Rebuilds are
independent: a failing set is reported and skipped, and the exit status is
non-zero if any set failed. With no C<--hours> each set uses its own
C<days_back>.

=head1 METHODS

These are the L<App::Cmd::Command> hooks; they are not called directly.

=head2 command_names

Overrides the default (derived from the package name) so the subcommand is
spelled C<rebuild-all> rather than C<rebuild_all>.

=head2 abstract

One-line description shown in C<zorita commands>.

=head2 usage_desc

The usage string shown for C<zorita help rebuild-all>.

=head2 opt_spec

Declares C<--hours>/C<-H>, the optional training-window override in hours.

=head2 validate_args

Rejects any positional arguments -- C<rebuild-all> takes none.

=head2 execute

Walks every slug and every set into a flat list of C<< [slug, set] >> targets
and rebuilds them via
L<Algorithm::Classifier::IsolationForest::Zorita::Cmd/rebuild_and_report>.
Warns (without failing) when the base directory holds no sets at all.

=cut

sub command_names { 'rebuild-all' }

sub abstract { 'rebuild the models for every set under every slug' }

sub usage_desc { '%c rebuild-all %o' }

sub opt_spec {
	return ( [ 'hours|H=i', 'training window in hours (default: days_back*24)' ], );
}

sub validate_args {
	my ( $self, $opt, $args ) = @_;
	$self->usage_error('rebuild-all takes no arguments') if @$args;
}

sub execute {
	my ( $self, $opt, $args ) = @_;
	my $z = $self->app->zorita;

	my @targets;
	for my $slug ( $z->slugs ) {
		push @targets, [ $slug, $_ ] for $z->sets( slug => $slug );
	}
	warn "no sets found under the base directory\n" unless @targets;

	$self->app->rebuild_and_report( \@targets, hours => $opt->hours );
} ## end sub execute

=head1 SEE ALSO

L<Algorithm::Classifier::IsolationForest::Zorita::Cmd>

=head1 AUTHOR

Zane C. Bowers-Hadley, C<< <vvelox at vvelox.net> >>

=head1 LICENSE AND COPYRIGHT

This software is Copyright (c) 2026 by Zane C. Bowers-Hadley.

This is free software, licensed under:

  The GNU Lesser General Public License, Version 2.1, February 1999

=cut

1;    # End of ...::Zorita::Cmd::Command::rebuild_all
