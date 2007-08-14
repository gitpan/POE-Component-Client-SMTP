#!perl -T

# Copyright (c) 2005-2007 George Nistorica
# All rights reserved.
# This program is part of POE::Component::Client::SMTP
# POE::Componen::Client::SMTP is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.  See the LICENSE
# file that comes with this distribution for more details.

use Test::More tests => 1;

BEGIN {
    use_ok('POE::Component::Client::SMTP');
}

diag(
"Testing POE::Component::Client::SMTP $POE::Component::Client::SMTP::VERSION, Perl $], $^X"
);
