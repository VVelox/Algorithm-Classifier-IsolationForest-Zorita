#!perl
use 5.006;
use strict;
use warnings;
use Test::More;

plan tests => 1;

BEGIN {
    use_ok( 'Algorithm::Classifier::IsolationForest::Zorita' ) || print "Bail out!\n";
}

diag( "Testing Algorithm::Classifier::IsolationForest::Zorita $Algorithm::Classifier::IsolationForest::Zorita::VERSION, Perl $], $^X" );
