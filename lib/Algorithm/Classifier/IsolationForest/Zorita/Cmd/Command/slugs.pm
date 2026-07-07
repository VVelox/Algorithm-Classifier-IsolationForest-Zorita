package Algorithm::Classifier::IsolationForest::Zorita::Cmd::Command::slugs;

use 5.006;
use strict;
use warnings;

use Algorithm::Classifier::IsolationForest::Zorita::Cmd -command;

=head1 NAME

Algorithm::Classifier::IsolationForest::Zorita::Cmd::Command::slugs - C<zorita slugs>: list slugs.

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

=head1 SYNOPSIS

    zorita slugs
    zorita --basedir /srv/zorita slugs

Prints one slug per line -- every slug directory directly under the base
directory -- or nothing when the base directory is empty or does not exist.

=head1 METHODS

These are the L<App::Cmd::Command> hooks; they are not called directly.

=head2 abstract

One-line description shown in C<zorita commands>.

=head2 usage_desc

The usage string shown for C<zorita help slugs>.

=head2 validate_args

Rejects any positional arguments -- C<slugs> takes none.

=head2 execute

Prints each slug from
L<Algorithm::Classifier::IsolationForest::Zorita/slugs>, one per line.

=cut

sub abstract { 'list the slugs under the base directory' }

sub usage_desc { '%c slugs %o' }

sub validate_args {
	my ( $self, $opt, $args ) = @_;
	$self->usage_error('slugs takes no arguments') if @$args;
}

sub execute {
	my ( $self, $opt, $args ) = @_;
	print "$_\n" for $self->app->zorita->slugs;
}

=head1 SEE ALSO

L<Algorithm::Classifier::IsolationForest::Zorita::Cmd>

=head1 AUTHOR

Zane C. Bowers-Hadley, C<< <vvelox at vvelox.net> >>

=head1 LICENSE AND COPYRIGHT

This software is Copyright (c) 2026 by Zane C. Bowers-Hadley.

This is free software, licensed under:

  The GNU Lesser General Public License, Version 2.1, February 1999

=cut

1;    # End of ...::Zorita::Cmd::Command::slugs
