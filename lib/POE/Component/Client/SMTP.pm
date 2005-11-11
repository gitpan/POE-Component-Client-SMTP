# Copyright (c) 2005 George Nistorica
# All rights reserved.
# This program is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.  See the LICENSE
# file that comes with this distribution for more details.

package POE::Component::Client::SMTP;

# TODO:
# * clean up code,
# * more nice output in debug mode

use warnings;
use strict;

our $VERSION = '0.11';

use Carp;
use Socket;
use POE qw(Wheel::SocketFactory Wheel::ReadWrite Filter::Line Filter::Stream);

my $EOL = "\015\012";

sub send{
    _create(@_);
}

# Create session
sub _create {
    my $class      = shift;
    my %parameters = @_;

    # some checking
    croak "not an object method"     if ( ref($class) );

    # The actual Object;
    my $self = bless _fill_data( \%parameters ),$class;

    # build commands to be sent and expected states
    $self->_build_expected_states;
    $self->_build_commands;

    # store the caller
    $self->parameter("Caller_Session",$poe_kernel->get_active_session());

    # Spawn the PoCoClient::SMTP session
    POE::Session->create(
        object_states => [
            $self => {
                _start   => "_pococlsmtp_start",
                _stop    => "_pococlsmtp_stop",
                _default => "_pococlsmtp_default",

                # public available events
                smtp_shutdown => "_pococlsmtp_shutdown",
                smtp_progress => "_pococlsmtp_progress",

                # internal events SMTP codes and stuff
                smtp_send => "_pococlsmtp_send",

                # network related
                connection_established => "_pococlsmtp_conn_est",
                connection_error       => "_pococlsmtp_conn_err",
                smtp_session_input     => "_pococlsmtp_input",
                smtp_session_error     => "_pococlsmtp_error",
                smtp_timeout_event     => "_smtp_timeout_handler",

                # return events
                return_failure => "_pococlsmtp_return_error_event",
            },
        ],
#        options => { trace => 1 },
    );
}

# EVENT HANDLERS

sub _pococlsmtp_start {
    my ( $kernel, $self ) = @_[ KERNEL, OBJECT ];

    # in case there's no alias, use refcount
    if ( $self->parameter("Alias") ) {
        $kernel->alias_set( $self->parameter("Alias") );
    }
    else {
        $kernel->refcount_increment(
            $kernel->get_active_session()->ID() => __PACKAGE__ );
    }

    # fire the Session
    $kernel->yield("smtp_send");

}

sub _pococlsmtp_stop {
    my ( $kernel, $self ) = @_[ KERNEL, OBJECT ];

    carp "CURRENT STATE _pococlsmtp_stop" if $self->debug;
}

sub _pococlsmtp_default {
    my ($self) = $_[OBJECT];
    carp "CURRENT STATE _pococlsmtp_default" if $self->debug;
}

# this takes care of wheel creation and initial handshake with the SMTP server
sub _pococlsmtp_send {
    my ( $kernel, $self ) = @_[ KERNEL, OBJECT ];

    carp "CURRENT STATE: _pococlsmtp_send" if $self->debug;

    my $wheel = POE::Wheel::SocketFactory->new(
        RemoteAddress  => $self->parameter("Server"),
        RemotePort     => $self->parameter("Port"),
        SocketDomain   => AF_INET,
        SocketType     => SOCK_STREAM,
        SocketProtocol => 'tcp',
        Reuse          => 'yes',
        SuccessEvent   => "connection_established",
        FailureEvent   => "connection_error",
    );

    # store the wheel
    $self->store_sf_wheel( $wheel );
}

