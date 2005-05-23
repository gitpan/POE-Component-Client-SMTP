package POE::Component::Client::SMTP;

use warnings;
use strict;

use Carp;
use Socket;
use POE qw(Wheel::SocketFactory Wheel::ReadWrite);
use Data::Dumper;

# references:
# RFC822 http://www.faqs.org/rfcs/rfc822.html
# RFC2821 http://www.faqs.org/rfcs/rfc2821.html
# RFC821 http://www.faqs.org/rfcs/rfc2821.html

=head1 NAME

POE::Component::Client::SMTP - The great new POE::Component::Client::SMTP!

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

sub EOL () { "\015\012" }

=head1 SYNOPSIS

    use POE::Component::Client::SMTP;

    POE::Component::Client::SMTP->send(
	alias		    => 'smtp_client',
	smtp_server	    => 'foo.bar.com',	# default localhost
	smtp_port	    => 25,		# default 25
	smtp_sender	    => 'foo@bar.com',	# will croak if emtpy
	smtp_recipient	    => 'foo@baz.com',	# will croak if empty
	to		    =>	"Foo Baz",	# defaults to smtp_recipient
	from		    =>	"Foo Bar",	# defaults to smtp_sender
	cc		    => ['a@foo.bar', 'b@foo.bar'],  # not implemented yet
	bcc		    => ['bcc1@bar.foo', 'bcc2@bar.foo'],    # not implemented yet
	subject		    => "Hi Foo!"	# defaults to "(none)"
	smtp_data	    =>	$ref_to_data,
	smtp_timeout	    => 30,		# seconds, defaults to 30
	debug               => 1,               # defaults to 0
	SMTPSendSuccessEvent => $success_event,
	SMTPSendFailureEvent => $failure_event,
    );

=head1 ABSTRACT

POE::Component::Client::SMTP can be used to send asynchronous e-mail messages while your POE program still does something else in the meantime.

Currently it doesn't support ESMTP features like sending mails trough an encrypted connection, honouring SMTP authentification or fancy stuff like this. It just sends electronic messages trough a SMTP daemon.

=head1 METHODS 

=head2 send

This method handles everything needed to send an email message (SMTP compliant, not ESMTP aware).

Arguments

=over

=item alias

The component's alias

=item smtp_server

SMTP server address; defaults to B<localhost>

=item smtp_port

SMTP server port; defaults to B<25>

=item smtp_sender

Email address from where the message originates; B<mandatory>

=item smtp_recipient

Email address for the message delivery; B<mandatory>

=item to

Recipient's name as it appears in the message's "To:" field; defaults to I<smtp_recipient>

=item from

Sender's name as it appears in the message's "From:" field; defaults to I<smtp_sender>

=item cc

Not implemented yet;

=item bcc

Not implemented yet;

=item subject

The subject of the message

=item smtp_data

The body of the message

=item SMTPSendSuccessEvent

Specify what event is to be sent back upon successful mail delivery

=item SMTPSendFailureEvent

Specify what event is to be sent back upon failure of mail delivery

=item smtp_timeout

Timeout to SMTP connection; defaults to B<30 seconds> (not implemented yet)

=item debug

Run in debug mode

=back

=head1 Events

PoCo::Client::SMTP sends two events: B<SMTPSendFailureEvent> and B<SMTPSendFailureEvent>.

=over

=item SMTPSendSuccessEvent

SMTPSendSuccessEvent is sent back to the session that spawned PoCo::Client::SMTP when the message is accepted by the SMTP server

=item SMTPSendFailureEvent

SMTPSendFailureEvent is sent back to the session that spawned PoCo::Client::SMTP when the message has not been delivered.

There are three main reasons for failure:

1) A connection could not be established in which case this event is sent along with three parameters (as received from: POE::Wheel::SocketFactory)

2) An error occured while network connection still active with the SMTP server in which case this event is sent along with three parameters (as received from POE::Wheel::ReadWrite)

3) An error occured while talking with the SMTP daemon; this means that a misunderstanding between PoCo::Client::SMTP and the SMTP server has occured; if you feel this shouldn't have happened, fill a bug report along with the session log.

If running in debug mode, you will receive not only the last line received from the server, but the entire SMTP session log.

=back

=head1 Note

Note that I<SMTPSendSuccessEvent> and I<SMTPSendFailureEvent> are relative to what the SMTP server tells us; even if the SMTP server accepts the message for delivery, this is not a guarantee that the message actually gets delivered.

=cut

