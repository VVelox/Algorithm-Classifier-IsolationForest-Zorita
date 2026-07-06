package Algorithm::Classifier::IsolationForest::Zorita::Cmd::Command::get_template;

use 5.006;
use strict;
use warnings;

use Algorithm::Classifier::IsolationForest::Zorita::Cmd -command;

=head1 NAME

Algorithm::Classifier::IsolationForest::Zorita::Cmd::Command::get_template - C<zorita get-template>: print a template's JSON.

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

=head1 SYNOPSIS

    zorita get-template http
    zorita --basedir /srv/zorita get-template http

Prints the named template's JSON (the raw C<.set_templates/<template>.json>
contents) to C<STDOUT>. Fails if the template does not exist.

=head1 METHODS

These are the L<App::Cmd::Command> hooks; they are not called directly.

=head2 command_names

Overrides the default (derived from the package name) so the subcommand is
spelled C<get-template> rather than C<get_template>.

=head2 abstract

One-line description shown in C<zorita commands>.

=head2 usage_desc

The usage string shown for C<zorita help get-template>.

=head2 validate_args

Requires exactly one positional argument, the template name.

=head2 execute

Prints the template JSON from
L<Algorithm::Classifier::IsolationForest::Zorita/template_json>.

=cut

sub command_names { 'get-template' }

sub abstract { 'print a set template as JSON' }

sub usage_desc { '%c get-template %o <template>' }

sub validate_args {
    my ( $self, $opt, $args ) = @_;
    $self->usage_error('get-template requires exactly one <template>')
        unless @$args == 1;
}

sub execute {
    my ( $self, $opt, $args ) = @_;
    print $self->app->zorita->template_json( template => $args->[0] );
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

1;    # End of ...::Zorita::Cmd::Command::get_template
