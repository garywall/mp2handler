#!/usr/bin/perl

use strict;
use warnings;

use Data::Dumper;

use constant SERVERHOST => 'localhost';
use constant SERVERPORT => '80';

my $service_address = 'http://'.SERVERHOST.':'.SERVERPORT;

use XML::Compile::WSDL11;
use XML::Compile::Transport::SOAPHTTP;
use XML::Compile::SOAP11;

my $transporter = XML::Compile::Transport::SOAPHTTP->new( 
	address => $service_address
);

my $http = $transporter->compileClient;
my $wsdl = XML::Compile::WSDL11->new('/home/gary/soap/test.wsdl');

my $Message1 = $wsdl->compileClient(
	'Message1',
	transporter => $http
);

my ($answer, $trace) = $Message1->('stringreq' => 'string1');

show_trace($answer, $trace);

sub show_trace {   
	my ($answer, $trace) = @_;

	$trace->printTimings;
	$trace->printRequest;
	$trace->printResponse;

	print Dumper $answer;
}
