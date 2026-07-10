use 5.006;
use strict;
use warnings;
use ExtUtils::MakeMaker;

my %WriteMakefileArgs = (
	NAME               => 'Algorithm::Classifier::IsolationForest::Zorita',
	AUTHOR             => q{Zane C. Bowers-Hadley <vvelox@vvelox.net>},
	VERSION_FROM       => 'lib/Algorithm/Classifier/IsolationForest/Zorita.pm',
	ABSTRACT_FROM      => 'lib/Algorithm/Classifier/IsolationForest/Zorita.pm',
	LICENSE            => 'lgpl_2_1',
	MIN_PERL_VERSION   => '5.006',
	EXE_FILES          => ['src_bin/zorita'],
	CONFIGURE_REQUIRES => {
		'ExtUtils::MakeMaker' => '0',
	},
	TEST_REQUIRES => {
		'Test::More' => '0',
	},
	PREREQ_PM => {
		'JSON::PP'                               => '0',
		'App::Cmd'                               => '0',
		'Algorithm::Classifier::IsolationForest' => '0.5.0',
		# the input mungers (and their Time::Piece / EventsPerSecond deps and
		# the FNV-1a XS) were extracted into their own distribution; the writer
		# compiles a set's info.json into a munging plan through it
		'Algorithm::ToNumberMunger'              => '0.0.1',
	},
	dist  => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
	clean => { FILES    => 'Algorithm-Classifier-IsolationForest-Zorita-*' },
);

# Compatibility with old versions of ExtUtils::MakeMaker
unless ( eval { ExtUtils::MakeMaker->VERSION('6.64'); 1 } ) {
	my $test_requires = delete $WriteMakefileArgs{TEST_REQUIRES} || {};
	@{ $WriteMakefileArgs{PREREQ_PM} }{ keys %$test_requires } = values %$test_requires;
}

unless ( eval { ExtUtils::MakeMaker->VERSION('6.55_03'); 1 } ) {
	my $build_requires = delete $WriteMakefileArgs{BUILD_REQUIRES} || {};
	@{ $WriteMakefileArgs{PREREQ_PM} }{ keys %$build_requires } = values %$build_requires;
}

delete $WriteMakefileArgs{CONFIGURE_REQUIRES}
	unless eval { ExtUtils::MakeMaker->VERSION('6.52'); 1 };
delete $WriteMakefileArgs{MIN_PERL_VERSION}
	unless eval { ExtUtils::MakeMaker->VERSION('6.48'); 1 };
delete $WriteMakefileArgs{LICENSE}
	unless eval { ExtUtils::MakeMaker->VERSION('6.31'); 1 };

WriteMakefile(%WriteMakefileArgs);
