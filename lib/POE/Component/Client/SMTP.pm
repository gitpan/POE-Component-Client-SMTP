package POE::Component::Client::SMTP;

use warnings;
use strict;

use Carp;
use Socket;
use Data::Dumper;
use POE qw(Wheel::SocketFactory Wheel::ReadWrite Filter::Stream);

# references:
# RFC822 http://www.faqs.org/rfcs/rfc822.html
# RFC2821 http://www.faqs.org/rfcs/rfc2821.html obsoletes
# RFC821 http://www.faqs.org/rfcs/rfc821.html

our $VERSION = '0.06';

# octal
my $EOL = "\015\012";

# Mighty Method to shoot the message
sub send {

    my ( $class, $sender, %params, $alias );
    my (
        $smtp_sender, $smtp_recipient, $smtp_server, $smtp_ehlo,
        $smtp_port,$smtp_bind_address,     $smtp_body, $smtp_data,    $to, $from, $subject,
        $cc,            $bcc,       $smtp_timeout, $debug,
        $success_event, $failure_event,

    );

    # hash containing server response, client request pairs
    # key -> server code; value -> what client responds to that SMTP code
    my %smtp_state;

    # server may respond 250 for multiple requests. this array helps keeping
    # track of where we are (obviously when receiving a 250 code from server)
    my @session_state;

   # this array contains "lines" of the email message
   # (don't want to send it all on the wire, but chunks of the message, then let
   # POE::Kernel give time to other "threads"
    my @mail_body;

    # my class name
    $class = shift;

    # caller, so we know where to send back the SMTP session results
    $sender = $poe_kernel->get_active_session();

    # fetch the parameters we received from user
    %params = @_;

    # parameters initialization

    # ALIAS

    $alias = delete $params{'alias'};

    # SMTP SENDER
    if ( !defined( $params{'smtp_sender'} ) ) {
        croak
"$class->send requires \"smtp_sender\"; please refer to $class's pod for details";
    }

    $smtp_sender = delete $params{'smtp_sender'};

    # SMTP RECIPIENT
    if ( !defined( $params{'smtp_recipient'} ) ) {
        croak
"$class->send requires \"smtp_recipient\"; please refer to $class's pod for details";
    }

    $smtp_recipient = $params{'smtp_recipient'};

    # SMTP SERVER
    $smtp_server = delete $params{'smtp_server'} || 'localhost';

    # SMTP EHLO
    $smtp_ehlo = delete $params{'smtp_ehlo'} || 'localhost';

    # SMTP PORT
    $smtp_port = delete $params{'smtp_port'} || 25;

    $smtp_bind_address = delete $params{'smtp_bind_address'};

    if ( defined( $params{'smtp_body'} ) ) {

        # SMTP DATA
        $smtp_body = delete $params{'smtp_body'}
          || "i've just forgot to write DATA!";

        if ( ref($smtp_body) eq 'SCALAR' ) {
            my @tmp = split /\r\n/, $$smtp_body;
            for ( 0 .. $#tmp ) {
                push @mail_body, split /\r|\n/, $tmp[$_];
            }
        }
        elsif ( ref($smtp_body) eq 'ARRAY' ) {
            @mail_body = @{$smtp_body};
        }
        else {
            croak
              "$class->send requires \$smtp_body to be a scalar or array ref";
        }

        # TO:
        if ( defined( $params{'to'} ) ) {
            $to = delete $params{'to'};
            $to .= " <$smtp_recipient>";
        }
        else {
            $to = $smtp_recipient;
        }

        # FROM:
        if ( defined( $params{'from'} ) ) {
            $from = delete $params{'from'};
            $from .= " <$smtp_sender>";
        }
        else {
            $from = $smtp_sender;
        }

        # SUBJECT:
        $subject = delete $params{'subject'} || "(none)";

        $smtp_state{'354'} =
          _add_mail_headers( \@mail_body, $to, $from, $subject );
    }
    else {
        $smtp_data = delete $params{'smtp_data'};
        my @tmp = split /\r\n/, $$smtp_data;
        for ( 0 .. $#tmp ) {
            push @mail_body, split /\r|\n/, $tmp[$_];
        }
        push @mail_body, ".";
        $smtp_state{'354'} = \@mail_body;
    }

    # EVENTS
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

    # SMTP TIMEOUT
    $smtp_timeout = delete $params{'smtp_timeout'} || 30;

    # DEBUG
    $debug = delete $params{'debug'} || 0;

    # ASSEMBLE SMTP STATES
    $smtp_state{'220'}         = "EHLO $smtp_ehlo";
    $smtp_state{'554'}         = 'QUIT';
    $smtp_state{'250'}{'ehlo'} = "MAIL FROM: <$smtp_sender>";
    $smtp_state{'500'}         = $smtp_state{'501'} = $smtp_state{'502'} =
      "HELO $smtp_ehlo";
    $smtp_state{'250'}{'mail_from'} = "RCPT TO: <$smtp_recipient>";
    $smtp_state{'551'} = $smtp_state{'550'} = 'QUIT';
    $smtp_state{'250'}{'rcpt_to'} = $smtp_state{'251'} = "DATA";

#    $smtp_state{'354'} = _add_mail_headers( \@mail_body, $to, $from, $subject );
    $smtp_state{'250'}{'data'} = "QUIT";
    $smtp_state{'221'} = "";    # the server ends connection

    # ASSEMMBLE 250 code states
    @session_state = qw(
      conn_accepted
      ehlo
      mail_from
      rcpt_to
      data
    );

    # session
    POE::Session->create(
        inline_states => {
            _start               => \&_client_start,
            smtp_connect_success =>
              \&_smtp_connect_success,    # connection to SMTP succeeded
            smtp_connect_error =>
              \&_smtp_connect_error,      # connection to SMTP failed
            smtp_session_input =>
              \&_smtp_session_input,      # reveived data from SMTP server
            smtp_session_error => \&_smtp_session_error,
            smtp_timeout_event => \&_smtp_timeout_handler,

            # SMTP events as sent by server here
            event_220 => \&_handler_220,
            event_250 => \&_handler_250,
            event_251 => \&_handler_251,
            send_more => \&_handler_354,
            event_354 => \&_handler_354,
            event_221 => \&_handler_221,
            event_421 => \&_handler_421,

            event_500 => \&_handler_non_ehlo,
            event_501 => \&_handler_non_ehlo,
            event_502 => \&_handler_non_ehlo,

            # codes: 554, 551, 550, and others
            _default => \&_handler_error_code,
            _stop    => \&_client_stop,
        },

        heap => {
            alias         => $alias,           # PoCo::Client::SMTP alias
            sender        => $sender,          # SENDER
            smtp_server   => $smtp_server,     # SMTP Server we connect to
            smtp_port     => $smtp_port,       # SMTP Port
	    smtp_bind_address => $smtp_bind_address, # Address to bind
            smtp_timeout  => $smtp_timeout,
            debug         => $debug,
            smtp_success  => $success_event,   # Event to send back upon success
            smtp_failure  => $failure_event,   # Event to send back upon error
            smtp_state    => \%smtp_state,
            session_state => \@session_state,

  # error codes as documented in the docs
  # if there are discrepancies between what's below and the docs, THIS IS A BUG!
            error_codes => {
                smtp_talk_error    => 1,
                smtp_connect_error => 2,
                smtp_session_error => 3,
                smtp_timeout       => 4,
            },
        },
    );
}

