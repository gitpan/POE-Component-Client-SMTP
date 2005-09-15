#!perl -T
# test sending
# the "SMTP" server is faking a live SMTP server
# I don't consider it polite to use the localhost SMTP server (if any) in order 
# to send "test" messages; some may consider it SPAM
# * the right event is emited?
# * no two different events are emited
# 
# Look into 10-send.pl for a working example (testing against a real world SMTP server)
use strict;
use lib '../lib';

use IO::Socket::INET;

use POE qw(Wheel::ListenAccept Component::Server::TCP);

use POE::Component::Client::SMTP;

use Test::More tests => 1;

my %tests = {
    mail_send => 0,
};

my $mail_body =
"Test mail, sent by POE::Component::Client::SMTP, version: $POE::Component::Client::SMTP::VERSION\n"
  . "at: "
  . localtime(time) . "\n"
  . "Please ignore, thank you.\n";

my $sender    = 'root@localhost';
my $recipient = 'root@localhost';
my $server    = 'localhost';
my $port      = 25252;
my $EOL = "\015\012";
my @smtp_server_responses = (
    "220 localhost ESMTP POE::Component::Client::SMTP Test Server",
    "250-localhost$EOL".
    "250-PIPELINING$EOL".
    "250-SIZE 250000000$EOL".
    "250-VRFY$EOL".
    "250-ETRN$EOL".
    "250 8BITMIME",
    "250 Ok",	# mail from
    "250 Ok",	# rcpt to:
    "354 End data with <CR><LF>.<CR><LF>",  # data
    "250 Ok: queued as 549B14484F", # end data
    "221 Bye",	# quit
);

POE::Component::Server::TCP->new(
    Port                  => $port,
    Address               => "localhost",
    Domain                => AF_INET,                       # Optional.
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
    ClientShutdownOnError => 1,                             # Optional.
);

POE::Session->create(
    inline_states => {
        _start       => \&client_start,
        send_mail    => \&client_send_mail,
        smtp_success => \&client_smtp_success,
        smtp_error   => \&client_smtp_error,
        _stop        => \&client_stop,
    },
    heap => { smtp_body => \$mail_body,},
);

POE::Kernel->run();
is( $tests{'mail_send'}, 1, "Send Mail");
diag("Send Mail");

sub handle_client_input {
    my ( $heap, $input ) = @_[ HEAP, ARG0 ];

    if ($input =~ /^(ehlo|mail from:|rcpt to:|data|\.|quit)/i){
	$heap->{'client'}->put(shift @smtp_server_responses);
    }
}

sub handle_client_connect {
    $_[HEAP]->{'client'}->put(shift @smtp_server_responses);
}

sub handle_client_disconnect {
}

sub handle_client_error {
}

sub handle_client_flush {
}

sub client_start {
    $_[KERNEL]->yield("send_mail");
}

sub client_send_mail {

    POE::Component::Client::SMTP->send(
        smtp_server    => $server,
        smtp_port      => $port,
        smtp_sender    => $sender,
        smtp_recipient => $recipient,
        to             => "George",
        from           => "Georgel",
        subject        => "Hi Foo!",
        smtp_body      => $_[HEAP]->{'smtp_body'},
        smtp_timeout   => 1,
        debug          => 0,

        SMTPSendSuccessEvent => "smtp_success",
        SMTPSendFailureEvent => "smtp_error",
    );
}

sub client_smtp_success {
    $tests{'mail_send'} = 1;
}

sub client_smtp_error {
    $tests{'mail_send'} = 0;
}

sub client_stop {
    $_[KERNEL]->call( smtp_server => "shutdown" );
}

	
		
