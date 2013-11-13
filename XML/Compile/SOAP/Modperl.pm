# XML::Compile::SOAP::Modperl -- mod_perl 2 handler for XML::Compile::SOAP
# Gary Wall <gary@daimonic.org>
#
# Note: This handler mimics the behaviour of XML::Compile::SOAP::Daemon,
# but has not been comprehensively tested for any period of time yet.

package XML::Compile::SOAP::Modperl;

use strict;
use warnings;

use Apache2::Request;
use Apache2::RequestIO ();
use Apache2::RequestRec ();
use Apache2::Response ();
use Apache2::Const -compile => qw( :http :methods );
use APR::Table ();

use Sys::Syslog qw( :standard );
use Data::Dumper;

use XML::Compile::WSDL11;
use XML::Compile::SOAP11;
use XML::Compile::SOAP11::Server;
use XML::Compile::Util qw( type_of_node pack_type );
use XML::LibXML ();
use Encode;

sub Message1 {
	return { 'stringresp' => 'Hello World!' };
}

my %callbacks = (
	'Message1' => \&Message1,
);

sub handler {
	my $r = shift;
	my ($xmlin, $postdata);
	$r->read($postdata, 4096);

	my $wsdl = XML::Compile::WSDL11->new('/home/garyw/soap/test.wsdl');
	my $ss = XML::Compile::SOAP11::Server->new('schemas' => $wsdl);
	my $parser = XML::LibXML->new;

	my $charset = $r->content_type =~ m{\;\s*type\=(["']?)([\w-]*)\1/} ? $2: 'utf-8';
	my $handler = {};

	# Method must be M_POST
	return makeResponse($r, Apache2::Const::HTTP_METHOD_NOT_ALLOWED, 'only POST or M-POST',
		'attempt to connect via '.$r->method) if ($r->method_number != Apache2::Const::M_POST);

	# Content-Type must begin with `text/xml;'
	return makeResponse($r, Apache2::Const::HTTP_NOT_ACCEPTABLE, 'required is XML',
		'content-type seems to be ' . $r->content_type . ', must be some XML') if
		($r->headers_in->{'Content-Type'} !~ m{^text/xml;}i);

	my $action = $r->headers_in->{'SOAPAction'} || undef;
	$action = $1 if ($action =~ m/^\s*\"(.*?)\"/);

	# SOAP requires an SOAPAction header field (empty or not)
	return makeResponse($r, Apache2::Const::HTTP_EXPECTATION_FAILED, 'not SOAP',
		'soap requires an soapAction header field') if !defined($action);

	my $local = '';

	if ($postdata) {
		$xmlin = $postdata;
		$xmlin = decode_utf8($xmlin) if (lc($charset) eq 'utf-8');
		$xmlin = $parser->parse_string($postdata);
		$xmlin = $xmlin->documentElement if $xmlin->isa('XML::LibXML::Document');
		$local = $xmlin->localName;
	}

	# The message was XML, but not SOAP; not an Envelope but {type_of_node $xmlin}
	return makeResponse($r, Apache2::Const::HTTP_FORBIDDEN, 'message not SOAP',
		"The message was XML, but not SOAP; not an Envelope but `{$local}'") if 
		($local ne 'Envelope');

	my $envns = $xmlin->namespaceURI || '';

	# SOAP version not supported
	return makeResponse($r, Apache2::Const::HTTP_NOT_IMPLEMENTED, 'SOAP version not supported',
		"The soap version `{$envns}' is not supported") if 
		(!(my $proto = XML::Compile::Operation->fromEnvelope($envns)));

	my $server   = $proto->serverClass;
	my $info     = XML::Compile::SOAP->messageStructure($xmlin);
	my $version  = $info->{soap_version} = $proto->version;
	
	my @ops = $wsdl->operations();
	my $code;

	foreach my $op (@ops) {
		my $name = $op->name;
		
		if ((defined($callbacks{$name})) && (ref($callbacks{$name}) eq 'CODE')) {
			$code = $op->compileHandler(callback => $callbacks{$name});
		} else {
			my $server  = $op->serverClass;
			my $hdlr = sub {
				return makeResponse($r, Apache2::Const::HTTP_NOT_IMPLEMENTED, 
					'procedure stub used',
					"procedure {$name} for {$version} is not yet implemented"
				);
			};

			$code = $op->compileHandler(callback => $hdlr);
		}

		my $ver = ref $op ? $op->version : $op;
		$handler->{$ver}{$name} = $code;
	}

	my $count = @ops;
	mlog("added {$count} operations from WSDL");

	my $handlers = $handler->{$version};
	keys %$handlers;

	while (my ($name, $handler) = each %$handlers) {
		my ($rc, $msg, $xmlout) = $handler->($name, $xmlin, $info);
		defined $xmlout or next;

		return makeResponse($r, Apache2::Const::HTTP_OK, undef, $xmlout);
	}

	my $bodyel = $info->{body}[0] || '(none)';
	my @other  = sort grep {$_ ne $version && keys %{$handler->{$_}}} soapVersions();

	return makeResponse($r, Apache2::Const::HTTP_SEE_OTHER, 'SOAP protocol not in use',
		$ss->faultTryOtherProtocol($bodyel, \@other)) if @other;

	my @available = sort keys %$handlers;
	return makeResponse($r, Apache2::Const::HTTP_NOT_FOUND, 'message not recognized',
		$ss->faultMessageNotRecognized($bodyel, \@available));

	# WTF happened?
	return Apache2::Const::HTTP_INTERNAL_SERVER_ERROR;
}

sub makeResponse {
	my ($r, $status, $msg, $body) = @_;

	$r->custom_response($status, $msg) if defined($msg);
	my $s;

	if(UNIVERSAL::isa($body, 'XML::LibXML::Document')) {
		$s = $body->toString($status == Apache2::Const::HTTP_OK ? 0 : 1);
		$r->content_type('text/xml; charset="utf-8"');
	} else {
		$s = "[$status] $body";
		$r->content_type('text/plain');
	}

	$r->headers_out->set('Content-Length' => length $s);
	$r->print(encode_utf8($s));

	return $status;
}

sub soapVersions() { qw( SOAP11 SOAP12 ) }

sub mlog {
	my $msg = shift;

	openlog 'mydaemon', 'ndelay,nowait,pid', 'LOCAL7';
	syslog 'LOG_INFO', $msg;
	closelog;
}

1;
