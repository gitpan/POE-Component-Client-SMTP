#!/usr/bin/perl -w

# Copyright (c) 2005 - 2007 George Nistorica
# All rights reserved.
# This file is part of POE::Component::Client::SMTP
# POE::Component::Client::SMTP is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.  See the LICENSE
# file that comes with this distribution for more details.

use strict;

# check that MessageFile slurps the file
# check that FileHandle slurps the file
# TODO:
# check that MessageFile to a file that can't be read returns error event
# check that Body parameter is disabled when one of the above is set

use lib '../lib';
use Test::More tests => 7;    # including use_ok
use Data::Dumper;
use Carp;
use Symbol qw( gensym );

BEGIN { use_ok("IO::Socket::INET"); }
BEGIN { use_ok("POE"); }
BEGIN { use_ok("POE::Wheel::ListenAccept"); }
BEGIN { use_ok("POE::Component::Server::TCP"); }
BEGIN { use_ok("POE::Component::Client::SMTP"); }

my $message_file = 't/email_message.txt';

# my $message_file = '/tmp/text';

# the tests we're running
my %test = (
    'filehandle'  => 0,
    'messagefile' => 0,
);

my $debug = 0;

my @recipients = qw(
  george@localhost
  root@localhost
  george.nistorica@localhost
);
my $from = 'george@localhost';

##### SMTP server vars
my $port                  = 25252;
my $EOL                   = "\015\012";
my @smtp_server_responses = (
    "220 localhost ESMTP POE::Component::Client::SMTP Test Server",
    "250-localhost$EOL"
      . "250-PIPELINING$EOL"
      . "250-SIZE 250000000$EOL"
      . "250-VRFY$EOL"
      . "250-ETRN$EOL"
      . "250 8BITMIME",
    "250 Ok",                                 # mail from
    "250 Ok",                                 # rcpt to:
    "250 Ok",                                 # rcpt to:, cc
    "250 Ok",                                 # rctp to:, bcc
    "354 End data with <CR><LF>.<CR><LF>",    # data
    "250 Ok: queued as 549B14484F",           # end data
    "221 Bye",                                # quit
);

# create the SMTP server session
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

# create the pococlsmtp master session
# 4 of them :)

foreach my $key ( keys %test ) {
    if ( $key eq 'filehandle' ) {
        my $handle = open_file($message_file);
        POE::Session->create(
            inline_states => {
                _start             => \&start_session,
                _stop              => \&stop_session,
                send_mail          => \&spawn_pococlsmt,
                pococlsmtp_success => \&smtp_send_success,
                pococlsmtp_failure => \&smtp_send_failure,
            },
            heap => {
                'test'   => $key,
                'handle' => $handle,
              }    # store the test name for each session

        );
    }
    else {
        POE::Session->create(
            inline_states => {
                _start             => \&start_session,
                _stop              => \&stop_session,
                send_mail          => \&spawn_pococlsmt,
                pococlsmtp_success => \&smtp_send_success,
                pococlsmtp_failure => \&smtp_send_failure,
            },
            heap => { 'test' => $key, }   # store the test name for each session
        );

    }
}

POE::Kernel->run();

# run tests
foreach my $key ( keys %test ) {
    is( $test{$key}, 1, $key );
}

sub start_session {
    carp "start_session" if ( $debug == 2 );
    $_[KERNEL]->yield("send_mail");
}

sub spawn_pococlsmt {
    carp "spawn_pococlsmt" if ( $debug == 2 );
    my $heap       = $_[HEAP];
    my %parameters = (
        From         => $from,
        To           => \@recipients,
        SMTP_Success => 'pococlsmtp_success',
        SMTP_Failure => 'pococlsmtp_failure',
        Server       => 'localhost',
        Port         => $port,

        # check that body is deleted
        Body    => "This message should not exist",
        Context => "test context",
        Debug   => 0,
    );

    if ( $heap->{'test'} eq 'filehandle' ) {
        $parameters{'MyHostname'} = 'filehandle';
        $parameters{'FileHandle'} = $heap->{'handle'};
    }
    elsif ( $heap->{'test'} eq 'messagefile' ) {
        $parameters{'MyHostname'}  = 'messagefile';
        $parameters{'MessageFile'} = $message_file;
    }

    POE::Component::Client::SMTP->send(%parameters);
}

sub stop_session {

    # stop server
    carp "stop_session" if ( $debug == 2 );
    $_[KERNEL]->call( smtp_server => "shutdown" );
}

sub smtp_send_success {
    my ( $arg0, $arg1, $heap ) = @_[ ARG0, ARG1, HEAP ];
    print "SMTP_Success: ARG0, ", Dumper($arg0), "\nARG1, ", Dumper($arg1), "\n"
      if $debug;
}

sub smtp_send_failure {
    my ( $arg0, $arg1, $arg2, $heap ) = @_[ ARG0, ARG1, ARG2, HEAP ];
    print "SMTP_Failure: ARG0, ", Dumper($arg0), "\nARG1, ", Dumper($arg1), "\n"
      if $debug;
}

sub error_handler {
    carp "Something nasty happened";
    exit 100;
}

sub handle_client_input {
    my ( $heap, $input ) = @_[ HEAP, ARG0 ];
    carp "handle_client_input" if ( $debug == 2 );
    my $client = $heap->{'client'};
    if ( $input =~ /^(ehlo|helo|mail from:|rcpt to:|data|\.|quit)/i ) {
        if ( $input =~ /^(ehlo|helo)\s(\w+)/i ) {
            $heap->{'test'}->{$client} = $2;
        }
        $heap->{'client'}
          ->put( shift @{ $heap->{'smtp_server_responses'}->{$client} } );
    }
    else {
        $heap->{'client_message'}->{$client} .= "$input\n";
    }
}

sub handle_client_connect {
    my $heap   = $_[HEAP];
    my $client = $heap->{'client'};
    @{ $heap->{'smtp_server_responses'}->{$client} } = @smtp_server_responses;
    $heap->{'client_message'}->{$client} = "";
    $heap->{'client'}
      ->put( shift @{ $heap->{'smtp_server_responses'}->{$client} } );
}

sub handle_client_disconnect {
    my $heap   = $_[HEAP];
    my $client = $heap->{'client'};
    delete $heap->{'smtp_server_responses'}->{$client};
    delete $heap->{'client_message'}->{$client};
    carp "handle_client_disconnect" if ( $debug == 2 );
}

sub handle_client_error {
    my $heap   = $_[HEAP];
    my $client = $heap->{'client'};
    delete $heap->{'smtp_server_responses'}->{$client};
    if ( $heap->{'client_message'}->{$client} eq message_file() ) {
        $test{ $heap->{'test'}->{$client} } = 1;
    }
    else {
        $test{ $heap->{'test'}->{$client} } = 0;
        print "Not the same!\n";
    }
    delete $heap->{'client_message'}->{$client};
    carp "handle_client_error" if ( $debug == 2 );
}

sub handle_client_flush {
    carp "handle_client_flush" if ( $debug == 2 );
}

sub message_file {
    my $message_file = << "EOF";
To: George Nistorica <george\@localhost>
CC: Root <george\@localhost>
Bcc: Alter Ego <george.nistorica\@localhost>
From: Charlie Root <george\@localhost>
Subject: Email test

Ok ...
EOF

    return $message_file;
}

sub open_file {
    my $filename = shift;
    my $handle   = gensym();

    if ( -e $filename ) {
        open $handle, q{<}, "$filename" || die "$!";
    }
    else {
        die "$filename does not exist!\n";
    }

    return $handle;
}
