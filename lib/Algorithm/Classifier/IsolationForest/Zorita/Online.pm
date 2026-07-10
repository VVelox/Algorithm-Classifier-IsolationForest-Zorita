package Algorithm::Classifier::IsolationForest::Zorita::Online;

use 5.006;
use strict;
use warnings;

use Carp                                           qw(croak);
use File::Path                                     qw(make_path);
use File::Spec                                     ();
use Scalar::Util                                   qw(looks_like_number);
use IO::Socket::UNIX                               ();
use IO::Select                                     ();
use POSIX                                          qw(setsid strftime);
use JSON::PP                                       ();
use Algorithm::Classifier::IsolationForest         ();
use Algorithm::Classifier::IsolationForest::Zorita ();

=head1 NAME

Algorithm::Classifier::IsolationForest::Zorita::Online - Serve an online Isolation Forest set over a Unix socket.

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

=head1 SYNOPSIS

    use Algorithm::Classifier::IsolationForest::Zorita;
    use Algorithm::Classifier::IsolationForest::Zorita::Online;

    my $z = Algorithm::Classifier::IsolationForest::Zorita->new(
        basedir => '/var/db/zorita/', type => 'online' );

    my $daemon = Algorithm::Classifier::IsolationForest::Zorita::Online->new(
        zorita        => $z,          # or basedir => ...
        slug          => 'myapp',
        set           => 'stream',
        save_interval => 300,         # optional
        foreground    => 1,           # optional; default daemonizes
    );
    $daemon->run;

=head1 DESCRIPTION

This is the online-backend counterpart of
L<Algorithm::Classifier::IsolationForest::Zorita::Writer>. Where a batch set
stores rows on disk to be rolled up and rebuilt, an B<online> set stores no rows
at all: it is a live L<Algorithm::Classifier::IsolationForest::Online> model
served over a Unix domain socket, learning each row as it arrives and dropping
it. There is nothing to roll up and nothing to rebuild.

The daemon owns everything under the set directory
(C<$basedir/online/$slug/$set/>): it listens on C<stream.sock>, writes
C<stream.pid>, logs to C<streamd.log>, and persists the model streamd-style as
timestamped C<oiforest-*.json> saves under a C<latest.json> symlink flipped
atomically at every save. At startup it resumes from C<latest.json> when it
exists, otherwise it creates a fresh model from the set's C<info.json>
(hyper-parameters, C<tags> as feature names, and any C<mungers>) via
L<Algorithm::Classifier::IsolationForest::Zorita/iforest> -- the same validated
body every other part of Zorita reads. The model is saved every
C<save_interval> seconds (only when something was learned), on the C<save>
command, on SIGUSR1, and at shutdown.

=head2 WIRE PROTOCOL

One JSON document per line in, one per line out. A request carries exactly one
of C<row>, C<rows>, or C<cmd>, an optional C<mode>, and an optional C<tag> (any
JSON value, echoed back verbatim as a correlation marker):

    {"row": [0.1, 0.7]}                    -> {"score": 0.41, "label": 0}
    {"row": {"cpu": 0.1, "mem": 0.7}}      -> {"score": 0.41, "label": 0}
    {"rows": [[...], {...}], "tag": "b7"}  -> {"scores": [[0.41,0], ...], "tag": "b7"}
    {"rows": [[...]], "mode": "learn"}     -> {"ok": {"learned": 1}}
    {"cmd": "mode", "mode": "score"}       -> {"ok": {"mode": "score"}}
    {"cmd": "ping"}                        -> {"ok": "pong"}
    {"cmd": "stats"}                       -> {"ok": {"seen": ..., ...}}
    {"cmd": "save"}                        -> {"ok": {"saved": "oiforest-....json"}}
    {"cmd": "relearn-threshold"}           -> {"ok": {"threshold": 0.61}}
    anything invalid                       -> {"error": "...", "tag": ...}

An array row is positional (scalar mungers applied); a JSON object is a tagged
row and runs the full munger plan from C<info.json>. Modes are C<prequential>
(score against the model as it stands, then learn -- the default), C<learn>
(learn only), and C<score> (score only); a C<mode> on a row/rows message
overrides the connection default set by the C<mode> command for that message.
This is the same protocol the upstream C<iforest streamd> speaks, so
C<iforest streamc> can drive the socket directly.

