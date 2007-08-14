#!/usr/local/bin/perl -w

# Copyright (c) 2007 George Nistorica
# All rights reserved.
# This file is part of POE::Component::Client::SMTP
# POE::Component::Client::SMTP is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.  See the LICENSE
# file that comes with this distribution for more details.

# Test PLAIN AUTH

use strict;
use lib '../lib';
use Test::More tests => 13;    # including use_ok

# use Test::More qw(no_plan);
use Data::Dumper;
use Carp;

BEGIN { use_ok("IO::Socket::INET"); }
BEGIN { use_ok("POE"); }
BEGIN { use_ok("POE::Wheel::ListenAccept"); }
BEGIN { use_ok("POE::Component::Server::TCP"); }
BEGIN { use_ok("POE::Component::Client::SMTP"); }

my $smtp_message;
my @recipients;
my $from;
my $debug = 0;

$smtp_message = create_smtp_message();
@recipients   = qw(
  george@localhost
);
$from = 'george@localhost';
my $myhostname         = 'george';
my $poco_said_hostname = undef;
my $plain_auth_string  = 'AGdlb3JnZQBhYnJhY2FkYWJyYQ==';

##### SMTP server vars
my $port = 25252;
my $EOL  = "\015\012";

# tests:
my %test = (
    test_auth                                            => 0,
    test_no_user                                         => 0,
    test_no_pass                                         => 0,
    test_mechanism_takes_precedence_over_wrong_host      => 0,
    test_wrong_host                                      => 0,
    test_no_user_takes_precedence_over_wrong_port        => 0,
    test_invalid_mechanism_takes_precedence_over_no_user => 0,
);

my @smtp_server_responses = (
    "220 localhost ESMTP POE::Component::Client::SMTP Test Server",
    "250-localhost$EOL"
      . "250-STARTTLS$EOL"
      . "250-PIPELINING$EOL"
      . "250-8BITMIME$EOL"
      . "250-SIZE 32000000$EOL"
      . "250-AUTH=CRAM-MD5 DIGEST-MD5 LOGIN PLAIN NTLM$EOL"
      .    # support broken clients
      "250 AUTH=CRAM-MD5 DIGEST-MD5 LOGIN PLAIN NTLM"
    ,      # don't want to break my unbroken client :D
    "235 ok, go ahead (#2.0.0)",
    "250 ok",
    "250 ok",
    "354 go ahead",
    "250 ok 1173791708 qp 32453",
    "221 localhost"
);

POE::Component::Server::TCP->new(
    Port                  => $port,
    Address               => "localhost",
    Domain                => AF_INET,
    Alias                 => "smtp_server",
    Error                 => \&error_handler,               # Optional.
    ClientInput           => \&handle_client_input,         # Required.
    ClientConnected       => \&handle_client_connect,       # Optional.
    ClientDisconnected    => \&handle_client_disconnect,    # Optional.
    ClientError           => \&handle_client_error,         # Optional.
    ClientFlushed         => \&handle_client_flush,         # Optional.
    ClientFilter          => "POE::Filter::Line",           # Optional.
    ClientInputFilter     => "POE::Filter::Line",           # Optional.
    ClientOutputFilter    => "POE::Filter::Line",           # Optional.
    ClientShutdownOnError => 1,                             #
);

POE::Session->create(
    inline_states => {
        _start             => \&start_session,
        _stop              => \&stop_session,
        send_mail          => \&spawn_pococlsmt,
        pococlsmtp_success => \&smtp_send_success,
        pococlsmtp_failure => \&smtp_send_failure,
    },
);

POE::Kernel->run();

is( $test{test_auth},    1, "Auth OK" );
is( $test{test_no_user}, 1, "No User" );
is( $test{test_no_pass}, 1, "No Pass" );
is( $test{test_mechanism_takes_precedence_over_wrong_host},
    1, "Mech precedes wrong host" );
is( $test{test_wrong_host}, 1, "Wrong host" );
is( $test{test_no_user_takes_precedence_over_wrong_port},
    1, "No User precedes wrong port" );
is( $test{test_invalid_mechanism_takes_precedence_over_no_user},
    1, "Invalid Mech precedes no User" );