# _start
# client start
sub _client_start {
    my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];
    my %sf = (
        RemoteAddress  => $heap->{'smtp_server'},
        RemotePort     => $heap->{'smtp_port'},
        SuccessEvent   => "smtp_connect_success",
        FailureEvent   => "smtp_connect_error",
        SocketDomain   => AF_INET,
        SocketType     => SOCK_STREAM,
        SocketProtocol => 'tcp',
        Reuse          => 'yes',
    );
    $sf{'BindAddress'} = $heap->{'smtp_bind_address'} if ( defined( $heap->{'smtp_bind_address'} ) );

    $heap->{'wheels'}->{'sf'} = POE::Wheel::SocketFactory->new(
	%sf,
    );

    # set alias
    if ( $heap->{'alias'} ) {
        $kernel->alias_set( $heap->{'alias'} );
    } else {
	$kernel->refcount_increment( $kernel->get_active_session()->ID() => __PACKAGE__ );
    }

    # set alarm too
    $heap->{'alarm'} =
      $kernel->delay_set( "smtp_timeout_event", $heap->{'smtp_timeout'} );
    $heap->{'sessid'} = $kernel->get_active_session()->ID();
}

# smtp_connect_success
# SocketFactory got connected, cool
sub _smtp_connect_success {

    # here's the meat ;-)
    my ( $kernel, $heap, $socket ) = @_[ KERNEL, HEAP, ARG0 ];

    $heap->{'wheels'}->{'rw'} = POE::Wheel::ReadWrite->new(
        Handle       => $socket,
        InputFilter  => POE::Filter::Line->new( Literal => $EOL ),
        OutputFilter => POE::Filter::Stream->new(),
        InputEvent   => 'smtp_session_input',
        ErrorEvent   => 'smtp_session_error',
    );
}