=head1 CONSTRUCTOR

=head2 new

    my $daemon = ...->new( zorita => $z, slug => ..., set => ..., %opts );

Requires C<slug>, C<set>, and either a ready online C<zorita> object or a
C<basedir> to build one from. The Zorita object must be of type C<online>; a
batch object croaks. Optional runtime knobs (none affect the model, which comes
from C<info.json>):

=over 4

=item * C<save_interval> - seconds between periodic saves (default 300, min 1).

=item * C<keep> - prune all but the newest N timestamped saves after each save.

=item * C<foreground> - do not daemonize; log to STDERR unless C<log> is given.

=item * C<log> - log file path (default C<streamd.log> in the set dir).

=item * C<socket_mode> - octal permissions to chmod the socket to (e.g. C<0660>).

=item * C<threshold> - fixed label cutoff in C<(0, 1)> overriding the model's
learned decision threshold.

=back

=cut

sub new {
	my ( $class, %args ) = @_;

	for my $field (qw(slug set)) {
		croak "new() requires '$field'" unless defined $args{$field};
	}

	my $zorita = $args{zorita}
		|| Algorithm::Classifier::IsolationForest::Zorita->new(
			basedir => $args{basedir},
			type    => 'online',
		);
	croak "Zorita::Online requires a zorita of type 'online', not '$zorita->{type}'"
		unless $zorita->{type} eq 'online';

	$zorita->assert_name( $args{slug}, 'slug' );
	$zorita->assert_name( $args{set},  'set' );

	my $save_interval = defined $args{save_interval} ? $args{save_interval} : 300;
	croak "save_interval ('$save_interval') must be >= 1 second"
		unless looks_like_number($save_interval) && $save_interval >= 1;

	croak "keep ('$args{keep}') must be >= 1"
		if defined $args{keep} && !( looks_like_number( $args{keep} ) && $args{keep} >= 1 );

	croak "threshold ('$args{threshold}') must be > 0 and < 1"
		if defined $args{threshold}
		&& !( looks_like_number( $args{threshold} ) && $args{threshold} > 0 && $args{threshold} < 1 );

	croak "socket_mode ('$args{socket_mode}') must be octal like 0660"
		if defined $args{socket_mode} && $args{socket_mode} !~ /\A0?[0-7]{3}\z/;

	my $self = {
		zorita        => $zorita,
		slug          => $args{slug},
		set           => $args{set},
		save_interval => $save_interval,
		keep          => $args{keep},
		foreground    => $args{foreground} ? 1 : 0,
		log           => $args{log},
		socket_mode   => $args{socket_mode},
		threshold     => $args{threshold},

		json => JSON::PP->new->utf8->canonical->allow_nonref(0),

		# runtime state, populated by run()
		oif        => undef,
		conn       => {},
		dirty      => 0,
		log_fh     => undef,
		run_flag   => 0,
		save_now   => 0,
		reopen_log => 0,
	};

	return bless $self, $class;
} ## end sub new

=head1 METHODS

=head2 run

    $daemon->run;

Binds the socket, resumes or creates the model, (optionally) daemonizes, and
enters the event loop until SIGTERM/SIGINT. Returns true after a clean shutdown
(socket and pid file unlinked, a final save if anything was learned).

=cut

