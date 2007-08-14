#!/usr/bin/perl -w

# Copyright (c) 2005 - 2007 George Nistorica
# All rights reserved.
# This file is part of POE::Component::Client::SMTP
# POE::Component::Client::SMTP is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.  See the LICENSE
# file that comes with this distribution for more details.

use strict;

# check that by default the transaction log is disabled when SMTP_Success - ARG1 undefined
# check that by default the transaction log is disabled when SMTP_Failure - ARG1 undefined
# check that when enabled, you really get the transaction log when SMTP_Success - ARG1
# check that when enabled, you really get the transaction log when SMTP_Failure - ARG2

use lib '../lib';
use Test::More tests => 9;    # including use_ok
use Data::Dumper;
use Carp;

BEGIN { use_ok("IO::Socket::INET"); }
BEGIN { use_ok("POE"); }
BEGIN { use_ok("POE::Wheel::ListenAccept"); }
BEGIN { use_ok("POE::Component::Server::TCP"); }
BEGIN { use_ok("POE::Component::Client::SMTP"); }

# the tests we're running
my %test = (
    'transaction_log_disabled_smtp_failure' => 0,
    'transaction_log_disabled_smtp_success' => 0,
    'transaction_log_enabled_smtp_failure'  => 0,
    'transaction_log_enabled_smtp_success'  => 0,
);
my $smtp_message;
my @recipients;
my $from;
my $debug = 0;

$smtp_message = create_smtp_message();
@recipients   = qw(
  george@localhost,
  root@localhost,
  george.nistorica@localhost,
);
$from = 'george@localhost';

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
    POE::Session->create(
        inline_states => {
            _start             => \&start_session,
            _stop              => \&stop_session,
            send_mail          => \&spawn_pococlsmt,
            pococlsmtp_success => \&smtp_send_success,
            pococlsmtp_failure => \&smtp_send_failure,
        },
        heap => { 'test' => $key, }    # store the test name for each session
    );
}

POE::Kernel->run();

# run tests
foreach my $key ( keys %test ) {
    my $name = $key;
    $name =~ s/_/ /g;
    is( $test{$key}, 1, $name );
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
        Body         => $smtp_message,
        Context      => "test context",
        Debug        => 0,
    );

# depending on which test we're running there are some things to be
# modified as well. look also for the Server how it does handle client connection
    if ( $heap->{'test'} eq 'transaction_log_enabled_smtp_success' ) {
        $parameters{'TransactionLog'} = 1;
    }
    if ( $heap->{'test'} eq 'transaction_log_enabled_smtp_failure' ) {
        $parameters{'TransactionLog'} = 1;
        $parameters{'MyHostname'}     = 'Fail';
    }
    elsif ( $heap->{'test'} eq 'transaction_log_disabled_smtp_failure' ) {
        $parameters{'MyHostname'} = 'Fail';
    }
    POE::Component::Client::SMTP->send( %parameters );
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

    if ( $heap->{'test'} eq 'transaction_log_disabled_smtp_success' ) {
        if ( not defined $arg1 ) {
            $test{ $heap->{'test'} } = 1;
        }
    }
    elsif ( $heap->{'test'} eq 'transaction_log_enabled_smtp_success' ) {

        # do we have a transaction log?
        if ( defined $arg1 ) {

            # this is how it should be
            if ( compare_transaction_logs( $arg1, return_transaction_log() ) ) {
                $test{ $heap->{'test'} } = 1;
            }
        }
    }

}

sub smtp_send_failure {
    my ( $arg0, $arg1, $arg2, $heap ) = @_[ ARG0, ARG1, ARG2, HEAP ];
    print "SMTP_Failure: ARG0, ", Dumper($arg0), "\nARG1, ", Dumper($arg1), "\n"
      if $debug;

    if ( $heap->{'test'} eq 'transaction_log_disabled_smtp_failure' ) {
        if ( not defined $arg2 ) {
            $test{ $heap->{'test'} } = 1;
        }
    }
    elsif ( $heap->{'test'} eq 'transaction_log_enabled_smtp_failure' ) {
        if ( defined $arg2 ) {
            if (
                compare_transaction_logs(
                    $arg2, return_failed_transaction_log()
                )
              )
            {
                $test{ $heap->{'test'} } = 1;
            }
        }
    }
}

