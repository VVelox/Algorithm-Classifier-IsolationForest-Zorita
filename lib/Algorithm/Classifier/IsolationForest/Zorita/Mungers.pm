package Algorithm::Classifier::IsolationForest::Zorita::Mungers;

use 5.006;
use strict;
use warnings;

use Carp         qw(croak carp);
use Scalar::Util qw(looks_like_number);

=head1 NAME

Algorithm::Classifier::IsolationForest::Zorita::Mungers - Input mungers that turn raw values into the numbers stored in a Zorita CSV.

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

# Feature hashing (the 'hash' munger) is a tight per-byte FNV-1a loop with a
# 32-bit modular multiply. That is exactly the kind of work XS is good at and
# pure Perl is bad at (both for speed and, on a 32-bit perl, for correctness of
# the wrap-around), so we compile it in C when we can. Everything else here is a
# hash lookup or a couple of flops -- crossing the XS boundary per row would
# only make those slower, so they stay pure Perl. If the XS did not build (no
# compiler at install time) we fall back to a pure-Perl FNV-1a, which is exact
# on a 64-bit perl.
our $HAVE_XS = 0;
eval {
	require XSLoader;
	XSLoader::load( __PACKAGE__, $VERSION );
	$HAVE_XS = 1;
	1;
};

=head1 SYNOPSIS

    use Algorithm::Classifier::IsolationForest::Zorita::Mungers;

    # one munger from an info.json spec
    my $code = Algorithm::Classifier::IsolationForest::Zorita::Mungers->build(
        { munger => 'enum', map => { GET => 0, POST => 1, PUT => 2 } },
    );
    my $n = $code->('POST');          # 1

    # all of a set's mungers at once, from info.json's 'mungers' hash
    my $by_tag = Algorithm::Classifier::IsolationForest::Zorita::Mungers->build_all(
        $info->{mungers},
    );
    my $row_value = $by_tag->{method}->($raw{method});

=head1 DESCRIPTION

A Zorita set stores raw numeric CSV, but the values a writer is handed are not
always numbers to begin with -- an HTTP method is a string, a timestamp is a
formatted date, a high-cardinality label wants bucketing. An B<input munger>
turns such a raw value into the number that gets written to the CSV. Munging
happens on the input side, at write time, before a row is appended.

Mungers are declared per tag in a set's C<info.json> under the optional
C<mungers> key (see
L<Algorithm::Classifier::IsolationForest::Zorita/INPUT MUNGING>). Each entry
names a built-in munger and carries that munger's parameters:

    "mungers": {
        "method": { "munger": "enum",  "map": { "GET": 0, "POST": 1 } },
        "bytes":  { "munger": "log",   "offset": 1 },
        "label":  { "munger": "hash",  "buckets": 1024 }
    }

B<Any tag without an entry is raw> and is written through unchanged; this module
is only concerned with tags that name a munger.

This class does not read or write files. It B<compiles> a spec into a closure
that maps one raw value to one number, so a caller (e.g. the Writer) can build
its mungers once from C<info.json> and then apply them per row with no
re-parsing. All configuration errors are caught at build time; the returned
closure only croaks on genuinely un-mungeable I<input>.

=head1 CLASS METHODS

=head2 build

    my $code = ...->build( \%spec );
    my $code = ...->build( \%spec, $tag_name );   # $tag_name only sharpens errors

Compile a single munger spec into a coderef. C<%spec> must contain a C<munger>
key naming one of the L</BUILT-IN MUNGERS>; the remaining keys are that munger's
parameters. Croaks on an unknown munger name or an invalid parameter set. The
optional second argument is only used to make error messages point at a tag.

=cut

# name => builder. Each builder validates its slice of the spec up front and
# returns the per-value closure. Keeping them in a table (rather than a big
# if/elsif) is what makes known_mungers() and has_munger() cheap and honest.
my %BUILDERS = (
	enum     => \&_build_enum,
	freq_map => \&_build_freq_map,
	bool     => \&_build_bool,
	length   => \&_build_length,
	entropy  => \&_build_entropy,
	char     => \&_build_char,
	count    => \&_build_count,
	bucket   => \&_build_bucket,
	scale    => \&_build_scale,
	zscore   => \&_build_zscore,
	log      => \&_build_log,
	clamp    => \&_build_clamp,
	datetime => \&_build_datetime,
	hash     => \&_build_hash,
	eps      => \&_build_eps,
);

# Status-class mungers (http_enum, smtp_enum, sip_enum) are one transform --
# collapse a numeric reply code to its leading digit, int(code/100) -- differing
# only in which range 'strict' accepts. Register them all from this table so a
# new protocol is a single line and they can never drift apart.
my %STATUS_PROTO = (
	http => [ 100, 599 ],    # 1xx-5xx
	smtp => [ 200, 599 ],    # 2xx-5xx; SMTP never issues 1yz in practice
	sip  => [ 100, 699 ],    # 1xx-6xx; SIP adds a 6xx global-failure class
	ftp  => [ 100, 599 ],    # 1xx-5xx FTP reply codes
);
for my $proto ( keys %STATUS_PROTO ) {
	my ( $lo, $hi ) = @{ $STATUS_PROTO{$proto} };
	$BUILDERS{"${proto}_enum"}
		= sub { _status_class_munger( $proto, $lo, $hi, @_ ) };
}

sub build {
	my ( $class, $spec, $tag ) = @_;
	my $where = defined $tag ? " for tag '$tag'" : '';

	croak "munger spec$where must be a hashref"
		unless ref $spec eq 'HASH';

	my $name = $spec->{munger};
	croak "munger spec$where has no 'munger' name"
		unless defined $name && length $name;

	my $builder = $BUILDERS{$name}
		or croak "unknown munger '$name'$where (known: " . join( ', ', $class->known_mungers ) . ')';

	return $builder->( $spec, $where );
} ## end sub build

=head2 build_all

    my $by_tag = ...->build_all( $info->{mungers} );

Compile a whole C<mungers> hash (tag name => spec) into a hash of tag name =>
coderef. A false/absent argument yields an empty hashref (every tag is raw).
Croaks if any spec is invalid, naming the offending tag.

=cut

sub build_all {
	my ( $class, $mungers ) = @_;
	return {} unless $mungers;

	croak "'mungers' must be a hashref"
		unless ref $mungers eq 'HASH';

	my %by_tag;
	for my $tag ( keys %$mungers ) {
		$by_tag{$tag} = $class->build( $mungers->{$tag}, $tag );
	}
	return \%by_tag;
} ## end sub build_all

=head2 compile

    my $plan = ...->compile( tags => \@tags, mungers => $info->{mungers} );
    my $row  = $plan->apply_named( \%named_input );   # numbers, in tags order

Compile a set's C<tags> and (optional) C<mungers> into a B<plan> object that maps
one input record to a fully-numeric row in tag order. Unlike L</build_all> (which
just compiles each spec in isolation), C<compile> understands the whole set:

=over 4

=item * a scalar munger, keyed by its output tag, fills that one column; its
input is read from the tag's own name, or from C<< from => 'other' >> to alias a
source field;

=item * an B<expanding> munger, keyed by any label and carrying C<< into =>
[tag, ...] >>, reads one source (C<from>, defaulting to the label) and fills
several columns at once -- this is how a single timestamp becomes both a
C<sin>/C<cos> pair without the two ever drifting apart (see L</datetime>);

=item * every remaining tag is B<raw> and passed through unchanged.

=back

Coverage is validated up front: C<compile> croaks if two mungers write the same
column, if an C<into> names a column not in C<tags>, if a munger key is neither a
tag nor an expander, or if an expander's output count does not match its C<into>.
The returned plan has two methods, both returning an arrayref of numbers in
C<tags> order: C<apply_named(\%hash)> (keyed by field name, the only form that
supports expanders) and C<apply_positional(\@row)> (positional; croaks if the set
has any expanding munger, since a shared source cannot be expressed by position).

=cut

# name => builder returning ($list_returning_code, $arity), for the mungers that
# can fan one input out into several columns via 'into'.
my %MULTI_BUILDERS = (
	datetime => \&_build_datetime_multi,
	eps      => \&_build_eps_multi,
);

sub _build_multi {
	my ( $class, $spec, $where ) = @_;
	my $name = $spec->{munger};
	croak "munger spec$where has no 'munger' name"
		unless defined $name && length $name;
	my $builder = $MULTI_BUILDERS{$name}
		or croak "munger '$name'$where does not support multiple outputs "
		. "('into'); only these do: "
		. join( ', ', sort keys %MULTI_BUILDERS );
	return $builder->( $spec, $where );
} ## end sub _build_multi