sub run {
	my ($self) = @_;

	my %where = ( slug => $self->{slug}, set => $self->{set} );
	my $sock  = $self->{zorita}->socket_path(%where);
	my $pid   = $self->{zorita}->pid_path(%where);
	my $dir   = $self->{zorita}->set_dir(%where);
	$self->{socket}    = File::Spec->rel2abs($sock);
	$self->{pid}       = File::Spec->rel2abs($pid);
	$self->{model_dir} = File::Spec->rel2abs($dir);
	$self->{log}       = File::Spec->rel2abs( $self->{log} ) if defined $self->{log};

	# Socket.pm silently TRUNCATES an over-long sun_path (~104 bytes) and binds
	# a socket nobody can find; refuse loudly instead.
	croak 'socket path "'
		. $self->{socket} . '" is '
		. length( $self->{socket} )
		. ' bytes; Unix socket paths are limited to ~104 bytes -- use a shorter basedir'
		if length( $self->{socket} ) > 100;

	# The set dir holds the socket, pid, log, and model saves; make sure it is
	# there (it normally is, since info.json was written into it).
	$self->_ensure_dir( $self->{model_dir} );

	$self->_refuse_double_start;
	$self->_build_or_resume_model;

	my $listener = IO::Socket::UNIX->new( Local => $self->{socket}, Listen => 64 )
		or croak 'failed to listen on "' . $self->{socket} . '": ' . $!;
	$listener->blocking(0);
	if ( defined $self->{socket_mode} ) {
		chmod( oct( $self->{socket_mode} ), $self->{socket} )
			or croak 'failed to chmod "' . $self->{socket} . '": ' . $!;
	}

	if ( !$self->{foreground} ) {
		$self->{log} = $self->{zorita}->log_path(%where)
			unless defined $self->{log};
		$self->{log} = File::Spec->rel2abs( $self->{log} );
		_daemonize();
	}
	$self->_open_log;

	$self->_write_pid;

	$self->{run_flag}   = 1;
	$self->{save_now}   = 0;
	$self->{reopen_log} = 0;
	local $SIG{TERM} = sub { $self->{run_flag}   = 0 };
	local $SIG{INT}  = sub { $self->{run_flag}   = 0 };
	local $SIG{USR1} = sub { $self->{save_now}   = 1 };
	local $SIG{HUP}  = sub { $self->{reopen_log} = 1 };
	local $SIG{PIPE} = 'IGNORE';

	$self->_log( 'listening on '
			. $self->{socket}
			. ' (seen='
			. $self->{oif}->seen
			. ', save-interval='
			. $self->{save_interval} . 's, '
			. $self->{slug} . '/'
			. $self->{set}
			. ')' );

	$self->_event_loop($listener);

	$self->_log('shutting down');
	$self->_save_model('shutdown') if $self->{dirty};
	close $_->{sock} for values %{ $self->{conn} };
	$self->{conn} = {};
	close $listener;
	unlink $self->{socket};
	unlink $self->{pid};
	$self->_log('bye');

	return 1;
} ## end sub run

# The select/accept/read/save loop. Split out of run() only for readability.
sub _event_loop {
	my ( $self, $listener ) = @_;

	my $rsel      = IO::Select->new($listener);
	my $wsel      = IO::Select->new();
	my $next_save = time + $self->{save_interval};

	while ( $self->{run_flag} ) {
		my $timeout = $next_save - time;
		$timeout = 0 if $timeout < 0;

		for my $s ( $rsel->can_read($timeout) ) {
			if ( $s == $listener ) {
				while ( my $cl = $listener->accept ) {
					$cl->blocking(0);
					$self->{conn}{ fileno($cl) } = { sock => $cl, inbuf => '', outbuf => '', mode => 'prequential' };
					$rsel->add($cl);
				}
				next;
			}
			$self->_read_from( $s, $rsel, $wsel );
		} ## end for my $s ( $rsel->can_read($timeout) )

		if ( $wsel->count ) {
			$self->_flush( $_, $rsel, $wsel ) for $wsel->can_write(0);
		}

		if ( $self->{reopen_log} ) {
			$self->{reopen_log} = 0;
			$self->_open_log;
			$self->_log('log reopened on SIGHUP');
		}
		if ( $self->{save_now} || time >= $next_save ) {
			$self->_save_model( $self->{save_now} ? 'signal' : 'interval' )
				if $self->{dirty} || $self->{save_now};
			$self->{save_now} = 0;
			$next_save = time + $self->{save_interval};
		}
	} ## end while ( $self->{run_flag} )

	return 1;
} ## end sub _event_loop

#-------------------------------------------------------------------------------
# startup helpers
#-------------------------------------------------------------------------------

sub _ensure_dir {
	my ( $self, $dir ) = @_;
	if ( !-d $dir ) {
		make_path($dir);
		croak 'could not create "' . $dir . '"; create it or fix permissions'
			unless -d $dir;
	}
	croak '"' . $dir . '" is not writable; fix permissions'
		unless -w $dir;
	return 1;
} ## end sub _ensure_dir