# smtp_connect_error
sub _smtp_connect_error {
    my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];
    my @sf = @_[ ARG0 .. ARG3 ];

    # send the error back
    $kernel->post(
        $heap->{'sender'},
        $heap->{'smtp_failure'},
        $heap->{'error_codes'}->{'smtp_connect_error'}, @sf
    );
    _smtp_component_destroy();
}

sub _smtp_timeout_handler {
    my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];
    $kernel->post(
        $heap->{'sender'},
        $heap->{'smtp_failure'},
        $heap->{'error_codes'}->{'smtp_timeout'},
        shift @{ $heap->{'session_state'} }
    );
    _smtp_component_destroy();
}

# smtp_session_input event
# this routine parses what SMTP server says (line by line) and dispatches the appropiate
# event to be handled by a routine dedicated to that speciffic SMTP server response
# Server responses should like this: "XXX optional text hereEOL" or
#                                    "XXX-optional text hereEOL" in case of EHLO command;
# this way the server advertises its ESMTP capabilities

sub _smtp_session_input {
    my ( $kernel, $heap, $input, $wheel_id ) = @_[ KERNEL, HEAP, ARG0, ARG1 ];
    my $event;

    $kernel->delay_adjust( $heap->{'alarm'}, $heap->{'smtp_timeout'} );
    if ( $input =~ /^(\d{3})\s+(.*)$/ ) {
        $heap->{'debug'} and warn "PoCoClSMTP: $heap->{'sessid'} RECEIVED FROM SERVER: $input";
        $heap->{'debug'} and warn "PoCoClSMTP: $heap->{'sessid'} DISPATCH EVENT      : $1";
        $kernel->yield( "event_$1", $1, $2 );
    }
    elsif ( $input =~ /^(\d{3})\-(.*)$/ ) {

        # nothing
    }
    else {

        # here nothing should go
        if ( $heap->{'debug'} ) {
            warn
"PoCoClSMTP: $heap->{'sessid'} SMTP Server sent us a message we can't parse, is the server RFC compliant?!";
            warn "Here's what server said: \"$input\"";
        }
    }

}

sub _handler_250 {
    my ( $kernel, $heap, $code, $message ) = @_[ KERNEL, HEAP, ARG0, ARG1 ];

    $kernel->delay_adjust( $heap->{'alarm'}, $heap->{'smtp_timeout'} );
    my $state = shift @{ $heap->{'session_state'} };
    $heap->{'debug'}
      and warn " PoCoClSMTP: $heap->{'sessid'} SENDING TO SERVER   : " . $heap->{'smtp_state'}{$code}{$state};
    $heap->{'wheels'}->{'rw'}
      ->put( $heap->{'smtp_state'}{$code}{$state} . $EOL );
}

# handle SMTP command, DATA
sub _handler_354 {
    my ( $kernel, $heap, $code, $message ) = @_[ KERNEL, HEAP, ARG0, ARG1 ];
    my $line;

    if ( ref( $heap->{'smtp_state'}{$code} ) eq 'ARRAY' ) {

        # extract another line to be put on the wire
        $line = shift @{ $heap->{'smtp_state'}{$code} };
    }
    else {
        if ( defined( $heap->{'smtp_state'}{$code} ) ) {
            $line = ${ $heap->{'smtp_state'}{$code} };

            #	    $line =~ s/\r|\n/$EOL/;
            $line .= "$EOL.";
        }

        $heap->{'smtp_state'}{$code} = undef;
    }

    $kernel->delay_adjust( $heap->{'alarm'}, $heap->{'smtp_timeout'} );
    if ( defined($line) ) {
        $heap->{'debug'} and warn "PoCoClSMTP: $heap->{'sessid'} SENDING TO SERVER   : $line";
        $heap->{'wheels'}->{'rw'}->put( $line . "$EOL" );
        $kernel->yield( "send_more", $code, $message );
    }
}