sub compile {
	my ( $class, %args ) = @_;

	my $tags = $args{tags};
	croak "compile requires a non-empty 'tags' arrayref"
		unless ref $tags eq 'ARRAY' && @$tags;
	my $mungers = $args{mungers} || {};
	croak "compile: 'mungers' must be a hashref"
		unless ref $mungers eq 'HASH';

	my %pos;
	for my $i ( 0 .. $#$tags ) {
		croak "compile: duplicate tag '$tags->[$i]'"
			if exists $pos{ $tags->[$i] };
		$pos{ $tags->[$i] } = $i;
	}

	my ( @scalar, @expand, %claimed );
	my $claim = sub {
		my ( $tag, $by ) = @_;
		croak "munger '$by' targets unknown column '$tag'"
			unless exists $pos{$tag};
		croak "two mungers write column '$tag'"
			if $claimed{$tag}++;
	};

	for my $key ( sort keys %$mungers ) {
		my $spec = $mungers->{$key};
		croak "munger '$key' spec must be a hashref"
			unless ref $spec eq 'HASH';
		my $from = defined $spec->{from} ? $spec->{from} : $key;

		if ( defined $spec->{into} ) {
			my $into = $spec->{into};
			croak "munger '$key': 'into' must be a non-empty arrayref"
				unless ref $into eq 'ARRAY' && @$into;
			my ( $code, $arity ) = $class->_build_multi( $spec, " for '$key'" );
			croak "munger '$key' produces $arity value(s) but 'into' lists " . scalar(@$into)
				unless $arity == @$into;
			$claim->( $_, $key ) for @$into;
			push @expand, { from => $from, into => [@$into], code => $code };
		} else {
			croak "munger '$key' is not a declared tag and has no 'into'"
				unless exists $pos{$key};
			$claim->( $key, $key );
			push @scalar, { tag => $key, from => $from, code => $class->build( $spec, $key ) };
		}
	} ## end for my $key ( sort keys %$mungers )

	for my $tag (@$tags) {
		push @scalar, { tag => $tag, from => $tag, code => undef }
			unless $claimed{$tag};
	}

	return bless {
		tags   => [@$tags],
		pos    => \%pos,
		scalar => \@scalar,
		expand => \@expand,
		},
		"${class}::Plan";
} ## end sub compile

=head2 known_mungers

    my @names = ...->known_mungers;

The sorted list of built-in munger names this version understands.

=head2 has_munger

    if ( ...->has_munger('enum') ) { ... }

True if the named munger is built in.

=cut

sub known_mungers { my @names = sort keys %BUILDERS; return @names }
sub has_munger    { return exists $BUILDERS{ $_[1] } }

=head1 BUILT-IN MUNGERS

Every munger returns a plain number and, where the input cannot be interpreted,
croaks -- the Writer would reject a non-numeric field anyway, so failing at the
munger gives a better message. Parameters are validated when the munger is
built, not per row.

=head2 enum

    { munger => 'enum', map => { GET => 0, POST => 1 }, default => -1 }

Categorical string to number via an explicit C<map>. All map values must be
numeric. Without a C<default>, an unmapped input croaks; with one, unmapped
inputs (including C<undef>) yield the default.

=cut

sub _build_enum {
	my ( $spec, $where ) = @_;

	my $map = $spec->{map};
	croak "enum munger$where requires a 'map' hashref"
		unless ref $map eq 'HASH';

	for my $k ( keys %$map ) {
		croak "enum munger$where: map value for '$k' ('"
			. ( defined $map->{$k} ? $map->{$k} : 'undef' )
			. "') is not numeric"
			unless looks_like_number( $map->{$k} );
	}

	my $has_default = exists $spec->{default};
	my $default     = $spec->{default};
	croak "enum munger$where: 'default' must be numeric"
		if $has_default && !looks_like_number($default);

	# Copy so a later edit of the caller's spec cannot mutate a live munger.
	my %m = %$map;
	return sub {
		my ($v) = @_;
		return $m{$v}   if defined $v && exists $m{$v};
		return $default if $has_default;
		croak "enum munger$where: no mapping for '" . ( defined $v ? $v : 'undef' ) . "'";
	};
} ## end sub _build_enum

=head2 freq_map

    { munger => 'freq_map', counts => { jpg => 40213, exe => 12, scr => 3 },
      total => 67560 }
    # defaults: mode => 'neg_log_prob', smoothing => 1, unseen => 'rare'

Frequency-encoding from a B<precomputed, frozen> count table: the rarer a value
was when the table was built, the more anomalous it scores. This is C<enum>'s
cousin -- a value-to-number map -- except the numbers are derived from observed
C<counts> rather than hand-authored, with the smoothing and unseen-value policy
that "rare = interesting" needs. It stays a stateless munger: the table is
computed offline and shipped in C<info.json>; this class only I<applies> it.

C<counts> maps each value to how many times it was seen. C<total> is the overall
observation count; it defaults to the sum of C<counts>, but may be given
explicitly and larger so you can B<prune the long tail> out of C<counts> while
still computing correct probabilities. The emitted number depends on C<mode>:

=over 4

=item * C<neg_log_prob> (default) - self-information C<-ln(prob)>: rare values
score high, common ones low. This is the axis "rare = interesting" describes and
what an Isolation Forest splits on most naturally.

=item * C<freq> - the probability itself, C<(count + smoothing) / denom>.

=item * C<log_count> - C<ln(1 + count)>, the count with its heavy tail tamed.

=item * C<count> - the raw count.

=back

Probabilities use add-one style C<smoothing> (default C<1>), treating "unseen" as
one aggregate bucket: C<prob(v) = (count + smoothing) / (total + smoothing*(V+1))>
where C<V> is the number of listed values. C<unseen> controls what a value absent
from the table maps to -- C<'rare'> (default) emits that value under the current
mode as if it had been seen zero times (for C<neg_log_prob>/C<freq> this is the
smoothed unseen bucket, for C<count>/C<log_count> it is C<0>), or a number to
force a fixed default. Because an unseen value is usually the very thing you are
hunting, mapping it to "maximally rare" rather than erroring is the point.

C<freq_map> only suits B<bounded, moderate-cardinality> columns (extensions,
vendor classes, named pipes, keyboard layouts, link addresses): the table lives
in C<info.json>, so a huge one bloats every read -- building one past
C<$Algorithm::Classifier::IsolationForest::Zorita::Mungers::FREQ_MAP_WARN_KEYS>
values (default 10000) warns. For unbounded cardinality (JA3, full user-agents)
use L</hash> instead, which needs no table but keeps only decorrelation, not
commonness.

=cut

# name => 1 for the recognized freq_map output modes.
my %FREQ_MODE = map { $_ => 1 } qw(neg_log_prob freq log_count count);

# Building a table larger than this warns: info.json ships the whole map, so a
# high-cardinality column belongs in the 'hash' munger instead.
our $FREQ_MAP_WARN_KEYS = 10_000;

sub _build_freq_map {
	my ( $spec, $where ) = @_;

	my $counts = $spec->{counts};
	croak "freq_map munger$where requires a non-empty 'counts' hashref"
		unless ref $counts eq 'HASH' && %$counts;

	my $sum = 0;
	for my $k ( keys %$counts ) {
		my $c = $counts->{$k};
		croak "freq_map munger$where: count for '$k' ('"
			. ( defined $c ? $c : 'undef' )
			. "') is not a non-negative number"
			unless looks_like_number($c) && $c >= 0;
		$sum += $c;
	}

	my $V = keys %$counts;
	carp "freq_map munger$where: 'counts' has $V keys; a table this large bloats "
		. "info.json -- consider the 'hash' munger for unbounded cardinality"
		if $V > $FREQ_MAP_WARN_KEYS;

	my $total = defined $spec->{total} ? $spec->{total} : $sum;
	croak "freq_map munger$where: 'total' must be numeric"
		unless looks_like_number($total);
	croak "freq_map munger$where: 'total' ($total) must be >= sum of counts ($sum)"
		if $total < $sum;

	my $mode = defined $spec->{mode} ? $spec->{mode} : 'neg_log_prob';
	croak "freq_map munger$where: unknown mode '$mode' (known: " . join( ', ', sort keys %FREQ_MODE ) . ')'
		unless $FREQ_MODE{$mode};

	my $s = defined $spec->{smoothing} ? $spec->{smoothing} : 1;
	croak "freq_map munger$where: 'smoothing' must be a non-negative number"
		unless looks_like_number($s) && $s >= 0;

	my $unseen = defined $spec->{unseen} ? $spec->{unseen} : 'rare';
	croak "freq_map munger$where: 'unseen' must be 'rare' or a number"
		unless $unseen eq 'rare' || looks_like_number($unseen);

	# An unseen value under neg_log_prob has probability s/denom; with no
	# smoothing that is 0 and -ln(0) is infinite, which would poison the column.
	# Refuse to build rather than emit inf.
	croak "freq_map munger$where: mode 'neg_log_prob' with unseen => 'rare' needs "
		. "smoothing > 0 (an unseen value would otherwise be infinitely surprising)"
		if $mode eq 'neg_log_prob' && $unseen eq 'rare' && $s == 0;

	# Smoothed-probability denominator, treating "unseen" as one extra bucket.
	my $denom = $total + $s * ( $V + 1 );

	# raw count -> emitted number under the chosen mode.
	my $emit_for = sub {
		my ($c) = @_;
		return $c            if $mode eq 'count';
		return log( 1 + $c ) if $mode eq 'log_count';
		my $p = ( $c + $s ) / $denom;
		return $p if $mode eq 'freq';
		return -log($p);    # neg_log_prob
	};

	my %emit         = map { $_ => $emit_for->( $counts->{$_} ) } keys %$counts;
	my $unseen_value = $unseen eq 'rare' ? $emit_for->(0) : $unseen;

	return sub {
		my ($v) = @_;
		return defined $v && exists $emit{$v} ? $emit{$v} : $unseen_value;
	};
} ## end sub _build_freq_map