# Refuse to start a second daemon on the same set: a live socket means one is
# already running; a stale socket/pid from an unclean exit is cleaned up.
sub _refuse_double_start {
	my ($self) = @_;

	if ( -e $self->{socket} ) {
		my $probe = IO::Socket::UNIX->new( Peer => $self->{socket} );
		croak 'another daemon is already listening on "' . $self->{socket} . '"' if $probe;
		unlink $self->{socket};
	}
	if ( -f $self->{pid} ) {
		open my $fh, '<', $self->{pid} or croak 'cannot read "' . $self->{pid} . '": ' . $!;
		my $old = <$fh>;
		close $fh;
		chomp $old if defined $old;
		if ( defined $old && $old =~ /\A\d+\z/ && ( kill( 0, $old ) || $!{EPERM} ) ) {
			croak 'another daemon appears to be running (pid ' . $old . ')';
		}
		unlink $self->{pid};
	} ## end if ( -f $self->{pid} )
	return 1;
} ## end sub _refuse_double_start

# Resume from the set's latest.json when present (it must be an online model),
# otherwise build a fresh one from info.json via the utility class.
sub _build_or_resume_model {
	my ($self) = @_;
	my %where = ( slug => $self->{slug}, set => $self->{set} );

	if ( -e $self->{zorita}->latest_path(%where) ) {
		$self->{oif} = $self->{zorita}->load_model(%where);
		croak 'resumed model is not online; the set dir holds a batch model'
			unless ref $self->{oif} eq 'Algorithm::Classifier::IsolationForest::Online';
	} else {
		$self->{oif} = $self->{zorita}->iforest(%where);
	}
	return 1;
} ## end sub _build_or_resume_model

# Classic double-fork daemonization. The parents leave via POSIX::_exit so no
# END blocks run twice. chdir / means every path used afterwards is absolute
# (run() rel2abs's them before this point).
sub _daemonize {
	defined( my $pid = fork() ) or croak 'fork failed: ' . $!;
	POSIX::_exit(0) if $pid;
	setsid()                 or croak 'setsid failed: ' . $!;
	defined( $pid = fork() ) or croak 'second fork failed: ' . $!;
	POSIX::_exit(0) if $pid;
	chdir '/'                       or croak 'chdir / failed: ' . $!;
	open( STDIN, '<', '/dev/null' ) or croak 'reopen STDIN failed: ' . $!;
	return 1;
} ## end sub _daemonize

sub _open_log {
	my ($self) = @_;
	if ( defined $self->{log} ) {
		open my $fh, '>>', $self->{log} or croak 'failed to open log "' . $self->{log} . '": ' . $!;
		$fh->autoflush(1);
		$self->{log_fh} = $fh;
		if ( !$self->{foreground} ) {
			open( STDOUT, '>>', $self->{log} ) or croak 'reopen STDOUT failed: ' . $!;
			open( STDERR, '>>', $self->{log} ) or croak 'reopen STDERR failed: ' . $!;
			STDOUT->autoflush(1);
			STDERR->autoflush(1);
		}
	} else {
		$self->{log_fh} = \*STDERR;
	}
	return 1;
} ## end sub _open_log

sub _log {
	my ( $self, $msg ) = @_;
	print { $self->{log_fh} } strftime( '%Y-%m-%dT%H:%M:%S', localtime ) . ' [' . $$ . '] ' . $msg . "\n";
	return 1;
}

sub _write_pid {
	my ($self) = @_;
	open my $fh, '>', $self->{pid} or croak 'cannot write pid "' . $self->{pid} . '": ' . $!;
	print {$fh} $$ . "\n";
	close $fh or croak 'cannot close pid "' . $self->{pid} . '": ' . $!;
	return 1;
}

#-------------------------------------------------------------------------------
# model persistence
#-------------------------------------------------------------------------------

