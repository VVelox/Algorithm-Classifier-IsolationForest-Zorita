package Algorithm::Classifier::IsolationForest::Zorita::Online::Client;

use 5.006;
use strict;
use warnings;

use Carp                                           qw(croak);
use Scalar::Util                                   qw(looks_like_number);
use IO::Socket::UNIX                               ();
use IO::Select                                     ();
use JSON::PP                                       ();
use Algorithm::Classifier::IsolationForest::Zorita ();

=head1 NAME

Algorithm::Classifier::IsolationForest::Zorita::Online::Client - Client for a Zorita online serving daemon.

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

=head1 SYNOPSIS

    use Algorithm::Classifier::IsolationForest::Zorita;
    use Algorithm::Classifier::IsolationForest::Zorita::Online::Client;

    my $z = Algorithm::Classifier::IsolationForest::Zorita->new(
        basedir => '/var/db/zorita/', type => 'online' );

    my $c = Algorithm::Classifier::IsolationForest::Zorita::Online::Client->new(
        zorita => $z, slug => 'myapp', set => 'stream' );   # or socket => '/path/stream.sock'

    my $r = $c->row( [ 0.1, 0.7 ] );          # { score => 0.41, label => 0 }
    my $r = $c->row( { cpu => 0.1, mem => 0.7 }, tag => 'r1' );
    $c->rows( [ [ ... ], { ... } ], mode => 'learn' );
    print $c->ping, "\n";                     # pong
    my $stats = $c->stats;                    # { seen => ..., ... }

=head1 DESCRIPTION

A thin, blocking client for
L<Algorithm::Classifier::IsolationForest::Zorita::Online> -- the producer/
consumer-side counterpart of the daemon, hiding the C<IO::Socket::UNIX> +
JSON-lines boilerplate behind ordinary method calls. Each call is one
request/reply round trip over the set's C<stream.sock>. This is what
C<zorita streamc> is built on; a program that just wants to push rows can use it
directly instead of shelling out.

The socket is resolved either from a C<zorita> object plus C<slug>/C<set> (via
C<socket_path>, which requires an online-type object) or given outright as
C<socket>. The connection is opened lazily on the first request and reused.

=head1 CONSTRUCTOR

=head2 new

    my $c = ...->new( zorita => $z, slug => ..., set => ..., %opts );
    my $c = ...->new( socket => '/var/db/zorita/online/app/s/stream.sock' );

Options:

=over 4

=item * C<socket> - the daemon's socket path, taken directly. When given,
C<zorita>/C<slug>/C<set> are not needed.

=item * C<zorita> / C<basedir>, C<slug>, C<set> - resolve the socket via
L<Algorithm::Classifier::IsolationForest::Zorita/socket_path>. The Zorita object
(or one built from C<basedir>) must be of type C<online>.

=item * C<timeout> - seconds to wait for each reply (default 30, min 1).

=back

=cut

sub new {
	my ( $class, %args ) = @_;

	my $socket = $args{socket};
	if ( !defined $socket ) {
		my $zorita = $args{zorita}
			|| Algorithm::Classifier::IsolationForest::Zorita->new(
				basedir => $args{basedir},
				type    => 'online',
			);
		croak "online client requires a zorita of type 'online', not '$zorita->{type}'"
			unless $zorita->{type} eq 'online';
		for my $field (qw(slug set)) {
			croak "new() requires 'socket', or 'slug' and 'set' to resolve one"
				unless defined $args{$field};
		}
		$socket = $zorita->socket_path( slug => $args{slug}, set => $args{set} );
	} ## end if ( !defined $socket )

	my $timeout = defined $args{timeout} ? $args{timeout} : 30;
	croak "timeout ('$timeout') must be >= 1 second"
		unless looks_like_number($timeout) && $timeout >= 1;

	my $self = {
		socket   => $socket,
		timeout  => $timeout,
		json     => JSON::PP->new->utf8->canonical,
		sock     => undef,
		buf      => '',
		last_raw => undef,
	};

	return bless $self, $class;
} ## end sub new

=head1 METHODS

=head2 socket_path

The daemon socket path this client talks to.

=head2 request

    my $reply = $c->request( { cmd => 'ping' } );

The low-level primitive: send one request hashref, return the decoded reply
hashref -- B<including> an C<{ error =E<gt> ... }> reply, which is handed back as
data rather than thrown (the typed helpers below croak on it instead). Croaks
only on a transport failure: connect error, write error, timeout/closed
connection with no reply, or an unparseable reply. The raw reply line is kept
for L</last_raw>.

=head2 last_raw

The raw JSON text of the most recent reply line, as the daemon sent it (before
decoding). Useful for passing a reply through verbatim.

=head2 disconnect

Close the underlying socket. A later request reconnects.

=cut

sub socket_path { return $_[0]->{socket} }
sub last_raw    { return $_[0]->{last_raw} }

sub _connect {
	my ($self) = @_;
	return $self->{sock} if $self->{sock};

	croak 'socket path "'
		. $self->{socket} . '" is '
		. length( $self->{socket} )
		. ' bytes; Unix socket paths are limited to ~104 bytes'
		if length( $self->{socket} ) > 100;

	$self->{sock} = IO::Socket::UNIX->new( Peer => $self->{socket} )
		or croak 'failed to connect to "' . $self->{socket} . '": ' . $! . ' -- is the daemon running?';
	$self->{sock}->autoflush(1);
	$self->{buf} = '';
	return $self->{sock};
} ## end sub _connect

