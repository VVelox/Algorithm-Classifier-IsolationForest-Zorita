package Algorithm::Classifier::IsolationForest::Zorita::Cmd::Command::rebuild_slug;

use 5.006;
use strict;
use warnings;

use Algorithm::Classifier::IsolationForest::Zorita::Cmd -command;

=head1 NAME

Algorithm::Classifier::IsolationForest::Zorita::Cmd::Command::rebuild_slug - C<zorita rebuild-slug>: rebuild every set under one slug.

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

=head1 SYNOPSIS

    zorita rebuild-slug myapp
    zorita rebuild-slug --hours 336 myapp

Rebuilds the model for B<every> set the given slug has (see C<zorita sets>).
Rebuilds are independent: one failing set is reported and skipped, the rest
still run. With no C<--hours> each set uses its own C<days_back>.

=head1 METHODS

These are the L<App::Cmd::Command> hooks; they are not called directly.

=head2 command_names

Overrides the default (derived from the package name) so the subcommand is
spelled C<rebuild-slug> rather than C<rebuild_slug>.

=head2 abstract

One-line description shown in C<zorita commands>.

=head2 usage_desc

The usage string shown for C<zorita help rebuild-slug>.

=head2 opt_spec

Declares C<--hours>/C<-H>, the optional training-window override in hours.

=head2 validate_args

Requires exactly one positional argument, the slug.

=head2 execute

Expands the slug into one C<< [slug, set] >> target per set and rebuilds them
via L<Algorithm::Classifier::IsolationForest::Zorita::Cmd/rebuild_and_report>.
Warns (without failing) when the slug has no sets.

=cut

sub command_names { 'rebuild-slug' }

sub abstract { 'rebuild the models for every set under a slug' }

sub usage_desc { '%c rebuild-slug %o <slug>' }

sub opt_spec {
	return ( [ 'hours|H=i', 'training window in hours (default: days_back*24)' ], );
}

sub validate_args {
	my ( $self, $opt, $args ) = @_;
	$self->usage_error('rebuild-slug requires exactly one <slug>')
		unless @$args == 1;
}

sub execute {
	my ( $self, $opt, $args ) = @_;
	my $slug = $args->[0];
	my $type = $self->app->current_type;

	my @targets = map { [ $type, $slug, $_ ] } $self->app->zorita->sets( slug => $slug );
	warn "slug '$slug' has no sets\n" unless @targets;

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

1;    # End of ...::Zorita::Cmd::Command::rebuild_slug