sub _pococlsmtp_conn_est {
    my ( $kernel, $self, $socket ) = @_[ KERNEL, OBJECT, ARG0 ];

    carp "CURRENT STATE: _pococlsmtp_conn_est" if $self->debug;

    my $wheel = POE::Wheel::ReadWrite->new(
        Handle       => $socket,
        InputFilter  => POE::Filter::Line->new( Literal => $EOL ),
        OutputFilter => POE::Filter::Stream->new(),
        InputEvent   => 'smtp_session_input',
        ErrorEvent   => 'smtp_session_error',
    );

    # set the alarm for preventing timeouts
    my $alarm = $kernel->delay_set(
        "smtp_timeout_event", $self->parameter("Timeout")
    );

    # store the wheel
    $self->store_rw_wheel( $wheel );
    # store the alarm
    $self->_alarm( $alarm );
}

sub _pococlsmtp_conn_err {
    my ( $kernel, $self ) = @_[ KERNEL, OBJECT ];
    my %hash;

    carp "CURRENT STATE: _pococlsmtp_conn_err" if $self->debug;

    $hash{'POE::Wheel::SocketFactory'} = @_[ARG0 .. ARG3];

    $kernel->yield(
        "return_failure",
        \%hash,
    );
}

# we've got our connection established, now we're processing input
sub _pococlsmtp_input {
    my ( $kernel, $self, $input, $wheel_id )
        = @_[ KERNEL, OBJECT, ARG0, ARG1 ];

    carp "CURRENT STATE: _pococlsmtp_input" if $self->debug;

    # reset alarm
    $kernel->delay_adjust(
        $self->_alarm,
        $self->parameter("Timeout"),
    );

    print "INPUT: $input\n" if $self->debug;

    if ( $input =~ /^(\d{3})\s+(.*)$/ ) {

        my $to_send = $self->command;
        if ( !defined($to_send) ){
            $kernel->post(
                $self->parameter("Caller_Session"),
                $self->parameter("SMTP_Success"),
                $self->parameter("Context"),
             );
            $self->_smtp_component_destroy;
        }else{
            print "TO SEND: $to_send\n" if $self->debug;        

            $self->store_rw_wheel->put(
                $to_send.$EOL
            );
        }
    }
    elsif ( $input =~ /^(\d{3})\-(.*)$/ ) {
        if ( $self->parameter("Debug") > 1 ) {
            carp "ESMTP Server capability: $input";
        }
    }
    else {
        carp "Received unknown string type from SMTP server, \"$input\"" if
$self->debug;
        my %hash;
        $hash{'SMTP_Server_Error'} = $input;
        $kernel->yield(
            "return_failure",
            \%hash,
        )
    }
}

sub _pococlsmtp_error {
    my ( $kernel, $self ) = @_[ KERNEL, OBJECT ];
    my %hash;

    carp "CURRENT STATE: _pococlsmtp_error" if $self->debug;

    $hash{'POE::Wheel::ReadWrite'} = @_[ARG0 .. ARG3];

    $kernel->yield(
        "return_failure",
        \%hash,
    );
}

sub _smtp_timeout_handler {
    my ( $kernel, $self ) = @_[ KERNEL, OBJECT ];
    my %hash;

    $hash{'Timeout'} = $self->parameter("Timeout");
    $kernel->yield(
        'return_failure',
        \%hash,
    );
}

sub _pococlsmtp_return_error_event{
    my ( $kernel, $self, $arg) = @_[ KERNEL, OBJECT, ARG0];

    carp "CURRENT STATE: _pococlsmtp_return_error_event" if $self->debug;

    $kernel->post(
        $self->parameter("Caller_Session"),
        $self->parameter("SMTP_Failure"),
        $self->parameter("Context"),
        $arg
    );
    $self->_smtp_component_destroy;

}

sub _smtp_component_destroy {
    my $self = shift;

    carp "CURRENT STATE: _smtp_component_destroy" if $self->debug;

    # remove alarms set for the Timeout
    $poe_kernel->alarm_remove_all();

    # in case there's no alias, use refcount
    if ( $self->parameter("Alias") ) {
        $poe_kernel->alias_remove( $self->parameter("Alias") );
    }
    else {
        $poe_kernel->refcount_decrement(
            $poe_kernel->get_active_session()->ID() => __PACKAGE__ );
    }

    # delete all wheels
    $self->delete_rw_wheel;
    $self->delete_sf_wheel;

}

