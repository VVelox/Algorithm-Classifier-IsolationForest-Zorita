package Algorithm::Classifier::IsolationForest::Zorita::Cmd::Command::templates;

use 5.006;
use strict;
use warnings;

use Algorithm::Classifier::IsolationForest::Zorita::Cmd -command;

=head1 NAME

Algorithm::Classifier::IsolationForest::Zorita::Cmd::Command::templates - C<zorita templates>: list set templates.

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

=head1 SYNOPSIS

    zorita templates
    zorita --basedir /srv/zorita templates

Prints one template name per line -- every C<$name.json> under the reserved
C<.set_templates> directory -- or nothing when there are no templates. Feed a
name to C<zorita create-set> to stamp out a set from it.

=head1 METHODS

These are the L<App::Cmd::Command> hooks; they are not called directly.

=head2 abstract

One-line description shown in C<zorita commands>.

=head2 usage_desc

The usage string shown for C<zorita help templates>.

=head2 validate_args

Rejects any positional arguments -- C<templates> takes none.

=head2 execute

Prints each template name from
L<Algorithm::Classifier::IsolationForest::Zorita/templates>, one per line.

=cut

sub abstract { 'list the available set templates' }

sub usage_desc { '%c templates %o' }

sub validate_args {
    my ( $self, $opt, $args ) = @_;
    $self->usage_error('templates takes no arguments') if @$args;
}

sub execute {
    my ( $self, $opt, $args ) = @_;
    print "$_\n" for $self->app->zorita->templates;
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

1;    # End of ...::Zorita::Cmd::Command::templates
