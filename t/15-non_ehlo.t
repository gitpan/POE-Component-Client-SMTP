#!perl -T
# test if the module does the right thing when a SMTP server does not recognize EHLO command
# (the module should send HELO and continue the SMTP session)
use strict;
use lib '../lib';

use IO::Socket::INET;

use POE qw(Wheel::ListenAccept Component::Server::TCP);

use POE::Component::Client::SMTP;

use Test::More tests => 3;

my %tests = {
    non_ehlo         => 0,
    service_shutdown => 0,
    is_failed        => 0,
};

my $shutdown = 0;

my $mail_body =
"Test mail, sent by POE::Component::Client::SMTP, version: $POE::Component::Client::SMTP::VERSION\n"
  . "at: "
  . localtime(time) . "\n"
  . "Please ignore, thank you.\n";

my $sender    = 'george@localhost';
my $recipient = 'george@localhost';
my $server    = 'localhost';
my $port      = 2525;

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

    # Optionally define other states for the client session.
    #           InlineStates  => { ... },
    #           PackageStates => [ ... ],
    #           ObjectStates  => [ ... ],
);

POE::Session->create(
    inline_states => {
        _start       => \&client_start,
        send_mail    => \&client_send_mail,
        smtp_success => \&client_smtp_success,
        smtp_error   => \&client_smtp_error,
        _stop        => \&client_stop,
    },
    heap => { smtp_body => \$mail_body, },
);

POE::Kernel->run();
is( $tests{'non_ehlo'},         1, "Handle Non EHLO SMTP Server" );
diag("Handling non-ehlo servers");
is( $tests{'service_shutdown'}, 1, "Handle Forced SMTP Shutdown" );
diag("Handling server shutdown");
is( $tests{'is_failed'},        1, "Check if client emits error event!" );
diag("Test sending mail result");

sub handle_client_input {
    my ( $heap, $input ) = @_[ HEAP, ARG0 ];

    if ( $input =~ /ehlo/io ) {
        $heap->{'client'}->put("500 Syntax error, command unrecognized");
    }
    elsif ( $input =~ /helo|hello/io ) {
        $tests{'non_ehlo'} = 1;
        $heap->{'client'}->put(
            "421 <domain> Service not available, closing transmission channel");
        $shutdown = 1;
    }
}

sub handle_client_connect {
    $_[HEAP]->{'client'}->put("220 localhost $0");
}

sub handle_client_disconnect {
    if ($shutdown) {
        $tests{'service_shutdown'} = 1;
    }
}

sub handle_client_error {
    if ($shutdown) {
        $tests{'service_shutdown'} = 1;
    }
}

sub handle_client_flush {
}

sub error_handler {
    my ($syscall_name, $error_number, $error_string) = @_[ARG0, ARG1, ARG2];
    diag("Error spawning POE::Component::Server::TCP, syscall: $syscall_name, err_no: $error_number, err_string: $error_string");
}


sub client_start {
    $_[KERNEL]->yield("send_mail");
}

sub client_send_mail {

    POE::Component::Client::SMTP->send(
        alias          => 'smtp_client',
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
    warn "# THIS SHOULD HAVE NEVER SUCCEED!!!";
    $tests{'is_failed'} = 1;
}

sub client_smtp_error {
    $tests{'is_failed'} = 1;
}

sub client_stop {
    $_[KERNEL]->call( smtp_server => "shutdown" );
}

# vim: ft=apache sw=4 ts=4
	
		
