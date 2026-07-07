package Algorithm::Classifier::IsolationForest::Zorita::Cmd::Command::get_set;

use 5.006;
use strict;
use warnings;

use Algorithm::Classifier::IsolationForest::Zorita::Cmd -command;

=head1 NAME

Algorithm::Classifier::IsolationForest::Zorita::Cmd::Command::get_set - C<zorita get-set>: print a set's info.json.

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

=head1 SYNOPSIS

    zorita get-set myapp http-logs
    zorita --basedir /srv/zorita get-set myapp http-logs

Prints the set's C<info.json> (its raw on-disk contents) to C<STDOUT>. Fails if
the set has no C<info.json>.

=head1 METHODS

These are the L<App::Cmd::Command> hooks; they are not called directly.

=head2 command_names

Overrides the default (derived from the package name) so the subcommand is
spelled C<get-set> rather than C<get_set>.

=head2 abstract

One-line description shown in C<zorita commands>.

=head2 usage_desc

The usage string shown for C<zorita help get-set>.

=head2 validate_args

Requires exactly two positional arguments: the slug and the set.

=head2 execute

Prints the set's C<info.json> from
L<Algorithm::Classifier::IsolationForest::Zorita/info_json>.

=cut

sub command_names { 'get-set' }

sub abstract { 'print a set\'s info.json' }

sub usage_desc { '%c get-set %o <slug> <set>' }

sub validate_args {
	my ( $self, $opt, $args ) = @_;
	$self->usage_error('get-set requires exactly <slug> and <set>')
		unless @$args == 2;
}

sub execute {
	my ( $self, $opt, $args ) = @_;
	my ( $slug, $set ) = @$args;
	print $self->app->zorita->info_json( slug => $slug, set => $set );
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

1;    # End of ...::Zorita::Cmd::Command::get_set