# Timestamped save + atomic latest.json flip. Returns the file name saved to
# (relative to the set dir, which is what the symlink stores so the tree stays
# relocatable).
sub _save_model {
	my ( $self, $why ) = @_;
	my $oif = $self->{oif};

	# Keep the persisted default cutoff tracking the stream, as streamd does.
	if ( defined $oif->{contamination} && $oif->window_count ) {
		$oif->relearn_threshold;
	}

	my $base
		= $Algorithm::Classifier::IsolationForest::Zorita::ONLINE_MODEL_PREFIX . strftime( '%Y%m%d-%H%M%S', localtime );
	my $name = $base . '.json';
	my $n    = 0;
	while ( -e File::Spec->catfile( $self->{model_dir}, $name ) ) {
		$n++;
		$name = $base . '-' . $n . '.json';
	}
	$oif->save( File::Spec->catfile( $self->{model_dir}, $name ) );    # atomic

	my $tmp = File::Spec->catfile( $self->{model_dir}, '.latest.tmp.' . $$ );
	unlink $tmp;
	symlink( $name, $tmp )
		or $self->_log( 'WARNING: symlink for latest.json failed: ' . $! );
	rename( $tmp,
		File::Spec->catfile( $self->{model_dir}, $Algorithm::Classifier::IsolationForest::Zorita::LATEST_FILE ) )
		or $self->_log( 'WARNING: renaming latest.json symlink failed: ' . $! );

	$self->{dirty} = 0;
	$self->_log( 'saved ' . $name . ' (' . $why . ', seen=' . $oif->seen . ')' );
	$self->_prune_models if defined $self->{keep};
	return $name;
} ## end sub _save_model

sub _prune_models {
	my ($self) = @_;
	my $prefix = $Algorithm::Classifier::IsolationForest::Zorita::ONLINE_MODEL_PREFIX;

	opendir my $dh, $self->{model_dir} or return;
	my @models = sort { ( stat($a) )[9] <=> ( stat($b) )[9] }
		map { File::Spec->catfile( $self->{model_dir}, $_ ) }
		grep { /\A\Q$prefix\E.*\.json\z/ } readdir $dh;
	closedir $dh;

	while ( scalar @models > $self->{keep} ) {
		my $old = shift @models;
		unlink $old and $self->_log( 'pruned ' . $old );
	}
	return 1;
} ## end sub _prune_models

#-------------------------------------------------------------------------------
# connection handling
#-------------------------------------------------------------------------------

sub _drop {
	my ( $self, $s, $rsel, $wsel ) = @_;
	$rsel->remove($s);
	$wsel->remove($s);
	delete $self->{conn}{ fileno($s) };
	close $s;
	return 1;
}

sub _read_from {
	my ( $self, $s, $rsel, $wsel ) = @_;
	my $c = $self->{conn}{ fileno($s) } or return;

	my $got = sysread( $s, my $chunk, 65536 );
	if ( !defined $got ) {
		return if $!{EAGAIN} || $!{EWOULDBLOCK} || $!{EINTR};
		return $self->_drop( $s, $rsel, $wsel );
	}
	return $self->_drop( $s, $rsel, $wsel ) if $got == 0;    # client closed

	$c->{inbuf} .= $chunk;
	if ( length( $c->{inbuf} ) > MAX_INBUF() && $c->{inbuf} !~ /\n/ ) {
		$self->_log( 'dropping client: unterminated line exceeded ' . MAX_INBUF() . ' bytes' );
		return $self->_drop( $s, $rsel, $wsel );
	}

	while ( $c->{inbuf} =~ s/\A([^\n]*)\n// ) {
		my $line = $1;
		next if $line =~ /\A\s*\z/;
		$self->_handle_line( $c, $line );
		return $self->_drop( $s, $rsel, $wsel ) if length( $c->{outbuf} ) > MAX_OUTBUF();
	}
	$self->_flush( $s, $rsel, $wsel ) if length $c->{outbuf};
	return 1;
} ## end sub _read_from

sub _flush {
	my ( $self, $s, $rsel, $wsel ) = @_;
	my $c = $self->{conn}{ fileno($s) } or return;
	while ( length $c->{outbuf} ) {
		my $wrote = syswrite( $s, $c->{outbuf} );
		if ( !defined $wrote ) {
			if ( $!{EAGAIN} || $!{EWOULDBLOCK} || $!{EINTR} ) {
				$wsel->add($s) unless $wsel->exists($s);
				return;
			}
			return $self->_drop( $s, $rsel, $wsel );
		}
		substr( $c->{outbuf}, 0, $wrote, '' );
	} ## end while ( length $c->{outbuf} )
	$wsel->remove($s) if $wsel->exists($s);
	return 1;
} ## end sub _flush