sub send {

    my ( $class, $sender, %params, $alias );
    my (
        $smtp_sender, $smtp_recipient, $smtp_server,
        $smtp_port,     $smtp_data, $to,           $from, $subject,
        $cc,            $bcc,       $smtp_timeout, $debug,
        $success_event, $failure_event,

    );

    my $to_send;

    $class  = shift;
    $sender = $poe_kernel->get_active_session();

    %params = @_;

    # parameters initialization

    if ( !defined( $params{'alias'} ) ) {
        croak
"$class->send requires alias; please refer to $class's pod for details";
    }

    $alias = delete $params{'alias'};

    if ( !defined( $params{'smtp_sender'} ) ) {
        croak
"$class->send requires \"smtp_sender\"; please refer to $class's pod for details";
    }

    $smtp_sender = delete $params{'smtp_sender'};

    if ( !defined( $params{'smtp_recipient'} ) ) {
        croak
"$class->send requires \"smtp_recipient\"; please refer to $class's pod for details";
    }

    $smtp_recipient = $params{'smtp_recipient'};

    $smtp_server = delete $params{'smtp_server'} || 'localhost';

    $smtp_port = delete $params{'smtp_port'} || 25;

    $smtp_data = delete $params{'smtp_data'}
      || "i've just forgot to write DATA!";

    if ( defined( $params{'to'} ) ) {
        $to = delete $params{'to'};
	$to.="< $smtp_recipient >";
    }
    else {
	$to = $smtp_recipient;
    }

    if ( defined( $params{'from'} ) ) {
        $from = delete $params{'from'};
	$from.= "< $smtp_sender >";
    }else{
        $from = $smtp_sender;
    }

    $subject = delete $params{'subject'} || "(none)";

    if ( !defined( $params{'SMTPSendSuccessEvent'} ) ) {
        croak
"$class->send requires \"SMTPSendSuccessEvent\"; please refer to $class's pod for details";
    }
    $success_event = delete $params{'SMTPSendSuccessEvent'};

    if ( !defined( $params{'SMTPSendFailureEvent'} ) ) {
        croak
"$class->send requires \"SMTPSendFailureEvent\"; please refer to $class's pod for details";
    }

    $failure_event = delete $params{'SMTPSendFailureEvent'};

    $smtp_timeout = delete $params{'smtp_timeout'} || 30;

    $debug = delete $params{'debug'} || 0;

    $to_send = [
        'HELO POE::Component::Client::SMTP',
        'MAIL FROM: <' . $smtp_sender . '>',
        'RCPT TO: <' . $smtp_recipient . '>',
        "DATA",
        "To: $to"
          . EOL()
          . "From: $from"
          . EOL()
          . "Subject: $subject"
          . EOL()
          . "Date: "
          . rfc_822_date()
          . EOL()
          . "User-Agent: POE::Component::Client::SMTP v$VERSION"
          . EOL()
          . EOL()
          . $$smtp_data
          . EOL() . ".",
        "QUIT",
    ];

    # session
    POE::Session->create(
        inline_states => {
            _start               => \&client_start,
            smtp_connect_success =>
              \&smtp_connect_success,    # connection to SMTP succeeded
            smtp_connect_error =>
              \&smtp_connect_error,      # connection to SMTP failed
            smtp_session_input =>
              \&smtp_session_input,      # reveived data from SMTP server

            smtp_session_error => \&smtp_connect_error,
            smtp_message_sent  => \&smtp_message_sent,    # yupii, message sent
            smtp_message_error =>
              \&smtp_message_error,    # Houston we've got a BUG!
            _stop => \&client_stop,
        },

        heap => {
            alias          => $alias,             # PoCo::Client::SMTP alias
            sender         => $sender,            # SENDER
            smtp_server    => $smtp_server,       # SMTP Server we connect to
            smtp_port      => $smtp_port,         # SMTP Port
            smtp_recipient => $smtp_recipient,    # Recipient address
            smtp_sender    => $smtp_sender,
            to             => $to,
            from           => $from,
            subject        => $subject,
            smtp_data      => $smtp_data,
            smtp_session_data => "",         # here is stored the session's data
            smtp_to_send      => $to_send,
            smtp_timeout => $smtp_timeout,
            debug        => $debug,
            smtp_success => $success_event,    # Event to send back upon success
            smtp_failure => $failure_event,    # Event to send back upon error
        },
    );
}

# _start event
sub client_start {
    my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];

    $heap->{sock_wheel} = POE::Wheel::SocketFactory->new(
        RemoteAddress  => $heap->{'smtp_server'},
        RemotePort     => $heap->{'smtp_port'},
        SuccessEvent   => "smtp_connect_success",
        FailureEvent   => "smtp_connect_error",
        SocketDomain   => AF_INET,
        SocketType     => SOCK_STREAM,
        SocketProtocol => 'tcp',
        Reuse          => 'yes',
    );

    # set alias
    $kernel->alias_set( $heap->{'alias'} );
}

# smtp_connect_success event
sub smtp_connect_success {

    # here's the meat ;-)
    my ( $kernel, $heap, $socket ) = @_[ KERNEL, HEAP, ARG0 ];

    $heap->{'rw_wheel'} = POE::Wheel::ReadWrite->new(
        Handle     => $socket,
        Filter     => POE::Filter::Line->new(),
        InputEvent => 'smtp_session_input',
        ErrorEvent => 'smtp_session_error',
    );
}

# smtp_connect_error
sub smtp_connect_error {
    my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];
    my @sf = @_[ ARG0 .. ARG3 ];

    # send the error back
    $kernel->post( $heap->{'sender'}, $heap->{'smtp_failure'}, @sf );
    smtp_component_destroy();
}