=head2 http_enum

    { munger => 'http_enum' }
    { munger => 'http_enum', strict => 1 }

Collapse an HTTP status code to its class: C<1xx> to C<1>, C<2xx> to C<2>, C<3xx>
to C<3>, and so on (i.e. C<int(code / 100)>). This is the usual bucketing for an
HTTP status column -- the forest cares far more about "was this a 4xx vs a 2xx"
than about C<403> vs C<404>, and it keeps the feature low-cardinality without
having to spell out every code in an C<enum> C<map>. The input must be numeric.

By default any numeric input is bucketed, so a bogus C<700> would quietly become
C<7>. With a true C<strict>, inputs outside the valid HTTP status range
(C<100>-C<599>) croak instead, so a malformed code is caught at write time rather
than smuggled into the model as a spurious class.

=head2 smtp_enum

    { munger => 'smtp_enum' }
    { munger => 'smtp_enum', strict => 1 }

The SMTP counterpart of L</http_enum>: collapse an SMTP reply code to its leading
digit (C<int(code / 100)>), since that digit I<is> the reply's meaning -- C<2yz>
completion, C<3yz> intermediate, C<4yz> transient failure, C<5yz> permanent
failure. As with C<http_enum> this keeps the column low-cardinality and lets the
forest weigh "a 5xx where a 2xx was expected" without enumerating every code.

With a true C<strict>, inputs outside the valid SMTP reply range (C<200>-C<599>)
croak. SMTP never issues C<1yz> replies in practice (no command permits a
positive-preliminary reply), so the strict floor is C<200> rather than
C<http_enum>'s C<100>.

=head2 sip_enum

    { munger => 'sip_enum' }
    { munger => 'sip_enum', strict => 1 }

The SIP counterpart of L</http_enum>: collapse a SIP status code to its leading
digit (C<int(code / 100)>). SIP reuses HTTP's class scheme but adds a sixth
class -- C<1xx> provisional, C<2xx> success, C<3xx> redirection, C<4xx> client
error, C<5xx> server error, C<6xx> global failure.

With a true C<strict>, inputs outside the valid SIP status range (C<100>-C<699>)
croak. The ceiling is C<699> rather than C<http_enum>'s C<599> precisely because
of that C<6xx> global-failure class.

=head2 ftp_enum

    { munger => 'ftp_enum' }
    { munger => 'ftp_enum', strict => 1 }

The FTP counterpart of L</http_enum>, for FTP reply codes: C<int(code / 100)>,
bucketing into C<1yz>-C<5yz>. With a true C<strict>, inputs outside C<100>-C<599>
croak.

=cut

# Shared closure for the status-class mungers registered from %STATUS_PROTO.
sub _status_class_munger {
	my ( $proto, $lo, $hi, $spec, $where ) = @_;
	my $strict = $spec->{strict} ? 1 : 0;
	return sub {
		my ($v) = @_;
		croak "${proto}_enum munger$where: '" . ( defined $v ? $v : 'undef' ) . "' is not a numeric status code"
			unless looks_like_number($v);
		croak "${proto}_enum munger$where: status code '$v' is out of range " . "($lo-$hi)"
			if $strict && ( $v < $lo || $v > $hi );
		return int( $v / 100 );
	};
} ## end sub _status_class_munger

=head2 bool

    { munger => 'bool' }                       # Perl truthiness -> 1/0
    { munger => 'bool', true => [ 'yes', 'Y', '1', 'true' ] }

Coerce to C<1> or C<0>. With a C<true> list, only those (string-compared) values
are C<1>; otherwise ordinary Perl truthiness is used.

=cut

sub _build_bool {
	my ( $spec, $where ) = @_;

	if ( exists $spec->{true} ) {
		croak "bool munger$where: 'true' must be an arrayref"
			unless ref $spec->{true} eq 'ARRAY';
		my %true = map { $_ => 1 } @{ $spec->{true} };
		return sub {
			my ($v) = @_;
			return exists $true{ defined $v ? $v : '' } ? 1 : 0;
		};
	}

	return sub { $_[0] ? 1 : 0 };
} ## end sub _build_bool

=head2 length

    { munger => 'length' }

The character length of the stringified input, C<undef> counting as C<0> (an
absent value is a zero-length one -- e.g. an SNI-absent TLS record). This is the
cheap shape feature behind every C<*_length> column (domain, URL, filename, SNI,
hostname, ...): tunneling and generated names run long, so raw length is a
surprisingly strong corroborator next to L</entropy>. Length is counted in
B<characters>, not bytes, so a multi-byte name is measured as a human would read
it; use L</entropy> (which is byte-oriented) when you want per-symbol randomness.

=cut

sub _build_length {
	my ( $spec, $where ) = @_;
	return sub {
		my ($v) = @_;
		return length( defined $v ? "$v" : '' );
	};
}

=head2 entropy

    { munger => 'entropy' }

Shannon entropy of the input string, in B<bits per symbol> -- i.e.
C<-sum(p*log2(p))> over the frequencies of its bytes. This is the single most
common feature in the pipeline (DGA domains, randomized filenames, forged
User-Agents, generated SNIs / hostnames / principal names), because
machine-generated strings spread their characters far more evenly than
human-chosen ones and so score high, while a real word scores low. An empty
string is C<0>; the maximum is C<8> (every byte value equally likely).

Entropy is computed over the string's B<UTF-8 bytes> (matching L</hash>), so the
value is well-defined regardless of the scalar's internal encoding flag. Like
C<hash>, this munger is XS-accelerated -- a per-byte histogram plus a C<log> per
distinct byte -- with a pure-Perl fallback that produces identical values;
C<$Algorithm::Classifier::IsolationForest::Zorita::Mungers::HAVE_XS> says which
is in use.

=cut

sub _build_entropy {
	my ( $spec, $where ) = @_;
	my $fn = $HAVE_XS ? \&_entropy_xs : \&_entropy_pp;
	return sub {
		my ($v) = @_;
		return $fn->( defined $v ? "$v" : '' );
	};
}

# Pure-Perl Shannon entropy (bits), used only when the XS did not build. Byte
# view via an explicit encode so it matches the XS's SvPVutf8, and so the same
# string scores the same regardless of its internal flag.
sub _entropy_pp {
	my ($str) = @_;
	utf8::encode($str);
	my $n = length $str;
	return 0 unless $n;
	my %count;
	$count{$_}++ for unpack 'C*', $str;
	my $ln2 = log(2);
	my $h   = 0;

	for my $c ( values %count ) {
		my $p = $c / $n;
		$h -= $p * ( log($p) / $ln2 );
	}
	return $h;
} ## end sub _entropy_pp

=head2 char

    { munger => 'char', class => 'non_alnum', mode => 'ratio' }
    { munger => 'char', class => 'non_ascii' }               # mode defaults to count

Count the characters of the input that fall in a named C<class>, either as a raw
C<count> (default) or, with C<< mode => 'ratio' >>, as a fraction of the string's
length (C<0> for an empty string). This is the injection / obfuscation detector
behind columns like C<url_non_alnum> (a I<ratio>, so it stays independent of
length) and C<filename_non_ascii> (a I<count>): payloads and homoglyph tricks
are dense with punctuation, percent-encoding, or non-ASCII where normal input is
not. Counting is over B<characters>, so C<non_ascii> means codepoints above 127.