is( $poco_said_hostname, $myhostname, "MyHostname" );
diag("Test PLAIN AUTH");

sub start_session {
    $_[KERNEL]->yield("send_mail");
}

sub spawn_pococlsmt {

# $from, $recipients, $server, $port, $smtp_message, $myhostname, $alias_append, $mech, $user, $pass
# Auth OK
    pococlsmtp_create(
        $from,         \@recipients, 'localhost', $port,
        $smtp_message, "Auth OK",    $myhostname, "auth_ok",
        'PLAIN',       'george',     'abracadabra',
    );

    # No User
    pococlsmtp_create(
        $from,         \@recipients, 'localhost', $port,
        $smtp_message, "No User",    $myhostname, "No_User",
        'PLAIN',,      'abracadabra',
    );

    # No Pass
    pococlsmtp_create(
        $from,         \@recipients, 'localhost', $port,
        $smtp_message, "No Pass",    $myhostname, "no_pass",
        'PLAIN',       'george',,
    );

    # Mech precedes wrong host
    pococlsmtp_create(
        $from,                      \@recipients,
        'thereisnosuchserverthere', $port,
        $smtp_message,              "Mech precedes wrong host",
        $myhostname,                "Mech_precedes_wrong_host",
        'PLAIN1',                   'george',
        'abracadabra',
    );

    # Wrong host
    pococlsmtp_create(
        $from,                      \@recipients,
        'thereisnosuchserverthere', $port,
        $smtp_message,              "Wrong host",
        $myhostname,                "Wrong_host",
        'PLAIN',                    'george',
        'abracadabra',
    );

    # No User precedes wrong port
    pococlsmtp_create(
        $from, \@recipients,
        'localhost', ( $port + 1 ),
        $smtp_message, "No User precedes wrong port",
        $myhostname,   "No_User_precedes_wrong_port",
        'PLAIN',,
        'abracadabra',
    );

    # Invalid Mech precedes no User
    pococlsmtp_create(
        $from,         \@recipients,
        'localhost',   $port,
        $smtp_message, "Invalid Mech precedes no User",
        $myhostname,   "Invalid_Mech_precedes_no_User",
        'PLAIN1',      '',
        'abracadabra',
    );

}

sub stop_session {

    # stop server
    $_[KERNEL]->call( smtp_server => "shutdown" );
}

sub smtp_send_success {
    my ( $kernel, $arg0, $arg1 ) = @_[ KERNEL, ARG0, ARG1 ];
    print "ARG0, ", Dumper($arg0), "\nARG1, ", Dumper($arg1), "\n" if $debug;

    if ( $arg0 eq 'Auth OK' ) {
        $test{test_auth} = 1;
    }
    elsif ( $arg0 eq 'No User'
        and $arg1->{'Configure'} eq
        'ERROR: You want AUTH but no USER/PASS given!' )
    {

        $test{test_no_user} = 0;
    }
    elsif ( $arg0 eq 'No Pass'
        and $arg1->{'Configure'} eq
        'ERROR: You want AUTH but no USER/PASS given!' )
    {
        $test{test_no_pass} = 0;

    }
    elsif ( $arg0 eq 'Mech precedes wrong host'
        and $arg1->{'Configure'} eq
        'ERROR: Method unsupported by Component version: '
        . $POE::Component::Client::SMTP::VERSION )
    {

        $test{test_mechanism_takes_precedence_over_wrong_host} = 0;

    }
    elsif ( $arg0 eq 'Wrong host'
        and exists( $arg1->{'POE::Wheel::SocketFactory'} ) )
    {
        $test{test_wrong_host} = 0;

    }
    elsif ( $arg0 eq 'No User precedes wrong port'
        and $arg1->{'Configure'} eq
        'ERROR: You want AUTH but no USER/PASS given!' )
    {
        $test{test_no_user_takes_precedence_over_wrong_port} = 0;

    }
    elsif ( $arg0 eq 'Invalid Mech precedes no User'
        and $arg1->{'Configure'} eq
        'ERROR: Method unsupported by Component version: '
        . $POE::Component::Client::SMTP::VERSION )
    {

        $test{test_invalid_mechanism_takes_precedence_over_no_user} = 0;

    }
    else {
        warn "What the hell! $arg0\/$arg1";
    }

}