sub _handler_221 {
    my ( $kernel, $heap ) = @_[ KERNEL, HEAP, ARG0, ARG1 ];

    $kernel->delay_adjust( $heap->{'alarm'}, $heap->{'smtp_timeout'} );
    if ( exists( $heap->{'error'} ) ) {
        $heap->{'debug'} and warn "PoCoClSMTP: $heap->{'sessid'} Closing connection to server, error";
        $kernel->post(
            $heap->{'sender'},
            $heap->{'smtp_failure'},
            $heap->{'error_codes'}->{'smtp_talk_error'},
            $heap->{'error_code'},
            $heap->{'error_message'},
        );
    }
    else {
        $heap->{'debug'} and warn "PoCoClSMTP: $heap->{'sessid'} closing connection";
        $kernel->post( $heap->{'sender'}, $heap->{'smtp_success'}, );
    }
    _smtp_component_destroy();
}

# SMTP server shutdown
sub _handler_421 {
    my ( $kernel, $heap, $code, $message ) = @_[ KERNEL, HEAP, ARG0, ARG1 ];

    $kernel->alarm_remove( $heap->{'alarm'} );

    # don't send any quit command, just call the handler
    $heap->{'error'}{'error_code'}    = $code;
    $heap->{'error'}{'error_message'} = $message;
    $kernel->yield("event_221");
}

sub _handler_220 {

    # server sayd go ahead
    my ( $kernel, $heap, $code, $message ) = @_[ KERNEL, HEAP, ARG0, ARG1 ];

    $kernel->delay_adjust( $heap->{'alarm'}, $heap->{'smtp_timeout'} );
    shift @{ $heap->{'session_state'} };
    $heap->{'debug'}
      and warn "PoCoClSMTP: $heap->{'sessid'} SENDING TO SERVER   : " . $heap->{'smtp_state'}{$code};
    $heap->{'wheels'}->{'rw'}->put( $heap->{'smtp_state'}{$code} . "$EOL" );
}

sub _handler_non_ehlo {
    my ( $kernel, $heap, $code, $message ) = @_[ KERNEL, HEAP, ARG0, ARG1 ];

    $kernel->delay_adjust( $heap->{'alarm'}, $heap->{'smtp_timeout'} );
    $heap->{'debug'}
      and warn "PoCoClSMTP: $heap->{'sessid'} SENDING TO SERVER   : " . $heap->{'smtp_state'}{$code};
    $heap->{'wheels'}->{'rw'}->put( $heap->{'smtp_state'}{$code} . "$EOL" );
}

sub _handler_error_code {

    # codes: 554, 551, 550,
    my ( $kernel, $heap, $code, $message ) = @_[ KERNEL, HEAP, ARG0, ARG1 ];

    $kernel->alarm_remove( $heap->{'alarm'} );
    $heap->{'wheels'}->{'rw'}->put( 'QUIT' . "$EOL" );
    $heap->{'error'}{'error_code'}    = $code;
    $heap->{'error'}{'error_message'} = $message;
}

# smtp_session_error
sub _smtp_session_error {
    my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];
    my @sf = @_[ ARG0 .. ARG3 ];

    $heap->{'debug'} and warn "PoCoClSMTP: $heap->{'sessid'} Wheel returned an error";
    $kernel->alarm_remove( $heap->{'alarm'} );

    # send the error back
    $kernel->post(
        $heap->{'sender'},
        $heap->{'smtp_failure'},
        $heap->{'error_codes'}->{'smtp_session_error'}, @sf
    );
    _smtp_component_destroy();
}