# smtp_session_input event

sub smtp_session_input {

    # http://www.faqs.org/rfcs/rfc821.html
    my ( $kernel, $heap, $input, $wheel_id ) = @_[ KERNEL, HEAP, ARG0, ARG1 ];
    my $to_send = shift @{ $heap->{'smtp_to_send'} },

      $heap->{'smtp_session_data'} .= "$input\n";
    $heap->{'smtp_session_data'} .= "$to_send\n" if ( defined($to_send) );

    if ( $input =~ /^\s*221/ ) {
        $kernel->yield("smtp_message_sent");
    }
    elsif ( $input =~ /^\s*2|^\s*354/ ) {

        # ok answer, put the data on the wire
        $heap->{'rw_wheel'}->put($to_send);
    }
    elsif ( $input =~ /^\s*4/ ) {
        $kernel->yield( "smtp_message_error", "$input" );

        # error
    }
    elsif ( $input =~ /^\s*5/ ) {
        $kernel->yield( "smtp_message_error", "$input" );

        # error
    }
    else {
        $kernel->yield( "smtp_message_error", "$input" );

        # THIS IS A BUG!
    }
}

sub smtp_message_sent {

    # notify the caller we have successfuly delivered the message
    # and clean up
    my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];

    $kernel->post( $heap->{'sender'}, $heap->{'smtp_success'} );
    smtp_component_destroy();
}

sub smtp_message_error {
    my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];
    my $input;

    if ( $heap->{'debug'} ) {
        $input = $heap->{'smtp_session_data'};
    }
    else {
        $input = $_[ARG0];
    }
    $kernel->post( $heap->{'sender'}, $heap->{'smtp_failure'}, [$input] );
    smtp_component_destroy();

}

sub smtp_component_destroy {
    my $heap = $poe_kernel->get_active_session()->get_heap();
    $poe_kernel->alias_remove( $heap->{'alias'} );
    delete $heap->{'rw_wheel'};
    delete $heap->{'sock_wheel'};
}

# _stop event
sub client_stop {
}

sub rfc_822_date {
    my @month = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
    my @day   = qw(Sun Mon Tue Wed Thu Fri Sat);
    my ( $sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst ) =
      gmtime(time);
    my $date;
    $year += 1900;
    $date = "$day[$wday], $mday $month[$mon] $year $hour:$min:$sec GMT";
    return $date;
}

=head1 EXAMPLE

 ...

 POE::Session->create(
   ...
   
     SMTP_Send_Success_Event => \&smtp_success,
     SMTP_Send_Failure_Event => \&smtp_failure,

   ...
   
 );

 ...

 $data = "Here is the info I want to send you:";
 $data .= "1 2 3 4 5 6";
 
 ...

 POE::Component::Client::SMTP->send(
    alias => 'smtp_client',
    smtp_server         => 'mail-host.foo.bar',
    smtp_port           => 25,
    smtp_sender         => 'me@foo.bar',
    smtp_recipient      => 'my_girlfriend@baz.com',
    from		=> "My Name Here",
    to                  => "The Girls's Name",
    subject             => "I've just did your homework",
    smtp_data           =>  \$data,
    SMTPSendSuccessEvent => 'SMTP_Send_Success_Event',
    SMTPSendFailureEvent => 'SMTP_Send_Failure_Event',
 );

 ...
 
 sub smtp_success{
    Logger->log("MAIL sent successfully ");
    # do something useful here ...
 }

 sub smtp_failure{
    # Oops
    
    Logger->log("MAIL sending failed");
    
    my ($er, $er1, $er2) = @_[ARG0 .. ARG3];

    if (!defined ($er1) ){
	Logger->log("Error during SMTP talk");
    }else{
	Logger->log("Error ducing SMTP connecton");
    }
 } 

=head1 BUGS

* Beware that the interface can be changed in the future!

* Currently there is no timeout checking for established connections; so the PoCo::Client::SMTP may hang if it doesn't receive proper response from the SMTP::Server 

Please report any bugs or feature requests to
C<bug-poe-component-client-smtp@rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=POE-Component-Client-SMTP>.
I will be notified, and then you'll automatically be notified of progress on
your bug as I make changes.

=head1 CAVEATS

Values given to send() are minimally checked.

=head1 ACKNOWLEDGEMENTS

=head1 TODO

* piping support thru sendmail binary

* add support for ESTMP (maybe a derivate class? like: POE::Component::Client::SMTP::Extended)

* add timeout for network operations

* freeze the interface

=head1 SEE ALSO

POE::Kernel, POE::Session, POE::Component, POE::Wheel::SocketFactory, POE::Wheel::ReadWrite

=head1 AUTHOR

George Nistorica, C<< <george@nistorica.ro> >>

=head1 COPYRIGHT & LICENSE

Copyright 2005 George Nistorica, All Rights Reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

1;    # End of POE::Component::Client::SMTP