sub smtp_send_failure {
    my ( $kernel, $arg0, $arg1 ) = @_[ KERNEL, ARG0, ARG1 ];
    print "\nARG0, ", $arg0, "\nARG1, ", Dumper($arg1) if $debug;
    if ( $arg0 eq 'Auth OK' ) {
        $test{test_auth} = 0;
    }
    elsif ( $arg0 eq 'No User'
        and $arg1->{'Configure'} eq
        'ERROR: You want AUTH but no USER/PASS given!' )
    {

        $test{test_no_user} = 1;
    }
    elsif ( $arg0 eq 'No Pass'
        and $arg1->{'Configure'} eq
        'ERROR: You want AUTH but no USER/PASS given!' )
    {
        $test{test_no_pass} = 1;

    }
    elsif ( $arg0 eq 'Mech precedes wrong host'
        and $arg1->{'Configure'} eq
        'ERROR: Method unsupported by Component version: '
        . $POE::Component::Client::SMTP::VERSION )
    {

        $test{test_mechanism_takes_precedence_over_wrong_host} = 1;

    }
    elsif ( $arg0 eq 'Wrong host'
        and exists( $arg1->{'POE::Wheel::SocketFactory'} ) )
    {
        $test{test_wrong_host} = 1;

    }
    elsif ( $arg0 eq 'No User precedes wrong port'
        and $arg1->{'Configure'} eq
        'ERROR: You want AUTH but no USER/PASS given!' )
    {
        $test{test_no_user_takes_precedence_over_wrong_port} = 1;

    }
    elsif ( $arg0 eq 'Invalid Mech precedes no User'
        and $arg1->{'Configure'} eq
        'ERROR: Method unsupported by Component version: '
        . $POE::Component::Client::SMTP::VERSION )
    {

        $test{test_invalid_mechanism_takes_precedence_over_no_user} = 1;

    }
    else {
        warn "What the hell! $arg0\/$arg1";
    }

}

sub create_smtp_message {
    my $body = <<EOB;
To: George Nistorica <george\@localhost>
Bcc: George Nistorica <george\@localhost>
CC: Alter Ego <root\@localhost>
From: Charlie Root <root\@localhost>
Subject: Email test

Sent with $POE::Component::Client::SMTP::VERSION
EOB

    return $body;
}

sub error_handler {
    carp "Something nasty happened";
    exit 100;
}

sub handle_client_input {
    my ( $heap, $input ) = @_[ HEAP, ARG0 ];

    if ( $input =~ /^(helo|ehlo|mail from:|rcpt to:|data|\.|quit|auth)/i ) {
        if ( $input =~ /^(ehlo|helo)\s(.*)$/i ) {
            $poco_said_hostname = $2 if defined $2;
        }
        elsif ( $input eq 'PLAIN AGdlb3JnZQBhYnJhY2FkYWJyYQ==' ) {
            $test{test_auth} = 1;
        }
        print "CLIENT SAID: $input\n" if $debug;
        $heap->{'client'}->put( shift @smtp_server_responses );
    }
}

sub handle_client_connect {
    $_[HEAP]->{'client'}->put( shift @smtp_server_responses );
}

sub handle_client_disconnect {
}

sub handle_client_error {
}

sub handle_client_flush {
}

sub pococlsmtp_create {
    my (
        $from,         $recipients, $server,     $port,
        $smtp_message, $context,    $myhostname, $alias_append,
        $mech,         $user,       $pass
    ) = @_;

    POE::Component::Client::SMTP->send(
        From         => $from,
        To           => $recipients,
        SMTP_Success => 'pococlsmtp_success',
        SMTP_Failure => 'pococlsmtp_failure',
        Server       => $server,
        Port         => $port,
        Body         => $smtp_message,
        Context      => $context,
        Timeout      => 20,
        MyHostname   => $myhostname,                          # to test
        Alias        => 'poco_smtp_alias_' . $alias_append,

        #         Debug => 1,
        Auth => {
            mechanism => $mech,
            user      => $user,
            pass      => $pass,
        }
    );
}
