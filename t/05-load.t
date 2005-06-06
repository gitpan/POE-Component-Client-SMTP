#!perl -T
use Test::More tests => 1;

BEGIN {
use_ok( 'POE::Component::Client::SMTP' );
}

diag( "Testing POE::Component::Client::SMTP $POE::Component::Client::SMTP::VERSION, Perl 5.008005, /usr/bin/perl5.8.5" );
