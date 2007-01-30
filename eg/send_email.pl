#!/usr/bin/perl -w
use strict;

# Copyright (c) 2005 George Nistorica
# All rights reserved.
# This file is part of POE::Component::Client::SMTP
# POE::Component::Client::SMTP is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.  See the LICENSE
# file that comes with this distribution for more details.

my $sender      = 'replace@with.email.address.net';
my $recipient   = 'replace@with.email.address.net';
my $smtp_server = 'your.relay.mail.server.net';
my $smtp_port   = 25;

# use the library from the kit
# remove the line below if you're using the system wide installed
# PoCoClSMTP
use lib '../lib';

use Data::Dumper;    # I always include this ;-)
use Email::MIME::Creator;
use IO::All;

use POE;
use POE::Component::Client::SMTP;

# main()
POE::Session->create(
    inline_states => {
        _start            => \&start_main_session,
        send_mail         => \&send_mail_from_main_session,
        send_mail_success => \&send_mail_success,
        send_mail_failure => \&send_mail_failure,
        _stop             => \&stop_main_session,
    }
);

POE::Kernel->run();

# done

sub start_main_session {

    #fire the things up
    $_[KERNEL]->yield("send_mail");
}

sub send_mail_from_main_session {
    my $email = create_message();

    # Note that you are prohibited by RFC to send bare LF characters in e-mail
    # messages; consult:
    # http://cr.yp.to/docs/smtplf.html
    $email =~ s/\n/\r\n/g;

    POE::Component::Client::SMTP->send(
        From         => $sender,
        To           => $recipient,
        Server       => $smtp_server,
        Port         => $smtp_port,
        Body         => $email,
        SMTP_Success => 'send_mail_success',
        SMTP_Failure => 'send_mail_failure',
    );
}

sub send_mail_success {
    print "Success\n";
}

sub send_mail_failure {
    my $fail = $_[ARG1];
    print Dumper($fail);
    print "Failure\n";
}

sub stop_main_session {
    print "End ...\n";
}

# Email Creation Part
# rather lame email creation.
# You may use any method that suits you (I usually create the messages by hand
# ;-) )
sub create_message {
    my $attachment_file = "text_mail_attachment.txt";

    my $email;
    my @parts;

    @parts = (
        Email::MIME->create(
            attributes => {
                filename     => "text.txt",
                content_type => "text/plain",
                encoding     => "quoted-printable",
                name         => "Example attachment",
            },
            body => io($attachment_file)->all,
        ),
        Email::MIME->create(
            attributes => {
                content_type => "text/plain",
                disposition  => "attachment",
                charser      => "US-ASCII",
            },
            body => "Howdy!",
        ),
    );

    $email = Email::MIME->create(
        header => [
            From => $sender,
            To   => $recipient,
        ],
        parts => [@parts],
    );

    # return the message
    return $email->as_string;
}

