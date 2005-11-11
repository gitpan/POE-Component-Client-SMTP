# Copyright (c) 2005 George Nistorica
# All rights reserved.
# This file is part of POE::Component::Client::SMTP
# POE::Component::Client::SMTP free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.  See the LICENSE
# file that comes with this distribution for more details.

use strict;
use warnings;
use Module::Build;

my $builder = Module::Build->new(
    module_name         => 'POE::Component::Client::SMTP',
    license             => 'perl',
    dist_author         => 'George Nistorica <ultadm@cpan.org>',
    dist_version_from   => 'lib/POE/Component/Client/SMTP.pm',
    requires => {
        'Test::More'                => 0,
        'Carp'                      => 0,
        'Socket'                    => 0,
        'Data::Dumper'              => 0,
        'POE'                       => '0.26',
        'POE::Wheel::SocketFactory' => 0,
        'POE::Wheel::ReadWrite'     => 0,
        'POE::Filter::Line'         => 0,
        'POE::Filter::Stream'       => 0,
    },
    add_to_cleanup      => [ 'POE-Component-Client-SMTP-*' ],
);

$builder->create_build_script();