sub _pococlsmtp_shutdown{
}

sub _pococlsmtp_progress{
}

# END OF EVENT HANDLERS

# UNDER THE HOOD

# take parameters, do checks on them and fill the object with data

sub _fill_data {
    my $parameters = shift;
    my $smtp_hash;

   # defaults
    my %default = (
        To           => 'root@localhost',
        From         => 'root@localhost',
        Body         => '',
        Server       => 'localhost',
        Port         => 25,
        Timeout      => 30,
        MyHostname   => "localhost",
        Debug        => 0,
        Alias        => undef,
        Context      => undef,
        SMTP_Success => undef,
        SMTP_Failure => undef,
    );

    #check parameters and set them to defaults if they don't exist
    for my $parameter ( keys(%default) ) {

        if ( exists($parameters->{$parameter}) ){
            $smtp_hash->{'Parameter'}->{$parameter} = $parameters->{$parameter};
        }else{
            $smtp_hash->{'Parameter'}->{$parameter} = $default{$parameter};
        }
    }
    return $smtp_hash;
}

# accessor/mutator
sub parameter {
    my $self      = shift;
    my $parameter = shift;
    my $value     = shift;

    die "This is an object method only" if ( !ref($self) );
    die "need a parameter!"             if ( !defined($parameter) );

    if ( defined($value) ) {
        $self->{'Parameter'}->{"$parameter"} = $value;
    }

    return $self->{'Parameter'}->{"$parameter"};
}

# accessor/mutator
sub store_sf_wheel{
    my $self = shift;
    my $wheel = shift;

    croak "not a class method" if ( !ref($self) );

    if (defined($wheel)){
        $self->{'Wheel'}->{'SF'} = $wheel;
    }

    return $self->{'Wheel'}->{'SF'};
}

sub delete_sf_wheel{
    my $self = shift;

    croak "not a class method" if ( !ref($self) );

    return delete $self->{'Wheel'}->{'SF'};

}

sub store_rw_wheel{
    my $self = shift;
    my $wheel = shift;

    croak "not a class method" if ( !ref($self) );

    if (defined($wheel)){
        $self->{'Wheel'}->{'RW'} = $wheel;
    }

    return $self->{'Wheel'}->{'RW'};

}

sub delete_rw_wheel{
    my $self = shift;

    croak "not a class method" if ( !ref($self) );

    return delete $self->{'Wheel'}->{'RW'};

}

# accessor/mutator for the alarm
sub _alarm{
    my $self = shift;
    my $alarm = shift;

    croak "not a class method" if ( !ref($self) );

    if ( defined( $alarm ) ){
        $self->{'session_alarm'} = $alarm;
        return $self;
    }else{
        return $self->{'session_alarm'};
    }
}

# return the current expected state
# return value is a list of expected values
sub _state{
    my $self = shift;

    croak "not a class method" if ( !ref($self) );

    return shift @{$self->{'State'}};
}

# build the expected list of states for every SMTP command we will be sending
sub _build_expected_states{
    my $self = shift;
    my @states;

    croak "not a class method" if ( !ref($self) );

    # initial state, the SMTP server greeting
    push @states, [220,221];

    # "ehlo" command
    push @states, [250,251];
    # TODO: de avut în vedere cazul în care serverul nu înţelege decât HELO

    # "mail from" command
    push @states, [250,251],
    
    my $rcpt_to = \$self->parameter( "To" );
    
    # "rcpt to" command
    if ( ref($$rcpt_to) =~ /SCALAR/io ){
        push @states, [250,251];
    }elsif( ref($$rcpt_to) =~/ARRAY/io ){
        for ( 0 .. $#$$rcpt_to){
           push @states, [250,251]; 
        }
    }else{
        push @states, [250,251];
    }

    # "data" command:
    push @states,[354,];

    # dot command
    push @states,[250,];

    # "quit" command
    push @states,[221,];

    $self->{'State'} = @states;

    return $self;

}

