package Algorithm::Classifier::IsolationForest::Zorita::Cmd::Command::streamd;

use 5.006;
use strict;
use warnings;

use Algorithm::Classifier::IsolationForest::Zorita::Cmd -command;

=head1 NAME

Algorithm::Classifier::IsolationForest::Zorita::Cmd::Command::streamd - C<zorita streamd>: serve an online set's model.

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

=head1 SYNOPSIS

    zorita streamd myapp stream
    zorita streamd --foreground myapp stream
    zorita --basedir /srv/zorita streamd myapp stream --save-interval 60

Runs the online serving daemon
(L<Algorithm::Classifier::IsolationForest::Zorita::Online>) for one B<online>
set: it binds C<stream.sock> in the set dir, resumes the model from
C<latest.json> or creates it from the set's C<info.json>, and learns/scores rows
that arrive over the socket. This is C<iforest streamd> adapted to Zorita -- the
model configuration comes from C<info.json>, not command flags, and the socket,
pid, log, and model saves all live under C<$basedir/online/$slug/$set/>.

The set is always resolved in the online tree regardless of the C<--type> global
option, since a batch set has no model to serve.

=head1 METHODS

These are the L<App::Cmd::Command> hooks; they are not called directly.

=head2 abstract

=head2 usage_desc

=head2 opt_spec

Runtime knobs only (the model comes from C<info.json>): C<--save-interval>,
C<--keep>, C<--foreground>/C<-f>, C<--log>, C<--socket-mode>, C<--threshold>.

=head2 validate_args

Requires exactly two positional arguments: the slug and the set.

=head2 execute

Builds the daemon for the C<< <slug> <set> >> online set and runs it until
SIGTERM/SIGINT.

=cut

sub abstract { 'run the online serving daemon for a set' }

sub usage_desc { '%c streamd %o <slug> <set>' }

sub opt_spec {
	return (
		[ 'save-interval=i', 'seconds between periodic saves (default: 300)', { default => 300 } ],
		[ 'keep=i',          'prune all but the newest N saved models after each save' ],
		[ 'foreground|f',    'do not daemonize; log to stderr unless --log is given' ],
		[ 'log=s',           'log file (default: streamd.log in the set dir)' ],
		[ 'socket-mode=s',   'octal permissions to chmod the socket to (e.g. 0660)' ],
		[ 'threshold=f',     'fixed label cutoff in (0, 1), overriding the learned threshold' ],
	);
} ## end sub opt_spec

sub validate_args {
	my ( $self, $opt, $args ) = @_;
	$self->usage_error('streamd requires exactly <slug> and <set>')
		unless @$args == 2;
}

sub execute {
	my ( $self, $opt, $args ) = @_;
	my ( $slug, $set ) = @$args;

	require Algorithm::Classifier::IsolationForest::Zorita::Online;

	my $daemon = Algorithm::Classifier::IsolationForest::Zorita::Online->new(
		zorita        => $self->app->zorita_for('online'),
		slug          => $slug,
		set           => $set,
		save_interval => $opt->save_interval,
		keep          => $opt->keep,
		foreground    => $opt->foreground,
		log           => $opt->log,
		socket_mode   => $opt->socket_mode,
		threshold     => $opt->threshold,
	);
	$daemon->run;

	return 1;
} ## end sub execute

=head1 SEE ALSO

L<Algorithm::Classifier::IsolationForest::Zorita::Online>,
L<Algorithm::Classifier::IsolationForest::Zorita::Cmd>

=head1 AUTHOR

Zane C. Bowers-Hadley, C<< <vvelox at vvelox.net> >>

=head1 LICENSE AND COPYRIGHT

This software is Copyright (c) 2026 by Zane C. Bowers-Hadley.

This is free software, licensed under:

  The GNU Lesser General Public License, Version 2.1, February 1999

=cut

1;    # End of ...::Zorita::Cmd::Command::streamd
