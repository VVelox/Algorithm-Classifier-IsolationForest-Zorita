package Algorithm::Classifier::IsolationForest::Zorita::Cmd::Command::streamc;

use 5.006;
use strict;
use warnings;

use Scalar::Util qw(looks_like_number);
use JSON::PP     ();
use Algorithm::Classifier::IsolationForest::Zorita::Cmd -command;
use Algorithm::Classifier::IsolationForest::Zorita::Online::Client ();

=head1 NAME

Algorithm::Classifier::IsolationForest::Zorita::Cmd::Command::streamc - C<zorita streamc>: client for a serving daemon.

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

=head1 SYNOPSIS

    # stream rows through the daemon (CSV on stdin), print "$score,$label"
    zorita streamc myapp stream -i -

    # JSON-lines in, the daemon's reply JSON verbatim out
    zorita streamc myapp stream --jsonl -i rows.jsonl

    # one-shot commands
    zorita streamc myapp stream --ping
    zorita streamc myapp stream --stats
    zorita streamc myapp stream --save

Talks to a running C<zorita streamd> for the given B<online> set over its
C<stream.sock>, speaking the same one-JSON-document-per-line protocol. This is
C<iforest streamc> adapted to Zorita: the set is named by C<< <slug> <set> >>
(resolved in the online tree) rather than by C<--set>/C<--socket>.

