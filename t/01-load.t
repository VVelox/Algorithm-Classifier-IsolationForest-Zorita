#!perl
use 5.006;
use strict;
use warnings;
use Test::More;

plan tests => 1;

BEGIN {
	use_ok('Algorithm::Classifier::IsolationForest::Zorita::Writer')
		|| print "Bail out!\n";
}

diag(
	"Testing Algorithm::Classifier::IsolationForest::Zorita::Writer $Algorithm::Classifier::IsolationForest::Zorita::Writer::VERSION, Perl $], $^X"
);
