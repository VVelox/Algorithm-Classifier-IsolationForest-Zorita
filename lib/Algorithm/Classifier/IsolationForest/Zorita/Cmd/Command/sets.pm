package Algorithm::Classifier::IsolationForest::Zorita::Cmd::Command::sets;

use 5.006;
use strict;
use warnings;

use Algorithm::Classifier::IsolationForest::Zorita::Cmd -command;

=head1 NAME

Algorithm::Classifier::IsolationForest::Zorita::Cmd::Command::sets - C<zorita sets>: list a slug's sets.

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

=head1 SYNOPSIS

    zorita sets myapp
    zorita --basedir /srv/zorita sets myapp

Prints one set per line -- every set directory the given slug has -- or nothing
when the slug has no sets or does not exist.

=head1 METHODS

These are the L<App::Cmd::Command> hooks; they are not called directly.

=head2 abstract

One-line description shown in C<zorita commands>.

=head2 usage_desc

The usage string shown for C<zorita help sets>.

=head2 validate_args

Requires exactly one positional argument, the slug to list. The slug name
itself is validated downstream by
L<Algorithm::Classifier::IsolationForest::Zorita/sets>.

=head2 execute

Prints each set from
L<Algorithm::Classifier::IsolationForest::Zorita/sets>, one per line.

=cut

sub abstract { 'list the sets a slug has' }

sub usage_desc { '%c sets %o <slug>' }

sub validate_args {
    my ( $self, $opt, $args ) = @_;
    $self->usage_error('sets requires exactly one <slug>') unless @$args == 1;
}

sub execute {
    my ( $self, $opt, $args ) = @_;
    print "$_\n" for $self->app->zorita->sets( slug => $args->[0] );
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

1;    # End of ...::Zorita::Cmd::Command::sets
