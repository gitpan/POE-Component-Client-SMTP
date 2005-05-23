use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME                => 'POE::Component::Client::SMTP',
    AUTHOR              => 'George Nistorica <george@nistorica.ro>',
    VERSION_FROM        => 'lib/POE/Component/Client/SMTP.pm',
    ABSTRACT_FROM       => 'lib/POE/Component/Client/SMTP.pm',
    PL_FILES            => {},
    PREREQ_PM => {
        'Test::More' => 0,
	'POE'        => 0.25,
    },
    dist                => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean               => { FILES => 'POE-Component-Client-SMTP-*' },
);
