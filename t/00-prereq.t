#!perl -T
use Test::More tests=>4;

use_ok('POE');
use_ok('POE::Filter::Line');
use_ok('POE::Wheel::SocketFactory');
use_ok('POE::Wheel::ReadWrite');
diag("Checking for prerequisites");