sub create_smtp_message {
    my $body = <<EOB;
To: George Nistorica <george\@localhost>
CC: Root <george\@localhost>
Bcc: Alter Ego <george.nistorica\@localhost>
From: Charlie Root <george\@localhost>
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
    carp "handle_client_input" if ( $debug == 2 );

    if ( $input =~ /^ehlo fail/i or $input =~ /^helo fail/i ) {

        # this is for the error part
        $heap->{'client'}->put('500 error');
    }
    elsif ( $input =~ /^(ehlo|helo|mail from:|rcpt to:|data|\.|quit)/i ) {
        my $client = $heap->{'client'};
        $heap->{'client'}
          ->put( shift @{ $heap->{'smtp_server_responses'}->{$client} } );
    }
}

sub handle_client_connect {
    my $heap   = $_[HEAP];
    my $client = $heap->{'client'};
    @{ $heap->{'smtp_server_responses'}->{$client} } = @smtp_server_responses;
    $heap->{'client'}
      ->put( shift @{ $heap->{'smtp_server_responses'}->{$client} } );
}

sub handle_client_disconnect {
    my $heap   = $_[HEAP];
    my $client = $heap->{'client'};
    delete $heap->{'smtp_server_responses'}->{$client};
    carp "handle_client_disconnect" if ( $debug == 2 );
}

sub handle_client_error {
    my $heap   = $_[HEAP];
    my $client = $heap->{'client'};
    delete $heap->{'smtp_server_responses'}->{$client};
    carp "handle_client_error" if ( $debug == 2 );
}

sub handle_client_flush {
    carp "handle_client_flush" if ( $debug == 2 );
}

sub return_failed_transaction_log {
    my @transaction_log = (
        '<- 220 localhost ESMTP POE::Component::Client::SMTP Test Server',
        '-> HELO Fail', '<- 500 error'
    );

    return \@transaction_log;
}

sub return_transaction_log {
    my @transaction_log = (
        '<- 220 localhost ESMTP POE::Component::Client::SMTP Test Server',
        '-> HELO localhost',
        '<- 250-localhost',
        '<- 250-PIPELINING',
        '<- 250-SIZE 250000000',
        '<- 250-VRFY',
        '<- 250-ETRN',
        '<- 250 8BITMIME',
        '-> MAIL FROM: <george@localhost>',
        '<- 250 Ok',
        '-> RCPT TO: <george@localhost,>',
        '<- 250 Ok',
        '-> RCPT TO: <root@localhost,>',
        '<- 250 Ok',
        '-> RCPT TO: <george.nistorica@localhost,>',
        '<- 250 Ok',
        '-> DATA',
        '<- 354 End data with <CR><LF>.<CR><LF>',
        '-> To: George Nistorica <george@localhost>
CC: Root <george@localhost>
Bcc: Alter Ego <george.nistorica@localhost>
From: Charlie Root <george@localhost>
Subject: Email test

Sent with ' . $POE::Component::Client::SMTP::VERSION . '

' . "\r" . '.',

        '<- 250 Ok: queued as 549B14484F',
        '-> QUIT',
        '<- 221 Bye'
    );

    return \@transaction_log;
}

sub compare_transaction_logs {
    my $transaction_log          = shift;
    my $expected_transaction_log = shift;

    my $same = 1;

    my ( @actual, @expected );

    foreach my $line ( @{$transaction_log} ) {
        $line =~ s /(\r)|(\n)|(\r\n)//g;

        #         push @actual, split //, $line;
    }
    foreach my $line ( @{$expected_transaction_log} ) {
        $line =~ s /(\r)|(\n)|(\r\n)//g;

        #         push @expected, split //, $line;
    }

    if ( scalar @{$transaction_log} != scalar @{$expected_transaction_log} ) {
        warn "Transaction logs differ!";
        $same = 0;
    }
    else {
        for ( my $i = 0 ; $i < scalar @{$transaction_log} ; $i++ ) {
            if ( $transaction_log->[$i] ne $expected_transaction_log->[$i] ) {
                $same = 0;
                last;
            }
        }
    }

#     if ( scalar @actual != scalar @expected ){
#         print "Number of transaction log characters differ!\n";
#     }
#
#     for (my $i = 0; $i<scalar(@actual); $i++){
#         if ( $actual[$i] ne $expected[$i]){
#             print "Element: \"$actual[$i]\" differs from: \"expected[$i]\"\n";
#         }
#     }

    return $same;
}