# Sanity caps on per-connection buffers: a client may send big batch messages,
# but one streaming an endless line (or not reading its replies) is dropped
# rather than eating the daemon's memory.
sub MAX_INBUF  { return 16 * 1024 * 1024 }
sub MAX_OUTBUF { return 16 * 1024 * 1024 }

#-------------------------------------------------------------------------------
# protocol
#-------------------------------------------------------------------------------

# One request line -> one reply line, appended to the connection's output
# buffer. Any croak from the model becomes an {"error": ...} reply on this
# message alone; the connection and daemon live on.
sub _handle_line {
	my ( $self, $c, $line ) = @_;

	my $msg = eval { $self->{json}->decode($line) };
	if ( $@ || ref $msg ne 'HASH' ) {
		( my $err = $@ ) =~ s/ at \S+ line \d+\.?\s*\z//s;
		return $self->_reply( $c, { error => 'request is not a JSON object: ' . ( $err || 'wrong type' ) } );
	}

	my @tag = exists $msg->{tag} ? ( tag => $msg->{tag} ) : ();

	my @kinds = grep { exists $msg->{$_} } qw(row rows cmd);
	if ( scalar @kinds != 1 ) {
		return $self->_reply( $c, { error => q{request needs exactly one of "row", "rows", or "cmd"}, @tag } );
	}
	my $kind = $kinds[0];

	my $mode = exists $msg->{mode} ? $msg->{mode} : $c->{mode};
	if ( !defined $mode || ref $mode || $mode !~ /\A(?:prequential|learn|score)\z/ ) {
		return $self->_reply( $c, { error => q{mode must be "prequential", "learn", or "score"}, @tag } );
	}

	if ( $kind eq 'cmd' ) {
		return $self->_handle_cmd( $c, $msg, \@tag );
	}

	my $rows = $kind eq 'row' ? [ $msg->{row} ] : $msg->{rows};
	if ( ref $rows ne 'ARRAY' || !@$rows ) {
		return $self->_reply( $c, { error => q{"rows" must be a non-empty JSON array of rows}, @tag } );
	}

	my @scored;
	my $i = 0;
	for my $row (@$rows) {
		my $score = eval { $self->_apply_row( $row, $mode ) };
		if ($@) {
			( my $err = $@ ) =~ s/ at \S+ line \d+\.?\s*\z//s;
			chomp $err;
			my $where = $kind eq 'row' ? '' : 'row ' . $i . ': ';
			return $self->_reply( $c, { error => $where . $err, @tag } );
		}
		push @scored, $score if defined $score;
		$i++;
	} ## end for my $row (@$rows)

	if ( $mode eq 'learn' ) {
		return $self->_reply( $c, { ok => { learned => scalar @$rows }, @tag } );
	}

	my $threshold = $self->_threshold;
	my @pairs     = map { [ 0 + $_, ( $_ >= $threshold ? 1 : 0 ) ] } @scored;
	if ( $kind eq 'row' ) {
		return $self->_reply( $c, { score => $pairs[0][0], label => $pairs[0][1], @tag } );
	}
	return $self->_reply( $c, { scores => \@pairs, @tag } );
} ## end sub _handle_line