sub _smtp_component_destroy {
    my $heap = $poe_kernel->get_active_session()->get_heap();

    if ( $heap->{'alias'} ) {
    	$poe_kernel->alias_remove( $heap->{'alias'} );
    } else {
	$poe_kernel->refcount_decrement( $poe_kernel->get_active_session()->ID() => __PACKAGE__ );
    }
    $poe_kernel->alarm_remove_all();
    delete $heap->{'wheels'}->{'rw'};
    delete $heap->{'wheels'}->{'sf'};
}

# _stop event
sub _client_stop {

    # anything useful here?

}

sub _rfc_822_date {
    my @month = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
    my @day   = qw(Sun Mon Tue Wed Thu Fri Sat);
    my ( $sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst ) =
      gmtime(time);
    my $date;
    $year += 1900;
    $date = "$day[$wday], $mday $month[$mon] $year $hour:$min:$sec GMT";
    return $date;
}

sub _add_mail_headers {
    my $mail_body = shift;
    my $to        = shift;
    my $from      = shift;
    my $subject   = shift;

    @{$mail_body} = (
        "To: $to",
        "From: $from",
        "Subject: $subject",
        "Date: " . _rfc_822_date(),
        "User-Agent: POE::Component::Client::SMTP v$VERSION",
        "",
        @{$mail_body},
        "$EOL."
    );

    return $mail_body;

}

=pod 

=head1 NAME

POE::Component::Client::SMTP - Sending emails using POE

=head1 VERSION

Version 0.06

=head1 SYNOPSIS

    use POE::Component::Client::SMTP;

    POE::Component::Client::SMTP->send(
        alias               => 'smtp_client',   # optional
        smtp_sender         => 'foo@bar.com',   # will croak if emtpy
        smtp_recipient      => 'foo@baz.com',   # will croak if empty
        smtp_data           =>  $ref_to_scalar,
        smtp_timeout        => 30,              # seconds, defaults to 30
        debug               => 1,               # defaults to 0
        SMTPSendSuccessEvent => $success_event,
        SMTPSendFailureEvent => $failure_event,
    );

=head1 DESCRIPTION

POE::Component::Client::SMTP can be used to send asynchronous e-mail messages while your POE program still does something else in the meantime.

Currently it doesn't support ESMTP features like sending mails trough an encrypted connection, honouring SMTP authentification or fancy stuff like this. It just sends electronic messages trough a SMTP daemon.

=head1 METHODS

=head2 send

This method handles everything needed to send an email message (SMTP compliant, not ESMTP aware).

Arguments

=over

=item alias

The component's alias. This is optional.

=item smtp_server

SMTP server address; defaults to B<localhost>

=item smtp_ehlo

Message to be appended to the EHLO/HELO command; defaults to 'localhost'

=item smtp_port

SMTP server port; defaults to B<25>

=item smtp_bind_address

Parameter to be passed to POE::Wheel::SocketFactory as the BindAdress attribute.

=item smtp_sender

Email address from where the message originates; This option is B<mandatory>

=item smtp_recipient

Email address for the message delivery; This option is B<mandatory>

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

=item smtp_body

The body of the message; must be a ref to a scalar or an array.

=item smtp_data

Scalar ref to the entire message, constructed outside the module; i.e. using a helper module like Email::MIME::Creator or MIME::Lite

Using this parameter results in ignoring POE::Component::Client::SMTP's parameters: I<to, from, subject>

B<Note:> that your POE program will block during the MIME creation.

=item SMTPSendSuccessEvent

Specify what event is to be sent back upon successful mail delivery

=item SMTPSendFailureEvent

Specify what event is to be sent back upon failure of mail delivery

=item smtp_timeout

Timeout to SMTP connection; defaults to B<30 seconds>

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

1) A connection could not be established

2) An error occured while network connection still active with the SMTP server

3) An error occured while talking with the SMTP daemon; this means that a misunderstanding between PoCo::Client::SMTP and the SMTP server has occured; if y
ou feel this shouldn't have happened, fill a bug report along with the session log.

The SMTPSendFailureEvent handler receives the following parameters:

=over

=item *

If ARG0 has a value of 1, then the error occured because of a SMTP session failure

In this case, ARG1 contains the SMTP numeric code, ARG2 contains a string message giving a short explanation of the error.

=item *

If ARG0 has a value of 2, then the error occured because of a network failure 

In this case, ARG1, ARG2, and ARG3 have the values as returned by POE::Wheel::SocketFactory 

=item *

