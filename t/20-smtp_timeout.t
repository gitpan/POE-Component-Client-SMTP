#!perl -T
use strict;
use lib '../lib';

use IO::Socket::INET;

use POE qw(Wheel::ListenAccept Component::Server::TCP);

use POE::Component::Client::SMTP;

use Test::More tests => 1;

my %tests = { connect_timeout => 0 };

my $timeout   = 2;    # seconds
my $mail_body =
"Test mail, sent by POE::Component::Client::SMTP, version: $POE::Component::Client::SMTP::VERSION\n"
  . "at: "
  . localtime(time) . "\n"
  . "Please ignore, thank you.\n";

my $sender    = 'george@localhost';
my $recipient = 'george@localhost';
my $server    = 'localhost';
my $port      = 25252;

POE::Session->create(
    inline_states => {
        _start           => \&server_start,
        client_connected => \&client_connected,
        client_sf_error  => \&client_sf_error,
        test_end         => \&server_end,
        _stop            => \&server_stop,
    }
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
is( $tests{'connect_timeout'}, 1, "Handle Timeout at connection time" );
diag("Handle Timeout at connection time");

sub server_start {
    $_[HEAP]->{'wheels'}->{'sf'} = POE::Wheel::SocketFactory->new(
        BindAddress    => $server,
        BindPort       => $port,
        SuccessEvent   => "client_connected",
        FailureEvent   => "client_sf_error",
        SocketDomain   => AF_INET,
        SocketType     => SOCK_STREAM,
        SocketProtocol => 'tcp',
        ListenQueue    => SOMAXCONN,
        Reuse          => 'on',
    );

    # set a timeout in the server in case PoCoCl::SMTP "forgets" to disconnect
    $_[KERNEL]->delay_set( "test_end", ( $timeout * 2 ) );
}

sub client_connected {
    # got client connected, "forget" to send SMTP banner, and wait for PoCoCl::SMTP
    # to disconnect
    $_[HEAP]->{'wheels'}->{'rw'} = POE::Wheel::ReadWrite->new(
        Handle       => $_[ARG0],
        Filter       => POE::Filter::Line->new(),
        InputEvent   => sub { },
        ErrorEvent   => sub { },
        FlushedEvent => sub { },
    );
}

sub client_sf_error {
}

sub server_end {
    $_[KERNEL]->alarm_remove_all();
    # remove network connections
    $_[HEAP]->{'wheels'} = ();
}

sub server_stop {
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
        smtp_timeout   => $timeout,
        debug => 1,

        SMTPSendSuccessEvent => "smtp_success",
        SMTPSendFailureEvent => "smtp_error",
    );
}

sub client_smtp_success {
    warn "# THIS SHOULD HAVE NEVER SUCCEED!!!";
    $tests{'connect_timeout'} = 0;

}

sub client_smtp_error {
    my ( $error_code, $state ) = @_[ ARG0, ARG1 ];
    if ( $error_code == 4 ) {
        $tests{'connect_timeout'} = 1;
    }
    else {
        $tests{'connect_timeout'} = 0;
    }

}

sub client_stop {
}

