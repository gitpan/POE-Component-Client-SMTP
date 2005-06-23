#!/usr/bin/perl -w
use strict;

use lib '../lib';

use IO::Socket::INET;

use POE qw(Wheel::ListenAccept);

use POE::Component::Client::SMTP;

use Test::More tests => 1;

my $success   = 0;
my $mail_body =
  "Ce faci bro' ? iar ai uitat de mine?\n" . "Hai! \r\n\la munca!!!!\n";

my $sender    = 'george@localhost';
my $recipient = 'george@localhost';
my $server    = 'localhost';
my $port      = 25;

POE::Session->create(
    inline_states => {
        _start       => \&start,
        send_mail    => \&send_mail,
        smtp_success => \&smtp_success,
        smtp_error   => \&smtp_error,
        _stop        => \&stop,
    },
    heap => { smtp_body => \$mail_body, },
);

POE::Kernel->run();

sub start {
    $_[KERNEL]->yield("send_mail");
}

sub send_mail {

    my $ref_to_data;
    my $data;

    $data        = "test test\nsdasdas\n";
    $ref_to_data = \$data;

    POE::Component::Client::SMTP->send(
        alias          => 'smtp_client',
        smtp_server    => $server,
        smtp_port      => $port,
        smtp_sender    => $sender,
        smtp_recipient => $recipient,
        to             => "Cos",
        from           => "Crony",
        subject        => "brrr, iar stai degeaba?!",
        smtp_body      => $_[HEAP]->{'smtp_body'},
        smtp_timeout   => 1,
        debug          => 2,

        SMTPSendSuccessEvent => "smtp_success",
        SMTPSendFailureEvent => "smtp_error",
    );
}

sub smtp_success {
    warn "success";
    $success = 1;
}

sub smtp_error {
    warn "eroare";
    my ( $err_type, $operation, $errnum, $errstr ) = @_[ ARG0 .. ARG4 ];
    warn "er: $err_type";
    my $heap = $_[HEAP];
    if ( $err_type == 2 ) {
        $success = 1;
        warn
"Could not connect to: $server:$port, error: $errnum, $errstr while $operation";
    }
    else {
        warn
"Could not connect to: $server:$port, error: $errnum, $errstr while $operation";
        $success = 0;
    }
}

sub stop {
    is( $success, 1,
        "Sending mail:from $sender, to $recipient, trough $server" );
}