If ARG0 has a value of 3, then the error occured because of a network failure

In this case, ARG1, ARG2, and ARG3 have the values as returned by POE::Wheel::ReadWrite

=item *

If ARG0 has a value of 4, then the error occured because a timeout

In this case, ARG1 holds the SMTP state the PoCoCl::SMTP is while timeouting

=back

If running in debug mode, you will receive not only the last line received from the server, but the entire SMTP session log.

=back

=head1 Examples

 # Send an email, having an attachments

 my $mail_body = create_message();

 POE::Session->create(
     inline_states => {
         _start       => \&start,
         send_mail    => \&send_mail,
         smtp_success => \&smtp_success,
         smtp_error   => \&smtp_error,
         _stop        => \&stop,
     },
     heap => { smtp_data => \$mail_body, },
 );
 
 POE::Kernel->run();
 
 sub start {
     $_[KERNEL]->yield("send_mail");
 }
 
 sub send_mail {
     POE::Component::Client::SMTP->send(
         alias          => 'smtp_client',
         smtp_server    => $server,
         smtp_port      => $port,
         smtp_sender    => $sender,
         smtp_recipient => $recipient,
         smtp_data      => $_[HEAP]->{'smtp_data'},
         smtp_timeout   => 10,
         debug          => 2,
 
         SMTPSendSuccessEvent => "smtp_success",
         SMTPSendFailureEvent => "smtp_error",
     );
 }

 sub create_message {
     my @parts;
     my $email;
     my $message;
 
     @parts = (
         Email::MIME->create(
             attributes => {
                 content_type => "text/plain",
                 disposition  => "attachment",
                 charset      => "US-ASCII",
             },
             body => "Hello there!",
         ),
 
         Email::MIME->create(
             attributes => {
                 filename     => 'picture.jpg',
                 content_type => "image/jpg",
                 encoding     => "quoted-printable",
                 name         => "Nokia.jpg",
             },
             # BLOCKING!
             body => io('picture.jpg')->all,
         ),
     );
 
     $email = Email::MIME->create(
         header => [ From => 'ultradm@cpan.org' ],
         parts  => [@parts],
         charset => "UTF-8",
     );
     $email->header_set('Date' => 'Thu, 23 Jun 2005 8:18:35 GMT');
 
     return $email->as_string;
 
 }

 # No use of external modules
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
    smtp_body           =>  \$data,
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
    
    my $err_type = @_[ARG0];

    if ( $err_type eq == 1 ){
	my $error_code = @_[ARG1];
        my $error_message = @_[ARG2];
        Logger->log( "Received: [$err_code] $error_message from the server" );
    }elsif ( $err_type == 2 ) {
	
        ...

    }
 } 

=head1 Note

Note that I<SMTPSendSuccessEvent> and I<SMTPSendFailureEvent> are relative to what the SMTP server tells us; even if the SMTP server accepts the message fo
r delivery, it is not guaranteed that the message actually gets delivered. In case an error occurs after the SMTP server accepted the message, an error mes
sage will be sent back to the sender.

=head1 BUGS

* Beware that the interface can be changed in the future!

Please report any bugs or feature requests to
C<bug-poe-component-client-smtp@rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=POE-Component-Client-SMTP>.
I will be notified, and then you'll automatically be notified of progress on
your bug as I make changes.

=head1 CAVEATS

Values given to send() are minimally checked.

The module assumes that the given I<smtp_server> is a relay or the target server. This doesn't conform to the RFC 2821.

The MIME creation is left to an external module of your own choice. This means that the process will block until the attachment(s) is (are) slurped from the disk.

=head1 ACKNOWLEDGEMENTS

Thanks to Mike Schroeder for giving me some good ideas about PoCoClSMTP enhancements.

=head1 TODO

See the TODO file in the distribution.

=head1 Changes

See the Changes file in the distribution.

=head1 SEE ALSO

POE::Kernel, POE::Session, POE::Component, POE::Wheel::SocketFactory, POE::Wheel::ReadWrite

RFC 2821

=head1 AUTHOR

George Nistorica, C<< ultradm@cpan.org >>

=head1 COPYRIGHT & LICENSE

Copyright 2005 George Nistorica, All Rights Reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

1;    # End of POE::Component::Client::SMTP
