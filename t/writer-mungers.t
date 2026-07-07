#!perl
# End-to-end: a set whose info.json declares mungers, including a multi-output
# datetime sin/cos expander. Confirms the Writer munges raw input into the
# numeric CSV, honors the header, and enforces the positional/expander rule.
use 5.006;
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);

use Algorithm::Classifier::IsolationForest::Zorita;
use Algorithm::Classifier::IsolationForest::Zorita::Writer;

my $WRITER_CLASS = 'Algorithm::Classifier::IsolationForest::Zorita::Writer';
my $FMT          = '%Y-%m-%dT%H:%M:%S';

# tags: two cyclic time columns (filled by one 'timestamp'), a log'd byte count,
# an enum'd method, and a raw status.
my @TAGS = qw(time_sin time_cos bytes method status);

my %MUNGERS = (
	time_of_week => {
		munger => 'datetime',
		from   => 'timestamp',
		format => $FMT,
		parts  => [qw(sin_week cos_week)],
		into   => [qw(time_sin time_cos)],
	},
	bytes  => { munger => 'log',  offset => 1 },
	method => { munger => 'enum', map    => { GET => 0, POST => 1 } },
);

sub new_writer {
	my %args    = @_;
	my $basedir = tempdir( CLEANUP => 1 );
	my $zorita  = Algorithm::Classifier::IsolationForest::Zorita->new( basedir => $basedir );
	$zorita->write_info(
		slug => 'myapp',
		set  => 'http-logs',
		info => { tags => [@TAGS], 'days_back' => 7, %args },
	);
	return $WRITER_CLASS->new(
		zorita => $zorita,
		slug   => 'myapp',
		set    => 'http-logs',
		writer => 'web01'
	);
} ## end sub new_writer

sub slurp_lines {
	my $file = shift;
	open my $fh, '<', $file or die "cannot read $file: $!";
	my @lines = <$fh>;
	close $fh;
	chomp @lines;
	return @lines;
}

# ---- write_named munges raw input, expander fills both time columns ---------
{
	my $writer = new_writer( mungers => \%MUNGERS );
	my $file   = $writer->write_named(
		{
			timestamp => '2026-07-05T00:00:00',    # Sunday midnight -> sin 0, cos 1
			bytes     => 0,                        # log1p(0) = 0
			method    => 'POST',                   # enum -> 1
			status    => 404,                      # raw
		}
	);

	my @lines = slurp_lines($file);
	is( $lines[0],  join( ',', @TAGS ), 'header is the tag names' );
	is( $lines[-1], '0,1,0,1,404',      'row: sin/cos pair, log1p(0), enum(POST), raw status' );
}

# ---- a munger croak surfaces as a write failure ----------------------------
{
	my $writer = new_writer( mungers => \%MUNGERS );
	eval {
		$writer->write_named(
			{
				timestamp => '2026-07-05T00:00:00',
				bytes     => 0,
				method    => 'HEAD',
				status    => 200,                     # HEAD unmapped
			}
		);
	};
	like( $@, qr/enum munger.*no mapping for 'HEAD'/, 'an enum miss croaks the write' );
}

# ---- positional write is refused when the set has an expander ---------------
{
	my $writer = new_writer( mungers => \%MUNGERS );
	eval { $writer->write( [ 0, 1, 0, 1, 200 ] ) };
	like( $@, qr/expanding mungers/, 'positional write() rejected for a set with a sin/cos expander' );
}

# ---- a set with no mungers is unchanged (regression) -----------------------
{
	my $writer = new_writer();                                                                                         # no mungers key
	my $file   = $writer->write_named( { time_sin => 0, time_cos => 1, bytes => 1234, method => 2, status => 200 } );
	my @lines  = slurp_lines($file);
	is( $lines[-1], '0,1,1234,2,200', 'no-munger set writes values straight through' );

	# positional still works with no expander
	my $writer2 = new_writer();
	my $f2      = $writer2->write( [ 0, 1, 5, 6, 7 ] );
	is( ( slurp_lines($f2) )[-1], '0,1,5,6,7', 'positional write with no mungers' );
}