sub _handle_cmd {
	my ( $self, $c, $msg, $tag ) = @_;
	my $cmd = $msg->{cmd};
	$cmd = '' if !defined $cmd || ref $cmd;
	my $oif = $self->{oif};

	if ( $cmd eq 'ping' ) {
		return $self->_reply( $c, { ok => 'pong', @$tag } );
	}
	if ( $cmd eq 'mode' ) {
		my $mode = $msg->{mode};
		if ( !defined $mode || ref $mode || $mode !~ /\A(?:prequential|learn|score)\z/ ) {
			return $self->_reply( $c, { error => q{mode must be "prequential", "learn", or "score"}, @$tag } );
		}
		$c->{mode} = $mode;
		return $self->_reply( $c, { ok => { mode => $mode }, @$tag } );
	}
	if ( $cmd eq 'stats' ) {
		return $self->_reply(
			$c,
			{
				ok => {
					seen        => 0 + $oif->seen,
					window      => 0 + $oif->window_count,
					n_features  => ( defined $oif->{n_features} ? 0 + $oif->{n_features} : undef ),
					threshold   => 0 + $self->_threshold,
					connections => 0 + scalar( keys %{ $self->{conn} } ),
					dirty       => ( $self->{dirty} ? 1 : 0 ),
					slug        => $self->{slug},
					set         => $self->{set},
				},
				@$tag
			}
		);
	} ## end if ( $cmd eq 'stats' )
	if ( $cmd eq 'save' ) {
		my $name = eval { $self->_save_model('command') };
		if ($@) {
			( my $err = $@ ) =~ s/ at \S+ line \d+\.?\s*\z//s;
			return $self->_reply( $c, { error => $err, @$tag } );
		}
		return $self->_reply( $c, { ok => { saved => $name }, @$tag } );
	}
	if ( $cmd eq 'relearn-threshold' ) {
		my $ok = eval { $oif->relearn_threshold; 1 };
		if ( !$ok ) {
			( my $err = $@ ) =~ s/ at \S+ line \d+\.?\s*\z//s;
			chomp $err;
			return $self->_reply( $c, { error => $err, @$tag } );
		}
		return $self->_reply( $c, { ok => { threshold => 0 + $oif->decision_threshold }, @$tag } );
	}
	return $self->_reply( $c, { error => 'unknown cmd "' . $cmd . '"', @$tag } );
} ## end sub _handle_cmd

sub _reply {
	my ( $self, $c, $reply ) = @_;
	$c->{outbuf} .= $self->{json}->encode($reply) . "\n";
	return 1;
}

# The effective label cutoff, resolved per message so a relearn or the
# contamination refresh at save time takes effect immediately.
sub _threshold {
	my ($self) = @_;
	return
		  defined $self->{threshold}               ? $self->{threshold}
		: defined $self->{oif}->decision_threshold ? $self->{oif}->decision_threshold
		:                                            0.5;
}

# One row through the model. A JSON object is a tagged row (full munger plan); a
# JSON array is positional (scalar mungers). The final vector is validated
# numeric before it touches the model. Returns the score, or undef in learn
# mode. Croaks on any problem.
sub _apply_row {
	my ( $self, $row, $mode ) = @_;
	my $oif = $self->{oif};

	my $vec;
	if ( ref $row eq 'HASH' ) {
		$vec = $oif->tagged_row_to_array( $row, 'zorita-online' );
	} elsif ( ref $row eq 'ARRAY' ) {
		$vec = $row;
		if ( ref $oif->{mungers} eq 'HASH' && %{ $oif->{mungers} } ) {
			$vec = $oif->munge_rows( [$row] )->[0];
		}
	} else {
		die "row must be a JSON array (positional) or object (tagged)\n";
	}

	for my $col ( 0 .. $#$vec ) {
		next if !defined $vec->[$col];    # undef defers to the model's missing policy
		die 'column ' . ( $col + 1 ) . " is not a number after munging\n"
			unless looks_like_number( $vec->[$col] );
	}

	if ( $mode eq 'learn' ) {
		$oif->learn( [$vec] );
		$self->{dirty} = 1;
		return undef;
	}
	if ( $mode eq 'score' ) {
		return $oif->score_samples( [$vec] )->[0];
	}
	my $score = $oif->score_learn( [$vec] )->[0];
	$self->{dirty} = 1;
	return $score;
} ## end sub _apply_row

=head1 SEE ALSO

L<Algorithm::Classifier::IsolationForest::Zorita>,
L<Algorithm::Classifier::IsolationForest::Zorita::Writer>,
L<Algorithm::Classifier::IsolationForest::Online>

The wire protocol matches the upstream C<iforest streamd> command in
L<Algorithm::Classifier::IsolationForest>.

=head1 AUTHOR

Zane C. Bowers-Hadley, C<< <vvelox at vvelox.net> >>

=head1 LICENSE AND COPYRIGHT

This software is Copyright (c) 2026 by Zane C. Bowers-Hadley.

This is free software, licensed under:

  The GNU Lesser General Public License, Version 2.1, February 1999

=cut

1;    # End of Algorithm::Classifier::IsolationForest::Zorita::Online