Recognised classes: C<alnum> / C<non_alnum>, C<ascii> / C<non_ascii>, C<digit>,
C<alpha>, C<upper>, C<lower>, C<space>, C<punct>.

=cut

# class name => a counting sub over an (already copied) string. The literal-
# range classes count with tr///, which runs at C speed -- an order of
# magnitude faster than tallying regex matches. tr/// needs its ranges spelled
# at compile time, hence one sub per class rather than a data table.
my %CHAR_COUNT = (
	alnum     => sub { $_[0] =~ tr/A-Za-z0-9// },
	non_alnum => sub { $_[0] =~ tr/A-Za-z0-9//c },
	ascii     => sub { $_[0] =~ tr/\x00-\x7f// },
	non_ascii => sub { $_[0] =~ tr/\x00-\x7f//c },
	digit     => sub { $_[0] =~ tr/0-9// },
	alpha     => sub { $_[0] =~ tr/A-Za-z// },
	upper     => sub { $_[0] =~ tr/A-Z// },
	lower     => sub { $_[0] =~ tr/a-z// },
	# space and punct match richer classes (\s, [[:punct:]], including their
	# Unicode behavior) that tr/// ranges cannot reproduce; they stay on the
	# regex so their semantics do not change.
	space => sub { my $n = () = $_[0] =~ /\s/g;          $n },
	punct => sub { my $n = () = $_[0] =~ /[[:punct:]]/g; $n },
);

sub _build_char {
	my ( $spec, $where ) = @_;

	my $class = $spec->{class};
	croak "char munger$where requires a 'class'"
		unless defined $class;
	my $count = $CHAR_COUNT{$class}
		or croak "char munger$where: unknown class '$class' (known: " . join( ', ', sort keys %CHAR_COUNT ) . ')';

	my $mode = defined $spec->{mode} ? $spec->{mode} : 'count';
	croak "char munger$where: 'mode' must be 'count' or 'ratio'"
		unless $mode eq 'count' || $mode eq 'ratio';
	my $ratio = $mode eq 'ratio' ? 1 : 0;

	return sub {
		my ($v) = @_;
		my $s   = defined $v ? "$v" : '';
		my $n   = $count->($s);
		return $n unless $ratio;
		my $len = length $s;
		return $len ? $n / $len : 0;
	};
} ## end sub _build_char

=head2 count

    { munger => 'count', of => '/' }             # url_path_depth, topic_depth
    { munger => 'count', of => '.', plus => 1 }  # label_count (dots + 1)

Count non-overlapping occurrences of a literal substring C<of> in the input,
optionally adding a constant C<plus>. This is the segment/depth feature behind
C<url_path_depth> and C<topic_depth> (count of C<`/`>) and C<label_count> (dots
plus one). C<of> is matched literally, not as a pattern, so C<.> means a literal
dot.

=cut

sub _build_count {
	my ( $spec, $where ) = @_;

	my $of = $spec->{of};
	croak "count munger$where requires a non-empty 'of' string"
		unless defined $of && length $of;

	my $plus = defined $spec->{plus} ? $spec->{plus} : 0;
	croak "count munger$where: 'plus' must be numeric"
		unless looks_like_number($plus);

	# index() beats a global regex match here: no pattern engine, and no
	# per-call list of matches just to count them. Advancing by length($of)
	# keeps the non-overlapping semantics m//g had.
	my $oflen = length $of;
	return sub {
		my ($v) = @_;
		my $s   = defined $v ? "$v" : '';
		my $n   = 0;
		my $p   = 0;
		while ( ( $p = index( $s, $of, $p ) ) >= 0 ) {
			$n++;
			$p += $oflen;
		}
		return $n + $plus;
	}; ## end sub
} ## end sub _build_count

=head2 bucket

    { munger => 'bucket', bounds => [ 1024, 49152 ] }   # dest_port classes

Map a number to a bucket index by ascending C<bounds>: the result is how many
bounds the value is greater than or equal to. With C<< bounds => [1024, 49152] >>
a value under C<1024> is C<0> (well-known), C<1024>-C<49151> is C<1> (registered),
and C<49152>+ is C<2> (ephemeral) -- the classic port classing, where the literal
port number is meaningless to a threshold split but the I<class> is a real
signal. C<bounds> must be strictly ascending; N bounds yield indices C<0>..C<N>.

This generalises the C<*_enum> status-class mungers, which are the special case
of bucketing a reply code by its leading digit.

=cut

sub _build_bucket {
	my ( $spec, $where ) = @_;

	my $bounds = $spec->{bounds};
	croak "bucket munger$where requires a non-empty 'bounds' arrayref"
		unless ref $bounds eq 'ARRAY' && @$bounds;

	my @b = @$bounds;
	for my $i ( 0 .. $#b ) {
		croak "bucket munger$where: bound[$i] ('" . ( defined $b[$i] ? $b[$i] : 'undef' ) . "') is not numeric"
			unless looks_like_number( $b[$i] );
		croak "bucket munger$where: 'bounds' must be strictly ascending"
			if $i && $b[$i] <= $b[ $i - 1 ];
	}

	return sub {
		my ($v) = @_;
		croak "bucket munger$where: '" . ( defined $v ? $v : 'undef' ) . "' is not numeric"
			unless looks_like_number($v);
		my $idx = 0;
		for my $bound (@b) {
			last if $v < $bound;
			$idx++;
		}
		return $idx;
	}; ## end sub
} ## end sub _build_bucket

=head2 scale

    { munger => 'scale', min => 0, max => 1000, clamp => 1 }

Min-max normalisation: C<(v - min) / (max - min)>, mapping C<[min, max]> onto
C<[0, 1]>. C<min> and C<max> must differ. With a true C<clamp>, results are
pinned into C<[0, 1]> so out-of-range inputs cannot escape the unit interval.

=cut

sub _build_scale {
	my ( $spec, $where ) = @_;

	my ( $min, $max ) = @{$spec}{qw(min max)};
	croak "scale munger$where requires numeric 'min' and 'max'"
		unless looks_like_number($min) && looks_like_number($max);

	my $range = $max - $min;
	croak "scale munger$where: 'min' and 'max' must differ"
		if $range == 0;

	my $clamp = $spec->{clamp} ? 1 : 0;
	return sub {
		my ($v) = @_;
		croak "scale munger$where: '" . ( defined $v ? $v : 'undef' ) . "' is not numeric"
			unless looks_like_number($v);
		my $s = ( $v - $min ) / $range;
		if ($clamp) { $s = 0 if $s < 0; $s = 1 if $s > 1; }
		return $s;
	};
} ## end sub _build_scale

=head2 zscore

    { munger => 'zscore', mean => 42.0, std => 7.5 }

Standardise: C<(v - mean) / std>. C<std> must be non-zero. The C<mean>/C<std>
are supplied (this module does not learn them) so munging stays stateless and a
row can be munged in isolation.

=cut

sub _build_zscore {
	my ( $spec, $where ) = @_;

	my ( $mean, $std ) = @{$spec}{qw(mean std)};
	croak "zscore munger$where requires numeric 'mean' and 'std'"
		unless looks_like_number($mean) && looks_like_number($std);
	croak "zscore munger$where: 'std' must be non-zero"
		if $std == 0;

	return sub {
		my ($v) = @_;
		croak "zscore munger$where: '" . ( defined $v ? $v : 'undef' ) . "' is not numeric"
			unless looks_like_number($v);
		return ( $v - $mean ) / $std;
	};
} ## end sub _build_zscore

=head2 log

    { munger => 'log' }                 # natural log
    { munger => 'log', offset => 1 }    # log1p-style, so 0 is allowed
    { munger => 'log', base => 10, offset => 1 }

Logarithm of C<v + offset>. Heavy-tailed counts (bytes, durations) compress well
under a log, which keeps a few huge values from dominating the forest. C<offset>
(default C<0>) shifts the input so zeros/small values are representable; the
shifted value must be strictly positive or the input croaks. C<base> defaults to
natural log.

=cut

sub _build_log {
	my ( $spec, $where ) = @_;

	my $offset = exists $spec->{offset} ? $spec->{offset} : 0;
	croak "log munger$where: 'offset' must be numeric"
		unless looks_like_number($offset);

	my $ln_base;
	if ( defined $spec->{base} ) {
		croak "log munger$where: 'base' must be numeric and > 0 and != 1"
			unless looks_like_number( $spec->{base} )
			&& $spec->{base} > 0
			&& $spec->{base} != 1;
		$ln_base = log( $spec->{base} );
	}

	return sub {
		my ($v) = @_;
		croak "log munger$where: '" . ( defined $v ? $v : 'undef' ) . "' is not numeric"
			unless looks_like_number($v);
		my $x = $v + $offset;
		croak "log munger$where: value+offset must be > 0 (got $x)"
			unless $x > 0;
		my $r = log($x);
		$r /= $ln_base if defined $ln_base;
		return $r;
	}; ## end sub
} ## end sub _build_log

=head2 clamp

    { munger => 'clamp', min => 0 }
    { munger => 'clamp', min => 0, max => 65535 }

Pass the number through, pinned into C<[min, max]>. Either bound may be omitted
to clamp on one side only. Unlike C<scale> this does not rescale; it only caps
outliers before they reach the model.

=cut

sub _build_clamp {
	my ( $spec, $where ) = @_;

	my ( $min, $max ) = @{$spec}{qw(min max)};
	my $have_min = defined $min;
	my $have_max = defined $max;
	croak "clamp munger$where needs at least one of 'min' or 'max'"
		unless $have_min || $have_max;
	croak "clamp munger$where: 'min' must be numeric"
		if $have_min && !looks_like_number($min);
	croak "clamp munger$where: 'max' must be numeric"
		if $have_max && !looks_like_number($max);
	croak "clamp munger$where: 'min' must be <= 'max'"
		if $have_min && $have_max && $min > $max;

	return sub {
		my ($v) = @_;
		croak "clamp munger$where: '" . ( defined $v ? $v : 'undef' ) . "' is not numeric"
			unless looks_like_number($v);
		$v = $min if $have_min && $v < $min;
		$v = $max if $have_max && $v > $max;
		return $v;
	};
} ## end sub _build_clamp

=head2 datetime

    { munger => 'datetime', format => '%Y-%m-%dT%H:%M:%S', part => 'epoch' }
    { munger => 'datetime', format => '%Y-%m-%d %H:%M:%S', part => 'hour' }

Parse a formatted timestamp with L<Time::Piece> (C<strptime>, so C<format> is a
standard strptime pattern) and extract one numeric C<part>:

=over 4

=item * C<epoch> (default) - seconds since the epoch.

=item * C<year>, C<mon> (1-12), C<mday> (1-31), C<hour>, C<min>, C<sec>.

=item * C<wday> - day of week, C<0>=Sunday .. C<6>=Saturday.

=item * C<yday> - day of year, C<0>-based.

=item * C<frac_day> - time of day as a fraction in C<[0, 1)>, i.e.
C<(hour*3600 + min*60 + sec) / 86400>. Handy as a cyclic-ish time-of-day feature.

=item * C<frac_week> - position within the week as a fraction in C<[0, 1)>, the
week starting Sunday to match C<wday>: C<(wday*86400 + hour*3600 + min*60 + sec)
/ 604800>. Like C<frac_day> but cycling over a week, so a weekly rhythm (weekend
vs. weekday, or a Monday-morning batch) shows up as a feature.

=item * C<sin_day> / C<cos_day>, C<sin_week> / C<cos_week> - the C<frac_*> value
mapped onto a circle, C<sin(2*pi*frac)> and C<cos(2*pi*frac)>. Prefer these over
the raw C<frac_*> when feeding the forest: a plain fraction has a false seam at
the wrap (23:59 and 00:00 sit at opposite ends, 1 vs 0, though they are a minute
apart), whereas the sin/cos pair is continuous across midnight/Sunday. Store
I<both> of a pair in two columns so the position is unambiguous.

=back

Time features often carry the anomaly (a job that normally runs at 03:00
suddenly firing at noon, or a weekday task firing on a Sunday), which is why this
is a first-class munger.

B<Multi-output form.> A cyclic pair belongs together -- C<sin> alone collides
(C<sin> is symmetric about its peak, so two different times map to one value) and
the forest then treats distinct times as identical. To emit a pair atomically,
give C<parts> (plural) and route them to two columns with C<into> (see
L</compile>):

    "time_of_week": {
        "munger": "datetime", "from": "timestamp",
        "format": "%Y-%m-%dT%H:%M:%S",
        "parts":  [ "sin_week", "cos_week" ],
        "into":   [ "time_sin", "time_cos" ]
    }

The timestamp is parsed once and both columns are filled together, so they can
never drift apart or be half-configured. C<parts> and C<into> must be the same
length. (Using C<parts> without C<into>, or C<part> with C<into>, is an error.)

B<Performance.> Two transparent accelerations, both value-identical to the plain
path: a one-slot memo returns the previous result when the same stamp string
repeats (the common case in bursty event streams); and when the format is built
from only the six numeric codes C<%Y %m %d %H %M %S> (once each, e.g.
C<%Y-%m-%dT%H:%M:%S>), parsing skips C<strptime> for a compiled regex plus
integer date math, falling back to C<strptime> for any value the regex does not
match. Like C<strptime> without a zone code, stamps are treated as UTC.

=cut

# Fraction (in [0,1)) of the way through the day / week, shared by the frac_*
# parts and their sin/cos cyclic encodings.
sub _frac_day {
	my $t = shift;
	return ( $t->hour * 3600 + $t->min * 60 + $t->sec ) / 86400;
}

sub _frac_week {
	my $t = shift;
	return ( $t->day_of_week * 86400 + $t->hour * 3600 + $t->min * 60 + $t->sec ) / 604800;
}

my $TWO_PI = 2 * atan2( 0, -1 );    # atan2(0,-1) == pi, core-only, no POSIX

# part name => how to pull it off a Time::Piece object.
my %DATETIME_PART = (
	epoch     => sub { $_[0]->epoch },
	year      => sub { $_[0]->year },
	mon       => sub { $_[0]->mon },
	mday      => sub { $_[0]->mday },
	hour      => sub { $_[0]->hour },
	min       => sub { $_[0]->min },
	sec       => sub { $_[0]->sec },
	wday      => sub { $_[0]->day_of_week },
	yday      => sub { $_[0]->yday },
	frac_day  => \&_frac_day,
	frac_week => \&_frac_week,
	sin_day   => sub { sin( $TWO_PI * _frac_day( $_[0] ) ) },
	cos_day   => sub { cos( $TWO_PI * _frac_day( $_[0] ) ) },
	sin_week  => sub { sin( $TWO_PI * _frac_week( $_[0] ) ) },
	cos_week  => sub { cos( $TWO_PI * _frac_week( $_[0] ) ) },
);

# ---- fast fixed-format engine ----------------------------------------------
#
# Time::Piece->strptime costs microseconds per call. When the format is built
# from only the six all-numeric codes below (once each, e.g. the ubiquitous
# '%Y-%m-%dT%H:%M:%S'), we can compile it to a capture regex and derive every
# part with integer math instead -- several times faster, and bit-identical:
# both paths treat the stamp as UTC (strptime with no zone does the same).
# Anything fancier (%b, %z, %j, ...) stays on strptime.

# strptime code => [ field name, capture pattern ].
my %FAST_CODE = (
	Y => [ 'year', '[0-9]{4}' ],
	m => [ 'mon',  '[0-9]{2}' ],
	d => [ 'mday', '[0-9]{2}' ],
	H => [ 'hour', '[0-9]{2}' ],
	M => [ 'min',  '[0-9]{2}' ],
	S => [ 'sec',  '[0-9]{2}' ],
);

# Compile a strptime format into { re, idx } for the arithmetic fast path --
# idx maps field name (year/mon/...) to its capture position -- or return undef
# when the format is not fast-eligible. All six codes must appear exactly once
# so every part can be derived.
sub _compile_fast_format {
	my ($format) = @_;
	my $re       = '';
	my %idx      = ();
	my $n        = 0;
	my $rest     = $format;
	while ( length $rest ) {
		if ( $rest =~ s/\A%(.)//s ) {
			my $f = $FAST_CODE{$1} or return undef;
			return undef if exists $idx{ $f->[0] };
			$idx{ $f->[0] } = $n++;
			$re .= '(' . $f->[1] . ')';
		} elsif ( $rest =~ s/\A([^%]+)//s ) {
			$re .= quotemeta($1);
		} else {
			return undef;    # lone trailing '%' -- not fast-eligible
		}
	} ## end while ( length $rest )
	return undef unless keys %idx == 6;
	return { re => qr/\A$re\z/, idx => \%idx };
} ## end sub _compile_fast_format

# Days since 1970-01-01 for a proleptic-Gregorian date (Howard Hinnant's
# days-from-civil). Pure integer math; Perl's % already yields a non-negative
# result for the wday derivation even on pre-1970 dates.
sub _days_from_civil {
	my ( $y, $m, $d ) = @_;
	$y -= $m <= 2;
	my $era = int( ( $y >= 0 ? $y : $y - 399 ) / 400 );
	my $yoe = $y - $era * 400;
	my $doy = int( ( 153 * ( $m + ( $m > 2 ? -3 : 9 ) ) + 2 ) / 5 ) + $d - 1;
	my $doe = $yoe * 365 + int( $yoe / 4 ) - int( $yoe / 100 ) + $doy;
	return $era * 146097 + $doe - 719468;
}

# part name => factory(\%idx) => getter(\@captures). Mirrors %DATETIME_PART;
# t/mungers-datetime-fast.t asserts the two stay value-identical. The factories
# bake the capture positions in at build time so a per-row getter indexes the
# raw capture array directly -- no intermediate hash per row, which is where
# the fast path's time would otherwise go. Slot 6 of the capture array caches
# days-from-civil so a multi-part (sin/cos) extraction computes it once.
my %DATETIME_PART_FAST;
{
	my $days_of = sub {
		my ( $iy, $im, $id ) = @{ $_[0] }{qw(year mon mday)};
		return sub {
			my $c = shift;
			return defined $c->[6]
				? $c->[6]
				: ( $c->[6] = _days_from_civil( $c->[$iy], $c->[$im], $c->[$id] ) );
		};
	};
	my $sod_of = sub {
		my ( $ih, $in, $is ) = @{ $_[0] }{qw(hour min sec)};
		return sub { $_[0][$ih] * 3600 + $_[0][$in] * 60 + $_[0][$is] };
	};
	my $frac_day_of = sub {
		my $sod = $sod_of->( $_[0] );
		return sub { $sod->( $_[0] ) / 86400 };
	};
	my $frac_week_of = sub {
		my ( $days, $sod ) = ( $days_of->( $_[0] ), $sod_of->( $_[0] ) );
		return sub {
			my $c = shift;
			return ( ( ( $days->($c) + 4 ) % 7 ) * 86400 + $sod->($c) ) / 604800;
		};
	};
	my $field_of = sub {
		my ($name) = @_;
		return sub {
			my $i = $_[0]{$name};
			return sub { $_[0][$i] + 0 }
		};
	};

	%DATETIME_PART_FAST = (
		year  => $field_of->('year'),
		mon   => $field_of->('mon'),
		mday  => $field_of->('mday'),
		hour  => $field_of->('hour'),
		min   => $field_of->('min'),
		sec   => $field_of->('sec'),
		epoch => sub {
			my ( $days, $sod ) = ( $days_of->( $_[0] ), $sod_of->( $_[0] ) );
			return sub { $days->( $_[0] ) * 86400 + $sod->( $_[0] ) };
		},
		wday => sub {    # epoch day 0 = Thursday = 4
			my $days = $days_of->( $_[0] );
			return sub { ( $days->( $_[0] ) + 4 ) % 7 };
		},
		yday => sub {
			my ($idx) = @_;
			my $days  = $days_of->($idx);
			my $iy    = $idx->{year};
			return sub {
				my $c = shift;
				return $days->($c) - _days_from_civil( $c->[$iy], 1, 1 );
			};
		},
		frac_day  => $frac_day_of,
		frac_week => $frac_week_of,
		sin_day   => sub {
			my $f = $frac_day_of->( $_[0] );
			return sub { sin( $TWO_PI * $f->( $_[0] ) ) };
		},
		cos_day => sub {
			my $f = $frac_day_of->( $_[0] );
			return sub { cos( $TWO_PI * $f->( $_[0] ) ) };
		},
		sin_week => sub {
			my $f = $frac_week_of->( $_[0] );
			return sub { sin( $TWO_PI * $f->( $_[0] ) ) };
		},
		cos_week => sub {
			my $f = $frac_week_of->( $_[0] );
			return sub { cos( $TWO_PI * $f->( $_[0] ) ) };
		},
	);
}

# Build the parse/getter machinery for a datetime spec: ($parse, $getter_for),
# where $parse->($v) yields whatever the getters consume (a capture array on
# the fast path, a Time::Piece object otherwise) and $getter_for->($part)
# resolves a part name to a getter closure, croaking on an unknown part.
# Shared by the scalar and multi-output builders so the choice is made in
# exactly one place.
sub _datetime_engine {
	my ( $format, $where ) = @_;
	croak "datetime munger$where requires a strptime 'format'"
		unless defined $format && length $format;

	# Time::Piece is not core on the ancient perls Makefile.PL still nominally
	# supports, so only pull it in for the one munger that needs it. The fast
	# path keeps it loaded too: a regex mismatch falls back to strptime so the
	# fast path can never reject a value the slow path would have accepted.
	require Time::Piece;

	my $strptime = sub {
		my ($v) = @_;
		my $t = eval { Time::Piece->strptime( $v, $format ) };
		croak "datetime munger$where: cannot parse '$v' with '$format'"
			unless $t;
		return $t;
	};

	if ( my $fast = _compile_fast_format($format) ) {
		my ( $re, $idx ) = @{$fast}{qw(re idx)};
		my $parse = sub {
			my ($v) = @_;
			croak "datetime munger$where: undefined value" unless defined $v;
			if ( my @c = $v =~ $re ) { return \@c }
			# Regex mismatch: let strptime be the judge, rebuilding the capture
			# array in this format's capture order.
			my $t = $strptime->($v);
			my @c;
			@c[ @{$idx}{qw(year mon mday hour min sec)} ]
				= ( $t->year, $t->mon, $t->mday, $t->hour, $t->min, $t->sec );
			return \@c;
		}; ## end $parse = sub
		my $getter_for = sub {
			my ($part) = @_;
			my $factory = $DATETIME_PART_FAST{$part}
				or croak "datetime munger$where: unknown part '$part' (known: "
				. join( ', ', sort keys %DATETIME_PART ) . ')';
			return $factory->($idx);
		};
		return ( $parse, $getter_for );
	} ## end if ( my $fast = _compile_fast_format($format...))

	my $parse = sub {
		my ($v) = @_;
		croak "datetime munger$where: undefined value" unless defined $v;
		return $strptime->($v);
	};
	my $getter_for = sub {
		my ($part) = @_;
		my $get = $DATETIME_PART{$part}
			or croak "datetime munger$where: unknown part '$part' (known: "
			. join( ', ', sort keys %DATETIME_PART ) . ')';
		return $get;
	};
	return ( $parse, $getter_for );
} ## end sub _datetime_engine

sub _build_datetime {
	my ( $spec, $where ) = @_;

	croak "datetime munger$where: 'parts' is for the multi-output form (needs "
		. "'into'); use 'part' for a single column"
		if defined $spec->{parts};

	my ( $parse, $getter_for ) = _datetime_engine( $spec->{format}, $where );
	my $get = $getter_for->( defined $spec->{part} ? $spec->{part} : 'epoch' );

	# One-slot memo: event streams repeat the same stamp within a second
	# constantly, so the previous input usually answers the next call with a
	# string compare. A parse failure leaves the memo untouched.
	my ( $memo_in, $memo_out );
	return sub {
		my ($v) = @_;
		return $memo_out
			if defined $v && defined $memo_in && $v eq $memo_in;
		my $out = $get->( $parse->($v) );
		( $memo_in, $memo_out ) = ( $v, $out );
		return $out;
	};
} ## end sub _build_datetime

# Multi-output datetime: parse once, emit one number per part, in 'parts' order
# (which lines up with the caller's 'into'). Returns ($list_returning_code,
# $arity) so compile() can check the arity against 'into'. Memoized like the
# scalar form, caching the whole output list per input stamp.
sub _build_datetime_multi {
	my ( $spec, $where ) = @_;

	my $parts = $spec->{parts};
	croak "datetime munger$where: 'parts' must be a non-empty arrayref"
		unless ref $parts eq 'ARRAY' && @$parts;

	my ( $parse, $getter_for ) = _datetime_engine( $spec->{format}, $where );
	my @get = map { $getter_for->($_) } @$parts;

	my ( $memo_in, @memo_out );
	my $code = sub {
		my ($v) = @_;
		return @memo_out
			if defined $v && defined $memo_in && $v eq $memo_in;
		my $t   = $parse->($v);
		my @out = map { $_->($t) } @get;
		( $memo_in, @memo_out ) = ( $v, @out );
		return @out;
	};
	return ( $code, scalar @$parts );
} ## end sub _build_datetime_multi

=head2 hash

    { munger => 'hash', buckets => 1024 }
    { munger => 'hash', buckets => 1024, seed => 7 }
    { munger => 'hash' }                          # raw 32-bit FNV-1a value

Feature hashing for high-cardinality categoricals you do not want to (or cannot)
enumerate with C<enum>. The input is stringified and run through 32-bit FNV-1a;
with C<buckets> the result is reduced modulo that many buckets (C<[0, buckets)>),
otherwise the full 32-bit hash is returned. An optional C<seed> lets you decorrelate
two hashed columns.

This is the one munger that is XS-accelerated: FNV-1a is a per-byte loop with a
32-bit modular multiply, which is slow in pure Perl and (on a 32-bit perl) fussy
to get exactly right. C<$Algorithm::Classifier::IsolationForest::Zorita::Mungers::HAVE_XS>
reports whether the compiled path is in use; a pure-Perl fallback (exact on a
64-bit perl) is used otherwise, and both produce identical values.

=cut

sub _build_hash {
	my ( $spec, $where ) = @_;

	my $buckets = $spec->{buckets};
	croak "hash munger$where: 'buckets' must be a positive integer"
		if defined $buckets && $buckets !~ /\A[1-9][0-9]*\z/;

	my $seed = defined $spec->{seed} ? $spec->{seed} : 0;
	croak "hash munger$where: 'seed' must be a non-negative integer"
		if $seed !~ /\A[0-9]+\z/;

	my $fn = $HAVE_XS ? \&_fnv1a_xs : \&_fnv1a_pp;
	return sub {
		my ($v) = @_;
		my $h = $fn->( defined $v ? "$v" : '', $seed );
		return defined $buckets ? $h % $buckets : $h;
	};
} ## end sub _build_hash

# Pure-Perl 32-bit FNV-1a, used only when the XS did not build. On a 64-bit
# perl the intermediate h*16777619 (< 2**57) stays an exact integer, so the
# masked result matches the C version bit for bit. The string is always
# utf8-encoded first so a value hashes as its UTF-8 bytes no matter the internal
# flag -- the same well-defined bytes SvPVutf8 hands the XS.
sub _fnv1a_pp {
	my ( $str, $seed ) = @_;
	utf8::encode($str);
	my $h = ( 2166136261 ^ ( $seed & 0xFFFFFFFF ) ) & 0xFFFFFFFF;
	for my $c ( unpack 'C*', $str ) {
		$h ^= $c;
		$h = ( $h * 16777619 ) & 0xFFFFFFFF;
	}
	return $h;
} ## end sub _fnv1a_pp

=head2 eps

    { munger => 'eps', prefix => 'http-req:', from => 'src_ip' }
    { munger => 'eps', prefix => 'dns-nxd:',  from => 'src_ip',
      read => 'rate', mark => 0 }
    # multi-output: one daemon round trip fills several columns
    { munger => 'eps', prefix => 'http-req:', from => 'src_ip',
      parts => [ 'rate', 'count' ], into => [ 'req_rate', 'req_count' ] }

Per-entity sliding-window event rates via the C<iqbi-damiq> daemon shipped with
L<Algorithm::EventsPerSecond> (see
L<Algorithm::EventsPerSecond::Sukkal>). The input value becomes a meter B<key>
(after C<prefix> is prepended); by default the munger B<marks> one event against
that key and returns the key's current events-per-second, using the daemon's
C<MARKRATE> command -- mark and query in a single command with a single reply.
This is the munger behind rate columns like a per-source request rate: every
event marks its source's meter and stores the rate the meter now reads.

Unlike every other munger this one consults external state -- but the state
lives in the daemon, not here, so the munger itself remains a stateless client
and rows stay reproducible I<given> the daemon. Because the daemon is shared,
multiple writer processes marking the same keys see one B<global> rate, which an
in-process meter could never give.

Spec keys:

=over 4

=item * C<socket> - unix socket path of the daemon. Defaults to
C<$Algorithm::Classifier::IsolationForest::Zorita::Mungers::EPS_SOCKET>
(C</var/run/iqbi-damiq.sock>).

=item * C<prefix> - string prepended to the input to form the key, namespacing
this column's meters (two columns keyed on the same field need different
prefixes or they share meters). No whitespace/control characters. Default C<''>.

=item * C<mark> - whether to mark the key (default C<1>). Marking rides
C<MARKRATE>: with C<< read => 'rate' >> that one command is the whole exchange;
with C<count>/C<total> the read is pipelined after it (the C<MARKRATE> rate
reply is discarded), so a marking failure still comes back as an ordinary
first reply. With C<< mark => 0 >> the munger only reads, for columns whose
marking is done elsewhere -- e.g. an NXDOMAIN rate is I<marked> by the pipeline
only on NXDOMAIN responses but I<read> on every row.

=item * C<read> - what to read: C<rate> (events/sec over the daemon's window,
default), C<count> (events inside the window), or C<total> (lifetime).

=item * C<parts> + C<into> - multi-output form (see L</compile>): read several
of C<rate>/C<count>/C<total> for the one key in a single round trip, filling one
column each. When marking, the C<MARKRATE> reply itself serves the first C<rate>
part, so C<< parts => ['rate', 'count'] >> costs exactly two commands.

=item * C<on_error> - C<'die'> (default) croaks the write when the daemon is
unreachable or replies C<ERR>; a number is returned instead as a quiet fallback.
Note C<0> is indistinguishable from a genuinely idle key, so quiet fallback
biases the column -- loud is the default on purpose.

=item * C<timeout> - per-operation socket timeout in seconds (default 5,
best-effort via C<SO_RCVTIMEO>/C<SO_SNDTIMEO>), so a wedged daemon cannot hang a
writer forever.

=back

Semantics worth knowing: a marked read B<includes the event just marked>; keys
have whitespace/control bytes replaced with C<_> to satisfy the daemon's key
rules; connections are made lazily on first use and kept open (reconnecting
transparently after a fork or an error), so compiling a plan -- including the
eager validation in C<write_info> -- needs no running daemon. Each eps column
costs one unix-socket round trip per row; the multi-output form exists so
rate+count of the same key costs one round trip, not two.

=cut

# Default socket path of the iqbi-damiq daemon.
our $EPS_SOCKET = '/var/run/iqbi-damiq.sock';

# Persistent daemon connections, keyed by socket path, shared by every eps
# munger in the process. Entries record the pid that opened them so a forked
# writer transparently reopens instead of sharing a socket with its parent.
# Connections are made lazily on first use -- never at munger build time, so a
# plan can compile (eager validation) with no daemon running.
my %EPS_CONN;

sub _eps_conn {
	my ( $path, $timeout ) = @_;
	my $c = $EPS_CONN{$path};
	return $c->{fh} if $c && $c->{pid} == $$;

	require Socket;
	require IO::Socket::UNIX;
	my $fh = IO::Socket::UNIX->new(
		Type => Socket::SOCK_STREAM(),
		Peer => $path,
	) or die "cannot connect to iqbi-damiq at $path: $!\n";

	# Best-effort read/write timeouts so a wedged daemon cannot hang a writer.
	eval {
		my $tv = pack( 'l!l!', $timeout, 0 );
		setsockopt( $fh, Socket::SOL_SOCKET(), Socket::SO_RCVTIMEO(), $tv );
		setsockopt( $fh, Socket::SOL_SOCKET(), Socket::SO_SNDTIMEO(), $tv );
	};

	$EPS_CONN{$path} = { fh => $fh, pid => $$ };
	return $fh;
} ## end sub _eps_conn

# One pipelined transaction: send $cmd (possibly several lines) and read
# $nreplies "OK n" lines, one per command sent. The munger only ever sends
# commands that reply exactly once -- MARKRATE (which marks AND returns the
# rate in one go), RATE, COUNT, TOTAL; never a bare MARK, whose reply-only-on-
# error behavior would let a failure desynchronize the reply stream. Dies on
# ERR, EOF, or timeout; the caller still drops the cached connection on error
# as belt and braces.
sub _eps_txn {
	my ( $path, $timeout, $cmd, $nreplies ) = @_;
	my $fh = _eps_conn( $path, $timeout );
	print {$fh} $cmd or die "write to iqbi-damiq failed: $!\n";
	my @out;
	for ( 1 .. $nreplies ) {
		my $reply = <$fh>;
		die "iqbi-damiq closed the connection (or timed out)\n"
			unless defined $reply;
		$reply =~ /\AOK (\S+)/
			or die "iqbi-damiq replied: $reply";
		push @out, $1 + 0;
	}
	return @out;
} ## end sub _eps_txn

# Validate the spec keys shared by the scalar and multi-output eps builders.
sub _eps_spec {
	my ( $spec, $where ) = @_;

	my $socket = defined $spec->{socket} ? $spec->{socket} : $EPS_SOCKET;
	croak "eps munger$where: 'socket' must be a non-empty path"
		unless length $socket;

	my $prefix = defined $spec->{prefix} ? $spec->{prefix} : '';
	croak "eps munger$where: 'prefix' may not contain whitespace or control " . 'characters'
		if $prefix =~ /[\s[:cntrl:]]/;

	my $mark = exists $spec->{mark} ? ( $spec->{mark} ? 1 : 0 ) : 1;

	my $timeout = defined $spec->{timeout} ? $spec->{timeout} : 5;
	croak "eps munger$where: 'timeout' must be a positive number"
		unless looks_like_number($timeout) && $timeout > 0;

	my $on_error = defined $spec->{on_error} ? $spec->{on_error} : 'die';
	croak "eps munger$where: 'on_error' must be 'die' or a number"
		unless $on_error eq 'die' || looks_like_number($on_error);

	return ( $socket, $prefix, $mark, $timeout, $on_error );
} ## end sub _eps_spec

my %EPS_READ = map { $_ => 1 } qw(rate count total);

sub _build_eps {
	my ( $spec, $where ) = @_;

	croak "eps munger$where: 'parts' is for the multi-output form (needs " . "'into'); use 'read' for a single column"
		if defined $spec->{parts};

	my ( $socket, $prefix, $mark, $timeout, $on_error ) = _eps_spec( $spec, $where );

	my $read = defined $spec->{read} ? $spec->{read} : 'rate';
	croak "eps munger$where: unknown read '$read' (known: " . join( ', ', sort keys %EPS_READ ) . ')'
		unless $EPS_READ{$read};

	# Command plan, fixed at build time. The common case -- mark and read the
	# rate -- is the daemon's single MARKRATE command. mark+count/total rides
	# MARKRATE too (its rate reply is discarded) so marking failures come back
	# as an ordinary first reply instead of a bare MARK's error-only surprise.
	my @cmds
		= !$mark          ? ( uc $read )
		: $read eq 'rate' ? ('MARKRATE')
		:                   ( 'MARKRATE', uc $read );

	return sub {
		my ($v) = @_;
		my $key = $prefix . ( defined $v ? "$v" : '' );
		$key =~ s/[\s[:cntrl:]]/_/g;
		my @replies = eval {
			die "empty key\n" unless length $key;
			_eps_txn( $socket, $timeout, join( '', map { "$_ $key\n" } @cmds ), scalar @cmds );
		};
		if ($@) {
			my $err = $@;
			delete $EPS_CONN{$socket};    # reconnect fresh next call
			croak "eps munger$where: $err" if $on_error eq 'die';
			return $on_error + 0;
		}
		return $replies[-1];              # the requested read is always the last reply
	}; ## end sub
} ## end sub _build_eps

# Multi-output eps: one key, several reads (rate/count/total), one round trip.
# Returns ($list_returning_code, $arity) for compile()'s 'into' check.
sub _build_eps_multi {
	my ( $spec, $where ) = @_;

	my $parts = $spec->{parts};
	croak "eps munger$where: 'parts' must be a non-empty arrayref"
		unless ref $parts eq 'ARRAY' && @$parts;
	for my $p (@$parts) {
		croak "eps munger$where: unknown part '"
			. ( defined $p ? $p : 'undef' )
			. "' (known: "
			. join( ', ', sort keys %EPS_READ ) . ')'
			unless defined $p && $EPS_READ{$p};
	}

	my ( $socket, $prefix, $mark, $timeout, $on_error ) = _eps_spec( $spec, $where );

	# Command plan, fixed at build time. When marking, the mark is a MARKRATE
	# whose own reply serves the first 'rate' part for free; the remaining
	# parts become one read command each. @take maps each part to the reply
	# index that answers it, so the output stays in 'parts' order.
	my ( @cmds, @take );
	my $rate_served = 0;
	push @cmds, 'MARKRATE' if $mark;
	for my $i ( 0 .. $#$parts ) {
		if ( $mark && !$rate_served && $parts->[$i] eq 'rate' ) {
			$take[$i] = 0;       # MARKRATE's reply is the rate
			$rate_served = 1;
			next;
		}
		push @cmds, uc $parts->[$i];
		$take[$i] = $#cmds;
	}
	my $n        = @$parts;
	my $nreplies = @cmds;

	my $code = sub {
		my ($v) = @_;
		my $key = $prefix . ( defined $v ? "$v" : '' );
		$key =~ s/[\s[:cntrl:]]/_/g;
		my @replies = eval {
			die "empty key\n" unless length $key;
			_eps_txn( $socket, $timeout, join( '', map { "$_ $key\n" } @cmds ), $nreplies );
		};
		if ($@) {
			my $err = $@;
			delete $EPS_CONN{$socket};
			croak "eps munger$where: $err" if $on_error eq 'die';
			return ( $on_error + 0 ) x $n;
		}
		return @replies[@take];
	}; ## end $code = sub
	return ( $code, $n );
} ## end sub _build_eps_multi

# A compiled munging plan for one set, produced by Mungers->compile. It turns an
# input record into a fully-numeric row in tags order; the Writer then only has
# to validate and append. Kept in its own package so the assembly logic is
# testable without a Writer or the filesystem.
package Algorithm::Classifier::IsolationForest::Zorita::Mungers::Plan;

use strict;
use warnings;
use Carp qw(croak);

sub tags { return $_[0]->{tags} }

# Assemble a row from a name-keyed record. Scalar/raw columns read their own tag
# (or the munger's 'from'); expanding mungers read one source and fill several
# columns. This is the only form that supports expanders.
sub apply_named {
	my ( $self, $hash ) = @_;
	croak 'apply_named requires a hashref' unless ref $hash eq 'HASH';

	my @row;
	for my $s ( @{ $self->{scalar} } ) {
		croak "missing value for '$s->{from}'"
			unless exists $hash->{ $s->{from} };
		my $v = $hash->{ $s->{from} };
		$row[ $self->{pos}{ $s->{tag} } ] = $s->{code} ? $s->{code}->($v) : $v;
	}

	for my $e ( @{ $self->{expand} } ) {
		croak "missing value for '$e->{from}'"
			unless exists $hash->{ $e->{from} };
		my @vals = $e->{code}->( $hash->{ $e->{from} } );
		croak "expanding munger for [@{ $e->{into} }] returned "
			. scalar(@vals)
			. ' value(s), expected '
			. scalar( @{ $e->{into} } )
			unless @vals == @{ $e->{into} };
		for my $i ( 0 .. $#{ $e->{into} } ) {
			$row[ $self->{pos}{ $e->{into}[$i] } ] = $vals[$i];
		}
	} ## end for my $e ( @{ $self->{expand} } )

	return \@row;
} ## end sub apply_named

# Assemble a row from an already-ordered positional row, applying scalar mungers
# in place. Expanding mungers cannot be expressed positionally (there is no named
# source), so a set that has any is a hard error here -- use apply_named.
sub apply_positional {
	my ( $self, $row ) = @_;
	croak 'apply_positional requires an arrayref row' unless ref $row eq 'ARRAY';
	croak 'positional write is unsupported for a set with expanding mungers; ' . 'use write_named'
		if @{ $self->{expand} };
	croak 'row has ' . scalar(@$row) . ' fields but info.json declares ' . scalar( @{ $self->{tags} } )
		unless @$row == @{ $self->{tags} };

	my @out = @$row;
	for my $s ( @{ $self->{scalar} } ) {
		next unless $s->{code};
		my $i = $self->{pos}{ $s->{tag} };
		$out[$i] = $s->{code}->( $out[$i] );
	}
	return \@out;
} ## end sub apply_positional

=head1 SEE ALSO

L<Algorithm::Classifier::IsolationForest::Zorita>,
L<Algorithm::Classifier::IsolationForest::Zorita::Writer>

=head1 AUTHOR

Zane C. Bowers-Hadley, C<< <vvelox at vvelox.net> >>

=head1 LICENSE AND COPYRIGHT

This software is Copyright (c) 2026 by Zane C. Bowers-Hadley.

This is free software, licensed under:

  The GNU Lesser General Public License, Version 2.1, February 1999

=cut

1;    # End of Algorithm::Classifier::IsolationForest::Zorita::Mungers
