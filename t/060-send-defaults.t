#!/usr/bin/perl -w

# Copyright (c) 2005 George Nistorica
# All rights reserved.
# This file is part of POE::Component::Client::SMTP
# POE::Component::Client::SMTP is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.  See the LICENSE
# file that comes with this distribution for more details.

# Test the defaults as stated in the lib POD
# TODO: 
# not all defaults are tested, maybe i should test using another class that 
# derives from PoCoClSMTP and that can check the parameters ;-)
use strict;

use lib '../lib';
use Test::More tests=>6;    # including use_ok
use Data::Dumper;
use Carp;

BEGIN{use_ok("IO::Socket::INET");};
BEGIN{use_ok("POE");};
BEGIN{use_ok("POE::Wheel::ListenAccept");};
BEGIN{use_ok("POE::Component::Server::TCP");};
BEGIN{use_ok("POE::Component::Client::SMTP");};

my $test = 0;

my $smtp_message;
my @recipients;
my $from;
my $debug = 0;

my %defaults = (
    From => 'root@localhost',
    To  =>  'root@localhost',
    Body => '',
    Server  => 'localhost',
    Port    =>  25,
    Timeout => 30,
    MyHostname => 'localhost',
    Debug => 0,
    Context => undef,
    SMTP_Success => undef,
    SMTP_Failure => undef,
    
);

$smtp_message = create_smtp_message();
@recipients = qw(
);
$from = '';

##### SMTP server vars
my $port = 25252;
my $EOL="\015\012";
my @smtp_server_responses = (
    "220 localhost ESMTP POE::Component::Client::SMTP Test Server",
    "250-localhost$EOL".
    "250-PIPELINING$EOL".
    "250-SIZE 250000000$EOL".
    "250-VRFY$EOL".
    "250-ETRN$EOL".
    "250 8BITMIME",
    "250 Ok",   # mail from
    "250 Ok",   # rcpt to:
    "354 End data with <CR><LF>.<CR><LF>",  # data
    "250 Ok: queued as 549B14484F", # end data
    "221 Bye",  # quit
);


POE::Component::Server::TCP->new(
    Port    => $port,
    Address    => "localhost",
    Domain  =>  AF_INET,
    Alias   =>  "smtp_server",
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
        _start => \&start_session,
        _stop => \&stop_session,
        send_mail => \&spawn_pococlsmt,
        pococlsmtp_success => \&smtp_send_success,
        pococlsmtp_failure => \&smtp_send_failure,
    },
);



POE::Kernel->run();

is( $test, 3, "Defaults");
diag("Defaults");


sub start_session{
    $_[KERNEL]->yield("send_mail");
}

sub spawn_pococlsmt{
    POE::Component::Client::SMTP->send(
#         From => $from,
#         To => \@recipients,
#         SMTP_Success => 'pococlsmtp_success',
#         SMTP_Failure => 'pococlsmtp_failure',
#         Server => 'localhost',
         Port    => $port,
#         Body => $smtp_message,
#         Context => "test context",
#            Debug => 1,
    );
}

sub stop_session{
    # stop server
    $_[KERNEL]->call( smtp_server => "shutdown" );
}

sub smtp_send_success{
    my ($arg0, $arg1) = @_[ARG0, ARG1];
    print "ARG0, ", Dumper($arg0), "\nARG1, ",Dumper($arg1) if $debug;
    $test = 1;
}

sub smtp_send_failure{
    my ($arg0, $arg1) = @_[ARG0, ARG1];
    print "ARG0, ", Dumper($arg0), "\nARG1, ",Dumper($arg1) if $debug;
    $test = 0;
}

sub create_smtp_message{
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

sub error_handler{
    carp "Something nasty happened";
    exit 100;
}

sub handle_client_input{
    my ( $heap, $input ) = @_[ HEAP, ARG0 ];

    if ($input =~ /^(helo|ehlo|mail from:|rcpt to:|data|\.|quit)/i){
        print "$input\n" if $debug;
        if ( $input =~ /(mail from: <)(.+)(>)/i){
            $test++ if ( $2 eq $defaults{'From'} );
        }elsif( $input =~ /(rcpt to: <)(.+)(>)/i ){
            $test++ if ( $2 eq $defaults{'To'});
        }elsif( $input =~ /(helo|ehlo)\s(.*)$/i ){
            $test++ if ( $2 eq $defaults{'MyHostname'} );
        }
        $heap->{'client'}->put(shift @smtp_server_responses);
    }
}

sub handle_client_connect{
    $_[HEAP]->{'client'}->put(shift @smtp_server_responses);
}

sub handle_client_disconnect{
}

sub handle_client_error{
}

sub handle_client_flush{
}


