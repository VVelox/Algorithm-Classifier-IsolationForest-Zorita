package Algorithm::Classifier::IsolationForest::Zorita::Cmd::Command::create_set;

use 5.006;
use strict;
use warnings;

use Algorithm::Classifier::IsolationForest::Zorita::Cmd -command;

=head1 NAME

Algorithm::Classifier::IsolationForest::Zorita::Cmd::Command::create_set - C<zorita create-set>: create a set from a template.

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

=head1 SYNOPSIS

    zorita create-set myapp http-logs http
    zorita --basedir /srv/zorita create-set myapp http-logs http

Creates the set C<< <slug>/<set> >> by copying the named template's JSON (from
C<.set_templates/<template>.json>) into the new set's C<info.json>. It refuses
to clobber a set that already exists, and fails if the template is unknown.

=head1 METHODS

These are the L<App::Cmd::Command> hooks; they are not called directly.

=head2 command_names

Overrides the default (derived from the package name) so the subcommand is
spelled C<create-set> rather than C<create_set>.

=head2 abstract

One-line description shown in C<zorita commands>.

=head2 usage_desc

The usage string shown for C<zorita help create-set>.

=head2 validate_args

Requires exactly three positional arguments: the slug, the set, and the
template.

=head2 execute

Creates the set via
L<Algorithm::Classifier::IsolationForest::Zorita/create_set> and reports the
C<info.json> path written.

=cut

sub command_names { 'create-set' }

sub abstract { 'create a set under a slug from a template' }

sub usage_desc { '%c create-set %o <slug> <set> <template>' }

sub validate_args {
	my ( $self, $opt, $args ) = @_;
	$self->usage_error('create-set requires <slug> <set> <template>')
		unless @$args == 3;
}

sub execute {
	my ( $self, $opt, $args )     = @_;
	my ( $slug, $set, $template ) = @$args;

	my $path = $self->app->zorita->create_set(
		slug     => $slug,
		set      => $set,
		template => $template,
	);

	print "created $slug/$set from template '$template' ($path)\n";
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

1;    # End of ...::Zorita::Cmd::Command::create_set