Stream mode (C<-i>) feeds rows through the daemon and prints one result per row,
in order. CSV input is positional (numeric-looking fields sent as numbers, the
rest as strings for the model's munger plan) and output is C<$score,$label>
lines, C<-d> prepending the input columns; C<--jsonl> input is a JSON row per
line (array positional, object tagged) and output is the daemon's reply JSON
verbatim. Rows go in C<--batch>-sized messages tagged with the input line
number, so a bad row dies naming its input line.

Command mode sends exactly one of C<--ping>, C<--stats>, C<--save>, or
C<--relearn-threshold> and renders the reply (C<--json> for the raw reply). The
exit code is 0 on ok and non-zero on error or connect failure, so
C<zorita streamc myapp stream --ping> works in a health check.

=head1 METHODS

These are the L<App::Cmd::Command> hooks; they are not called directly.

=head2 abstract

=head2 usage_desc

=head2 opt_spec

=head2 validate_args

Requires C<< <slug> <set> >>, then either C<-i> (stream mode) or exactly one of
the command-mode flags, matching C<iforest streamc>.

=head2 execute

Builds an L<Algorithm::Classifier::IsolationForest::Zorita::Online::Client> for
the set and dispatches to command or stream mode.

=cut

sub abstract { 'client for a serving daemon: stream rows or send commands' }

sub usage_desc { '%c streamc %o <slug> <set>' }

sub opt_spec {
	return (
		[ 'timeout=i', 'seconds to wait for each reply from the daemon (default: 30)', { default => 30 } ],

		# stream mode
		[ 'input|i=s',  'input to stream, one row per line; - reads stdin' ],
		[ 'output|o=s', 'write results to this file instead of printing' ],
		[ 'w',          'overwrite the -o file if it exists' ],
		[ 'd',          'include the input data in the output (CSV input only)' ],
		[ 'mode=s',     "per-row action: prequential (default), learn, or score", { default => 'prequential' } ],
		[ 'jsonl',      'input lines are JSON rows; output is the reply JSON verbatim' ],
		[ 'batch=i',    'rows per request message (default: 256)', { default => 256 } ],

		# command mode
		[ 'ping',              'check the daemon is alive; exits 0 on pong' ],
		[ 'stats',             'print the daemon stats' ],
		[ 'save',              'ask the daemon to save the model now; prints the file name' ],
		[ 'relearn-threshold', 'ask the daemon to relearn the decision threshold' ],
		[ 'json',              'command mode: print the raw JSON reply instead of text' ],
	);
} ## end sub opt_spec

sub validate_args {
	my ( $self, $opt, $args ) = @_;

	$self->usage_error('streamc requires <slug> and <set>')
		unless @$args == 2;

	my @cmds = grep { $opt->{$_} } qw(ping stats save relearn_threshold);
	if ( defined $opt->input ) {
		$self->usage_error('-i may not be combined with --ping/--stats/--save/--relearn-threshold')
			if @cmds;
	} elsif ( @cmds != 1 ) {
		$self->usage_error(
			'need either -i (stream mode) or exactly one of --ping, --stats, --save, --relearn-threshold');
	}

	if ( defined $opt->input && $opt->input ne '-' ) {
		$self->usage_error( '-i, "' . $opt->input . '", is not a file or does not exist' )
			unless -f $opt->input;
		$self->usage_error( '-i, "' . $opt->input . '", is not readable' )
			unless -r $opt->input;
	}

	$self->usage_error( '-o, "' . $opt->output . '", already exists and -w is not specified' )
		if defined $opt->output && !$opt->w && -e $opt->output;

	$self->usage_error( '--mode, "' . $opt->mode . '", must be prequential, learn, or score' )
		unless $opt->mode =~ /\A(?:prequential|learn|score)\z/;

	$self->usage_error('-d only applies to CSV input; --jsonl replies are already self-describing')
		if $opt->d && $opt->jsonl;

	$self->usage_error('--json only applies to command mode')
		if $opt->json && defined $opt->input;

	$self->usage_error( '--batch, "' . $opt->batch . '", must be >= 1' )
		if $opt->batch < 1;

	$self->usage_error( '--timeout, "' . $opt->timeout . '", must be >= 1' )
		if $opt->timeout < 1;

	return 1;
} ## end sub validate_args

sub execute {
	my ( $self, $opt, $args ) = @_;
	my ( $slug, $set ) = @$args;

	my $client = Algorithm::Classifier::IsolationForest::Zorita::Online::Client->new(
		zorita  => $self->app->zorita_for('online'),
		slug    => $slug,
		set     => $set,
		timeout => $opt->timeout,
	);

	return defined $opt->input
		? $self->_stream( $opt, $client )
		: $self->_command( $opt, $client );
} ## end sub execute

# Command mode: send the single requested command and render its reply.
sub _command {
	my ( $self, $opt, $client ) = @_;

	my ($which) = grep { $opt->{$_} } qw(ping stats save relearn_threshold);
	( my $cmd = $which ) =~ tr/_/-/;

	my $reply = $client->request( { cmd => $cmd } );
	die 'daemon error: ' . $reply->{error} . "\n" if defined $reply->{error};

	if ( $opt->json ) {
		print $client->last_raw . "\n";
		return 1;
	}

	my $ok = $reply->{ok};
	if ( ref $ok eq 'HASH' ) {
		for my $k ( sort keys %$ok ) {
			printf "  %-20s  %s\n", $k, ( defined $ok->{$k} ? $ok->{$k} : '(unset)' );
		}
	} else {
		print( ( defined $ok ? $ok : 'ok' ) . "\n" );
	}
	return 1;
} ## end sub _command

# Stream mode: read rows, send them in --batch sized messages, print results.
sub _stream {
	my ( $self, $opt, $client ) = @_;

	my $in_fh;
	if ( $opt->input eq '-' ) {
		$in_fh = \*STDIN;
	} else {
		open $in_fh, '<', $opt->input or die '-i, "' . $opt->input . '": ' . $! . "\n";
	}

	# -o accumulates and writes once at the end (so it is unsuitable for an
	# endless stdin); without it, results print as replies arrive.
	my $results = '';
	my $emit    = sub {
		if ( defined $opt->output ) { $results .= $_[0] . "\n" }
		else                        { print $_[0] . "\n" }
	};

	my $expected_cols;
	my @rows;               # decoded rows for the pending request
	my @raw;                # matching raw input lines, for -d
	my $batch_start = 1;    # input line number of $rows[0]
	my $line_no     = 0;

	my $flush = sub {
		return unless @rows;
		my $reply = $client->request( { rows => [@rows], mode => $opt->mode, tag => $batch_start } );
		if ( defined $reply->{error} ) {
			my $line = $batch_start;
			my $err  = $reply->{error};
			# Batch errors come back as "row N: ..." with N relative to the
			# message; map it back to the input line.
			$line = $batch_start + $1 if $err =~ s/\Arow (\d+): //;
			die 'line ' . $line . ' of input: ' . $err . "\n";
		}
		if ( $opt->mode ne 'learn' ) {
			if ( $opt->jsonl ) {
				$emit->( $client->last_raw );
			} else {
				my $pairs = $reply->{scores};
				for my $i ( 0 .. $#$pairs ) {
					my $prefix = $opt->d ? $raw[$i] . ',' : '';
					$emit->( $prefix . $pairs->[$i][0] . ',' . $pairs->[$i][1] );
				}
			}
		} ## end if ( $opt->mode ne 'learn' )
		@rows        = ();
		@raw         = ();
		$batch_start = $line_no + 1;
		return 1;
	}; ## end $flush = sub

	my $json = JSON::PP->new->utf8->canonical;
	while ( my $line = <$in_fh> ) {
		$line_no++;
		chomp $line;
		if ( $line =~ /\A\s*\z/ ) {
			$flush->();    # keep line-number accounting exact across blanks
			$batch_start = $line_no + 1;
			next;
		}

		if ( $opt->jsonl ) {
			my $row = eval { $json->decode($line) };
			die 'line ' . $line_no . ' of input did not parse as JSON: ' . $@ if $@;
			die 'line ' . $line_no . ' of input must be a JSON array (positional) or object (tagged)' . "\n"
				unless ref $row eq 'ARRAY' || ref $row eq 'HASH';
			push @rows, $row;
		} else {
			my @fields = split /,/, $line, -1;
			if ( !defined $expected_cols ) {
				$expected_cols = scalar @fields;
				die 'line ' . $line_no . ' of input has no columns' . "\n" if $expected_cols < 1;
			} elsif ( scalar @fields != $expected_cols ) {
				die 'line '
					. $line_no
					. ' of input has '
					. scalar(@fields)
					. ' columns but expected '
					. $expected_cols . "\n";
			}

			# Numeric-looking fields travel as JSON numbers, the rest as strings
			# for the daemon's munger plan; the daemon owns validation either way.
			push @rows, [ map { looks_like_number($_) ? 0 + $_ : $_ } @fields ];
			push @raw,  $line;
		} ## end else [ if ( $opt->jsonl ) ]

		$flush->() if scalar @rows >= $opt->batch;
	} ## end while ( my $line = <$in_fh> )
	$flush->();

	if ( defined $opt->output ) {
		open my $ofh, '>', $opt->output or die '-o, "' . $opt->output . '": ' . $! . "\n";
		print {$ofh} $results;
		close $ofh or die '-o, "' . $opt->output . '": ' . $! . "\n";
	}
	return 1;
} ## end sub _stream

=head1 SEE ALSO

L<Algorithm::Classifier::IsolationForest::Zorita::Online::Client>,
L<Algorithm::Classifier::IsolationForest::Zorita::Cmd::Command::streamd>

=head1 AUTHOR

Zane C. Bowers-Hadley, C<< <vvelox at vvelox.net> >>

=head1 LICENSE AND COPYRIGHT

This software is Copyright (c) 2026 by Zane C. Bowers-Hadley.

This is free software, licensed under:

  The GNU Lesser General Public License, Version 2.1, February 1999

=cut

1;    # End of ...::Zorita::Cmd::Command::streamc