sub disconnect {
	my ($self) = @_;
	close $self->{sock} if $self->{sock};
	$self->{sock} = undef;
	$self->{buf}  = '';
	return 1;
}

sub request {
	my ( $self, $msg ) = @_;
	croak 'request() needs a hashref' unless ref $msg eq 'HASH';

	my $sock = $self->_connect;

	# A daemon that drops us mid-write should surface as the read-side "no
	# reply" error, not a silent SIGPIPE death.
	local $SIG{PIPE} = 'IGNORE';
	print {$sock} $self->{json}->encode($msg) . "\n"
		or croak 'failed writing to the daemon: ' . $!;

	my $line = $self->_read_line;
	croak 'no reply from the daemon within ' . $self->{timeout} . 's (or it closed the connection)'
		unless defined $line;
	$self->{last_raw} = $line;

	my $reply = eval { $self->{json}->decode($line) };
	croak 'daemon sent an unparseable reply: ' . $@ if $@;
	return $reply;
} ## end sub request

# One reply line, honouring the timeout. Returns the line (newline stripped) or
# undef if the deadline passes or the daemon closes before a full line arrives.
sub _read_line {
	my ($self)   = @_;
	my $deadline = time + $self->{timeout};
	my $sel      = IO::Select->new( $self->{sock} );
	while ( $self->{buf} !~ /\n/ ) {
		my $left = $deadline - time;
		return undef if $left <= 0 || !$sel->can_read($left);
		my $got = sysread( $self->{sock}, my $chunk, 65536 );
		return undef unless $got;
		$self->{buf} .= $chunk;
	}
	$self->{buf} =~ s/\A([^\n]*)\n//;
	return $1;
} ## end sub _read_line

=head2 row

    my $r = $c->row( \@row_or_\%tagged, mode => ..., tag => ... );

Send one row (a positional arrayref or a tagged hashref). Returns the reply
payload: C<{ score =E<gt> ..., label =E<gt> ... }> in a scoring mode, or
C<{ learned =E<gt> 1 }> under C<mode =E<gt> 'learn'>. Croaks on a daemon error.

=head2 rows

    my $r = $c->rows( \@rows, mode => ..., tag => ... );

Like L</row> for a batch. Returns C<{ scores =E<gt> [ [score,label], ... ] }> or
C<{ learned =E<gt> N }>.

=head2 ping

Returns the daemon's C<pong>.

=head2 set_mode

    $c->set_mode('learn');

Sets the connection's default mode; returns the new mode.

=head2 stats

Returns the daemon stats hashref (C<seen>, C<window>, C<threshold>, ...).

=head2 save

Asks the daemon to save now; returns the saved file name.

=head2 relearn_threshold

Asks the daemon to relearn the contamination decision threshold; returns it.

=cut

# Unwrap an {ok=>...} reply or croak on {error=>...}; a transport failure
# already threw inside request().
sub _ok {
	my ( $self, $reply ) = @_;
	croak 'daemon error: ' . $reply->{error} if defined $reply->{error};
	return $reply->{ok};
}

sub _row_msg {
	my ( $self, $kind, $payload, %opt ) = @_;
	my %msg = ( $kind => $payload );
	$msg{mode} = $opt{mode} if defined $opt{mode};
	$msg{tag}  = $opt{tag}  if exists $opt{tag};
	return \%msg;
}

sub row {
	my ( $self, $row, %opt ) = @_;
	my $reply = $self->request( $self->_row_msg( 'row', $row, %opt ) );
	croak 'daemon error: ' . $reply->{error} if defined $reply->{error};
	return $reply;    # {score,label,tag?} or {ok=>{learned=>1},tag?}
}

sub rows {
	my ( $self, $rows, %opt ) = @_;
	my $reply = $self->request( $self->_row_msg( 'rows', $rows, %opt ) );
	croak 'daemon error: ' . $reply->{error} if defined $reply->{error};
	return $reply;    # {scores=>[...]} or {ok=>{learned=>N}}
}

sub ping {
	my ($self) = @_;
	return $self->_ok( $self->request( { cmd => 'ping' } ) );
}

sub set_mode {
	my ( $self, $mode ) = @_;
	my $ok = $self->_ok( $self->request( { cmd => 'mode', mode => $mode } ) );
	return ref $ok eq 'HASH' ? $ok->{mode} : $ok;
}

sub stats {
	my ($self) = @_;
	return $self->_ok( $self->request( { cmd => 'stats' } ) );
}

sub save {
	my ($self) = @_;
	my $ok = $self->_ok( $self->request( { cmd => 'save' } ) );
	return ref $ok eq 'HASH' ? $ok->{saved} : $ok;
}

sub relearn_threshold {
	my ($self) = @_;
	my $ok = $self->_ok( $self->request( { cmd => 'relearn-threshold' } ) );
	return ref $ok eq 'HASH' ? $ok->{threshold} : $ok;
}

=head1 SEE ALSO

L<Algorithm::Classifier::IsolationForest::Zorita::Online> (the daemon this talks
to), L<Algorithm::Classifier::IsolationForest::Zorita>.

=head1 AUTHOR

Zane C. Bowers-Hadley, C<< <vvelox at vvelox.net> >>

=head1 LICENSE AND COPYRIGHT

This software is Copyright (c) 2026 by Zane C. Bowers-Hadley.

This is free software, licensed under:

  The GNU Lesser General Public License, Version 2.1, February 1999

=cut

1;    # End of Algorithm::Classifier::IsolationForest::Zorita::Online::Client