# return the next command
sub command{
    my $self = shift;

    croak "not a class method" if ( !ref($self) );

    return shift @{ $self->{'Command'} };

}

#  build the list of commands
sub _build_commands{
    my $self = shift;
    my @commands;

    croak "not a class method" if ( !ref($self) );

    push @commands, "HELO ".$self->parameter("MyHostname");
    push @commands, "MAIL FROM: <".$self->parameter("From").">";
    my $rcpt_to = \$self->parameter("To");
    if ( ref( $$rcpt_to) =~ /ARRAY/io ){
        for my $recipient ( @{$$rcpt_to} ){
            push @commands, "RCPT TO: <".$recipient.">";
        }
    }
    elsif (ref( $$rcpt_to) =~ /SCALAR/io){
            push @commands, "RCPT TO: <".$$$rcpt_to.">";
    }else{
        # no ref, just a scalar ;-)
        push  @commands, "RCPT TO: <".$$rcpt_to.">";
    }

    push @commands,"DATA";
    # TODO: de adăugat şi Body la comanda "." ? nu prea aş vrea
    my $body = $self->parameter("Body");
    $body.="$EOL.";
    push @commands, $body;
    #push @commands, '.',
    push @commands, "QUIT";

    $self->{'Command'} = \@commands;

    return $self;
}

sub debug{
    my $self = shift;
    my $debug_level = shift;
    
    croak "not a class method" if ( !ref($self) );

    if ( defined( $debug_level ) ){
        $self->parameter("Debug") = $debug_level;
    }
    
    return $self->parameter("Debug");
}

# END UNDER THE HOOD

# POD BELOW

=head1 NAME

POE::Component::Client::SMTP - Asynchronous mail sending with POE

=head1 VERSION

Version 0.11

=head1 DESCRIPTION

PoCoClient::SMTP allows you to send email messages in an asynchronous manner, 
using POE.

Thus your program isn't blocking while busy talking with an (E)SMTP server.

=head1 SYNOPSIS

B<Warning!> The following examples are B<not> complete programs, and
aren't designed to be run as full blown applications. Their purpose is to
quickly
introduce you to the module.

For complete examples, check the 'eg' directory that can be found in the
distribution's kit.

A simple example:

 # load PoCoClient::SMTP
 use POE::Component::Client::SMTP;
 # spawn a session
 POE::Component::Client::SMTP->send(
     From    => 'foo@baz.com',
     To      => 'john@doe.net',
     Server  =>  'relay.mailer.net',
     SMTP_Success    =>  'callback_event_for_success',
     SMTP_Failure    =>  'callback_event_for_failure',
 );
 # and you are all set ;-)

A more complex example:

 # load PoCoClient::SMTP
 use POE::Component::Client::SMTP;
 # spawn a session
 POE::Component::Client::SMTP->send(
     # Email related parameters
     From    => 'foo@baz.com',
     To      => [
                'john@doe.net',
                'andy@zzz.org',
                'peter@z.net',
                'george@g.com',
                ],
     Body    =>  \$email_body,   # here's where your message is stored
     Server  =>  'relay.mailer.net',
     Timeout => 100, # 100 seconds before timeouting
     # POE related parameters
     Alias           => 'pococlsmtpX',
     SMTP_Success    =>  'callback_event_for_success',
     SMTP_Failure    =>  'callback_event_for_failure',
 );
 # and you are all set ;-)

=head1 API Changes

As you may have noticed, the API has changed, and this module version is not
backward compatible.

So if you are upgrading from a previous version, please adjust your code.

=head1 METHODS

Below are the methods this Component has:

=head2 send

This immediately spawns a PoCoClient::SMTP Session and registers 
itself with the Kernel in order to have its job done. This method may be
overhead for sending bulk messages, as after sending one message it gets
destroyed. Maybe in the future, there will be a I<spawn> method that will keep
the Session around forever, until received a 'shutdown' like event.

=head3 PARAMETERS

There are two kinds of parameters PoCoClient::SMTP supports: Email related
parameters and POE related parameters:

=over 8

=item From

This holds the sender's email address