# ---- eager validation: a bad munger config croaks at write_info -------------
{
	my $zorita = Algorithm::Classifier::IsolationForest::Zorita->new( basedir => tempdir( CLEANUP => 1 ) );

	# unknown munger name
	eval {
		$zorita->write_info(
			slug => 'myapp',
			set  => 'bad',
			info => {
				tags    => [qw(a)],
				mungers => { a => { munger => 'bogus' } }
			}
		);
	};
	like( $@, qr/unknown munger 'bogus'/, 'write_info rejects an unknown munger' );
	ok( !-f $zorita->info_path( slug => 'myapp', set => 'bad' ), 'nothing was written for the rejected set' );

	# broken expander coverage
	eval {
		$zorita->write_info(
			slug => 'myapp',
			set  => 'bad2',
			info => {
				tags    => [qw(s c)],
				mungers => {
					tw => {
						munger => 'datetime',
						from   => 'ts',
						format => $FMT,
						parts  => [qw(sin_week cos_week)],
						into   => [qw(s nope)]
					}
				}
			}
		);
	};
	like( $@, qr/unknown column 'nope'/, 'write_info rejects bad into coverage' );

	# mungers without tags
	eval { $zorita->write_info( slug => 'myapp', set => 'bad3', info => { mungers => { a => { munger => 'log' } } } ); };
	like( $@, qr/requires a non-empty 'tags'/, 'write_info rejects mungers without tags' );

	# a valid munger config still writes
	my $path = $zorita->write_info(
		slug => 'myapp',
		set  => 'good',
		info => {
			tags    => [qw(a)],
			mungers => { a => { munger => 'log', offset => 1 } }
		}
	);
	ok( -f $path, 'a valid munger config writes as before' );

	# tag sanity: tags obey the standard name rule (which also keeps the
	# comma-joined CSV header well-formed)
	eval { $zorita->write_info( slug => 'myapp', set => 'bad4', info => { tags => [ 'ok', 'not ok' ] } ); };
	like( $@, qr/invalid tag 'not ok'/, 'write_info rejects a tag violating the name rule' );
	eval { $zorita->write_info( slug => 'myapp', set => 'bad4', info => { tags => ['dotted.name'] } ); };
	like( $@, qr/invalid tag 'dotted\.name'/, 'write_info rejects a dotted tag' );
	eval { $zorita->write_info( slug => 'myapp', set => 'bad5', info => { tags => [qw(dup dup)] } ); };
	like( $@, qr/duplicate tag 'dup'/, 'write_info rejects duplicate tags' );

	# write_template runs the same gate, so a broken template is refused at
	# write time instead of poisoning every set stamped from it
	eval {
		$zorita->write_template(
			template => 'broken',
			info     => {
				tags    => [qw(a)],
				mungers => { a => { munger => 'bogus' } }
			}
		);
	};
	like( $@, qr/unknown munger 'bogus'/, 'write_template rejects a bad munger config' );
	ok( !-f $zorita->template_path( template => 'broken' ), 'the rejected template was not written' );

	eval { $zorita->write_template( template => 'diepolicy', info => { tags => [qw(a)], missing => 'die' } ); };
	like( $@, qr/may not be 'die'/, "write_template rejects missing => 'die'" );

	my $tpl = $zorita->write_template(
		template => 'good',
		info     => {
			tags    => [qw(a)],
			mungers => { a => { munger => 'log', offset => 1 } }
		}
	);
	ok( -f $tpl, 'a sane template writes as before' );

	# create_set still validates, covering hand-dropped template files that
	# never went through write_template
	require File::Path;
	File::Path::make_path( $zorita->template_dir );
	open my $fh, '>', $zorita->template_path( template => 'dropped' )
		or die "cannot write template fixture: $!";
	print {$fh} '{"tags":["a"],"mungers":{"a":{"munger":"bogus"}}}';
	close $fh;
	eval { $zorita->create_set( slug => 'myapp', set => 'from-tpl', template => 'dropped' ); };
	like( $@, qr/unknown munger 'bogus'/, 'create_set rejects a hand-dropped template with a bad munger config' );
}

done_testing;
