package Algorithm::Classifier::IsolationForest::Zorita::Cmd::Command::rebuild;

use 5.006;
use strict;
use warnings;

use Algorithm::Classifier::IsolationForest::Zorita::Cmd -command;

=head1 NAME

Algorithm::Classifier::IsolationForest::Zorita::Cmd::Command::rebuild - C<zorita rebuild>: rebuild one set's model.

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

=head1 SYNOPSIS

    zorita rebuild myapp http-logs
    zorita rebuild --hours 336 myapp http-logs

Rebuilds the C<iforest_model.json> for a single set, reading the training window
back and re-fitting the model. With no C<--hours> the set's C<days_back> (from
its C<info.json>) picks the window.

=head1 METHODS

These are the L<App::Cmd::Command> hooks; they are not called directly.

=head2 abstract

One-line description shown in C<zorita commands>.

=head2 usage_desc

The usage string shown for C<zorita help rebuild>.

=head2 opt_spec

Declares C<--hours>/C<-H>, the optional training-window override in hours.

=head2 validate_args

Requires exactly two positional arguments: the slug and the set.

=head2 execute

Rebuilds the one C<< [type, slug, set] >> target (the type coming from the
C<--type> global option, default C<batch>) via
L<Algorithm::Classifier::IsolationForest::Zorita::Cmd/rebuild_and_report>.

=cut

sub abstract { 'rebuild the model for one set' }

sub usage_desc { '%c rebuild %o <slug> <set>' }

sub opt_spec {
	return ( [ 'hours|H=i', 'training window in hours (default: days_back*24)' ], );
}

sub validate_args {
	my ( $self, $opt, $args ) = @_;
	$self->usage_error('rebuild requires exactly <slug> and <set>')
		unless @$args == 2;
}

sub execute {
	my ( $self, $opt, $args ) = @_;
	my ( $slug, $set ) = @$args;
	my $type = $self->app->current_type;
	$self->app->rebuild_and_report( [ [ $type, $slug, $set ] ], hours => $opt->hours );
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

1;    # End of ...::Zorita::Cmd::Command::rebuild