B<Defaults> to 'root@localhost', just don't ask why.

=item To

This holds a list of recipients. Note that To/CC/BCC fields are separated in
your email body. From the SMTP server's point of view (and from this
component's too) there is no difference as who is To, who CC and who BCC.

The bottom line is: be careful how you construct your email message.

B<Defaults> to root@localhost', just don't ask why.

=item Body

Here's the meat. This scalar contains the message you are sending composed of
Email Fields and the actual message content. You need to construct this by hand
or use another module. Which one you use is a matter of taste ;-)))

B<Defaults> to an empty mail body.

=item Server

Here you specify the relay SMTP server to be used by this component. Currently 
piping thru sendmail is not supported so you need a SMTP server to actually
do the mail delivery (either by storing the mail somewhere on the hard
drive, or by relaying to another SMTP server).

B<Defaults> to 'localhost'

=item Port

Usually SMTP servers bind to port 25. (See /etc/services if you are using a
*NIX like O.S.).

Sometimes, SMTP servers are set to listen to other ports, in which case you
need to set this parameter to the correct value to match your setup.

B<Defaults> to 25

=item Timeout

Set the timeout for SMTP transactions (seconds).

B<Defaults> to 30 seconds

=item MyHostname

Hostname to present when sending EHLO/HELO command.

B<Defaults> to "localhost"

=item Debug

Set the debugging level. A value greater than 0 increases the Component's
verbosity

B<Defaults> to 0

=item Alias

In case you have multiple PoCoClient::SMTP Sessions, you'd like to handle them
separately, so use Alias to differentiate them.

This holds the Session's alias.

B<Defaults> to nothing. Internally it refcounts to stay alive.

=item Context

You may want to set a context for your POE::Component::Client::SMTP session.
This is a scalar.

When the caller session receives SMTP_Success or SMTP_Failure event, the
context is also passed to it if defined.

=item SMTP_Success

Event you want to be called by PoCoClient::SMTP in case of success.

B<Defaults> to nothing. This means that the Component will not trigger any
event and will silently go away.

It will send you the Context as ARG0 if Context is defined.

=item SMTP_Failure

Event you want to be called by PoCoClient::SMTP in case of failure.

You will get back the following information:

=over 8

=item ARG0

The Context you've set when spawning the component, or undef if no Context
specified

=item ARG1

A hash ref that currently has only a key:

* SMTP_Server_Error, in this case, the value is the string as returned by the
server (the error code should be included too by the server in the string)

* Timeout, the value is the amount of seconds the timeout was set to

* POE::Wheel::* depending on the wheel that returned error on us ;-)
the value is an array containing ARG0 .. ARG3

=back

B<Defaults> to nothing. This means that the Component will not trigger any
event and will silently go away.

=back

=head1 SEE ALSO

RFC2821 L<POE> L<POE::Session>

=head1 BUGS

=over 8

=item * Currently the Component sends only HELO to the server, not EHLO. This
shouldn't be such a problem as for the moment the Component hasn't any ESMTP
features.

=back

=head2 Bug Reporting

Please report bugs using the project's page interface, at: 
L<https://savannah.nongnu.org/projects/pococlsmtp/>

Unified format patches are more than welcome.

=head1 KNOWN ISSUES

=head2 Bare LF characters

Note that the SMTP protocol forbids bare LF characters in e-mail messages.
PoCoClSMTP doesn't do any checking whether you message is SMTP compliant or not.

Most of the SMTP servers in the wild are tolerant with bare LF characters, but
you shouldn't count on that.

The point is you shouldn't send email messages having bare LF characters.
See: http://cr.yp.to/docs/smtplf.html

=head1 ACKNOWLEDGMENTS

=over 4

=item BinGOs for ideas/patches and testing

=item Mike Schroeder for ideas

=back

=head1 AUTHOR

George Nistorica, C<< <ultradm@cpan.org> >>

=head1 COPYRIGHT & LICENSE

Copyright 2005 George Nistorica, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

1;    # End of POE::Component::Client::SMTP
