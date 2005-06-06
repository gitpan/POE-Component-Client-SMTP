#!perl -T
# Check if POE::Component::Client::SMTP is a POE::Session
use strict;
use Test::More tests => 1;


use POE;
use POE::Component::Client::SMTP;
my $data = "zzzzzzzzzz";

my ($self) = POE::Component::Client::SMTP->send(
    alias => "smtp_client",
    smtp_sender => "foo\@bar.com",
    smtp_recipient => "bar\@foo.com",
    smtp_data => \$data,
    SMTPSendSuccessEvent => "success",
    SMTPSendFailureEvent => "failure",
);

isa_ok ( $self, 'POE::Session' );
diag("Check if POE::Component::Client::SMTP is a POE::Session");

POE::Session->create(
	inline_states => { _start => \&test_start, },
);

$poe_kernel->run();
exit 0;

sub test_start {
}
