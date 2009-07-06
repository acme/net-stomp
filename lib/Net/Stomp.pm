package Net::Stomp;
use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;
use Net::Stomp::Frame;
use base 'Class::Accessor::Fast';
__PACKAGE__->mk_accessors(
    qw(hostname port select serial session_id socket ssl ssl_options));
our $VERSION = '0.34';

sub new {
    my $class = shift;
    my $self  = $class->SUPER::new(@_);
    my ($socket);
    my %sockopts = (
        PeerAddr => $self->hostname,
        PeerPort => $self->port,
        Proto    => 'tcp'
    );

    if ( $self->ssl ) {
        eval { require IO::Socket::SSL };
        die
            "You should install the IO::Socket::SSL module for SSL support in Net::Stomp"
            if $@;
        %sockopts = ( %sockopts, %{ $self->ssl_options || {} } );
        $socket = IO::Socket::SSL->new(%sockopts);
    } else {
        $socket = IO::Socket::INET->new(%sockopts);
    }
    die "Error connecting to " . $self->hostname . ':' . $self->port . ": $!"
        unless $socket;
    binmode($socket);
    $self->socket($socket);
    my $select = IO::Select->new();
    $select->add($socket);
    $self->select($select);

    return $self;
}

sub connect {
    my ( $self, $conf ) = @_;
    my $frame = Net::Stomp::Frame->new(
        { command => 'CONNECT', headers => $conf } );
    $self->send_frame($frame);
    $frame = $self->receive_frame;

    # Setting initial values for session id, as given from
    # the stomp server
    $self->session_id( $frame->headers->{session} );

    return $frame;
}

sub disconnect {
    my $self = shift;
    my $frame = Net::Stomp::Frame->new( { command => 'DISCONNECT' } );
    $self->send_frame($frame);
    $self->socket->close;
}

sub can_read {
    my ( $self, $conf ) = @_;
    my $timeout = $conf->{timeout} || 0;
    return $self->select->can_read($timeout) || 0;
}

sub send {
    my ( $self, $conf ) = @_;
    my $body = $conf->{body};
    delete $conf->{body};
    my $frame = Net::Stomp::Frame->new(
        { command => 'SEND', headers => $conf, body => $body } );
    $self->send_frame($frame);
}

sub send_transactional {
    my ( $self, $conf ) = @_;
    my $body = $conf->{body};
    delete $conf->{body};

    # begin the transaction
    my $transaction_id = $self->_get_next_transaction;
    my $begin_frame
        = Net::Stomp::Frame->new(
        { command => 'BEGIN', headers => { transaction => $transaction_id } }
        );
    $self->send_frame($begin_frame);

    # send the message
    my $receipt_id = $self->_get_next_transaction;
    $conf->{receipt} = $receipt_id;
    my $message_frame = Net::Stomp::Frame->new(
        { command => 'SEND', headers => $conf, body => $body } );
    $self->send_frame($message_frame);

    # check the receipt
    my $receipt_frame = $self->receive_frame;
    if (   $receipt_frame->command eq 'RECEIPT'
        && $receipt_frame->headers->{'receipt-id'} eq $receipt_id )
    {

        # success, commit the transaction
        my $frame_commit = Net::Stomp::Frame->new(
            {   command => 'COMMIT',
                headers => { transaction => $transaction_id }
            }
        );
        $self->send_frame($frame_commit);

        return 1;
    } else {

        # some failure, abort transaction
        my $frame_abort = Net::Stomp::Frame->new(
            {   command => 'ABORT',
                headers => { transaction => $transaction_id }
            }
        );
        $self->send_frame($frame_abort);
        return 0;
    }
}

sub subscribe {
    my ( $self, $conf ) = @_;
    my $frame = Net::Stomp::Frame->new(
        { command => 'SUBSCRIBE', headers => $conf } );
    $self->send_frame($frame);
}

sub unsubscribe {
    my ( $self, $conf ) = @_;
    my $frame = Net::Stomp::Frame->new(
        { command => 'UNSUBSCRIBE', headers => $conf } );
    $self->send_frame($frame);
}

sub ack {
    my ( $self, $conf ) = @_;
    my $id    = $conf->{frame}->headers->{'message-id'};
    my $frame = Net::Stomp::Frame->new(
        { command => 'ACK', headers => { 'message-id' => $id } } );
    $self->send_frame($frame);
}

sub send_frame {
    my ( $self, $frame ) = @_;

    #     warn "send [" . $frame->as_string . "]\n";
    $self->socket->print( $frame->as_string );
}

sub receive_frame {
    my $self = shift;

    my $frame = Net::Stomp::Frame->parse( $self->socket );

    #     warn "receive [" . $frame->as_string . "]\n";
    return $frame;
}

sub _get_next_transaction {
    my $self = shift;
    my $serial = $self->serial || 0;
    $serial++;
    $self->serial($serial);

    return $self->session_id . '-' . $serial;
}

1;

__END__

=head1 NAME

Net::Stomp - A Streaming Text Orientated Messaging Protocol Client

=head1 SYNOPSIS

  # send a message to the queue 'foo'
  use Net::Stomp;
  my $stomp = Net::Stomp->new( { hostname => 'localhost', port => '61613' } );
  $stomp->connect( { login => 'hello', passcode => 'there' } );
  $stomp->send(
      { destination => '/queue/foo', body => 'test message' } );
  $stomp->disconnect;

  # subscribe to messages from the queue 'foo'
  use Net::Stomp;
  my $stomp = Net::Stomp->new( { hostname => 'localhost', port => '61613' } );
  $stomp->connect( { login => 'hello', passcode => 'there' } );
  $stomp->subscribe(
      {   destination             => '/queue/foo',
          'ack'                   => 'client',
          'activemq.prefetchSize' => 1
      }
  );
  while (1) {
    my $frame = $stomp->receive_frame;
    warn $frame->body; # do something here
    $stomp->ack( { frame => $frame } );
  }
  $stomp->disconnect;

  # write your own frame
   my $frame = Net::Stomp::Frame->new(
       { command => $command, headers => $conf, body => $body } );
  $self->send_frame($frame);

=head1 DESCRIPTION

This module allows you to write a Stomp client. Stomp is the Streaming
Text Orientated Messaging Protocol (or the Protocol Briefly Known as
TTMP and Represented by the symbol :ttmp). It's a simple and easy to
implement protocol for working with Message Orientated Middleware from
any language. L<Net::Stomp> is useful for talking to Apache ActiveMQ,
an open source (Apache 2.0 licensed) Java Message Service 1.1 (JMS)
message broker packed with many enterprise features.

A Stomp frame consists of a command, a series of headers and a body -
see L<Net::Stomp::Frame> for more details.

For details on the protocol see L<http://stomp.codehaus.org/Protocol>.

To enable the ActiveMQ Broker for Stomp add the following to the
activemq.xml configuration inside the <transportConnectors> section:

  <transportConnector name="stomp" uri="stomp://localhost:61613"/>

To enable the ActiveMQ Broker for Stomp and SSL add the following
inside the <transportConnectors> section:

  <transportConnector name="stomp+ssl" uri="stomp+ssl://localhost:61612"/>

For details on Stomp in ActiveMQ See L<http://activemq.apache.org/stomp.html>.

=head1 METHODS

=head2 new

The constructor creates a new object. You must pass in a hostname and
a port:

  my $stomp = Net::Stomp->new( { hostname => 'localhost', port => '61613' } );

If you want to use SSL, make sure you have L<IO::Socket::SSL> and
pass in the SSL flag:

  my $stomp = Net::Stomp->new( {
    hostname => 'localhost',
    port     => '61612',
    ssl      => 1,
  } );

If you want to pass in L<IO::Socket::SSL> options:

  my $stomp = Net::Stomp->new( {
    hostname    => 'localhost',
    port        => '61612',
    ssl         => 1,
    ssl_options => { SSL_cipher_list => 'ALL:!EXPORT' },
  } );

=head2 connect

This connects to the Stomp server. You must pass in a login and
passcode.

You may pass in 'client-id', which specifies the JMS Client ID which
is used in combination to the activemqq.subscriptionName to denote a
durable subscriber.
  
  $stomp->connect( { login => 'hello', passcode => 'there' } );

=head2 send

This sends a message to a queue or topic. You must pass in a destination and a body.

  $stomp->send(
      { destination => '/queue/foo', body => 'test message' } );

To send a BytesMessage, you should set the field 'bytes_message' to 1.

=head2 send_transactional

This sends a message in transactional mode and fails if the receipt of the
message is not acknowledged by the server:

  $stomp->send_transactional(
      { destination => '/queue/foo', body => 'test message' }
  ) or die "Couldn't send the message!";

If using ActiveMQ, you might also want to make the message persistent:

  $stomp->send_transactional(
      { destination => '/queue/foo', body => 'test message', persistent => 'true' }
  ) or die "Couldn't send the message!";

=head2 disconnect

This disconnects from the Stomp server:

  $stomp->disconnect;

=head2 subscribe

This subscribes you to a queue or topic. You must pass in a destination.

The acknowledge mode defaults to 'auto', which means that frames will
be considered delivered after they have been sent to a client. The
other option is 'client', which means that messages will only be
considered delivered after the client specifically acknowledges them
with an ACK frame.

Other options:

'selector': which specifies a JMS Selector using SQL
92 syntax as specified in the JMS 1.1 specificiation. This allows a
filter to be applied to each message as part of the subscription.

'activemq.dispatchAsync': should messages be dispatched synchronously
or asynchronously from the producer thread for non-durable topics in
the broker. For fast consumers set this to false. For slow consumers
set it to true so that dispatching will not block fast consumers.

'activemq.exclusive': Would I like to be an Exclusive Consumer on a queue.

'activemq.maximumPendingMessageLimit': For Slow Consumer Handlingon
non-durable topics by dropping old messages - we can set a maximum
pending limit which once a slow consumer backs up to this high water
mark we begin to discard old messages.
 
'activemq.noLocal': Specifies whether or not locally sent messages
should be ignored for subscriptions. Set to true to filter out locally
sent messages.
 
'activemq.prefetchSize': Specifies the maximum number of pending
messages that will be dispatched to the client. Once this maximum is
reached no more messages are dispatched until the client acknowledges
a message. Set to 1 for very fair distribution of messages across
consumers where processing messages can be slow.
 
'activemq.priority': Sets the priority of the consumer so that
dispatching can be weighted in priority order.

'activemq.retroactive': For non-durable topics do you wish this
subscription to the retroactive.

'activemq.subscriptionName': For durable topic subscriptions you must
specify the same clientId on the connection and subscriberName on the
subscribe.

  $stomp->subscribe(
      {   destination             => '/queue/foo',
          'ack'                   => 'client',
          'activemq.prefetchSize' => 1
      }
  );

=head2 unsubscribe

This unsubscribes you to a queue or topic. You must pass in a destination:

  $stomp->unsubcribe({ destination => '/queue/foo' });

=head2 receive_frame

This blocks and returns you the next Stomp frame. 

  my $frame = $stomp->receive_frame;
  warn $frame->body; # do something here

The header bytes_message is 1 if the message was a BytesMessage.

=head2 can_read

This returns whether a frame is waiting to be read. Optionally takes a
timeout in seconds:

  my $can_read = $stomp->can_read;
  my $can_read = $stomp->can_read({ timeout => '0.1' });


=head2 ack

This acknowledges that you have received and processed a frame (if you
are using client acknowledgements):

  $stomp->ack( { frame => $frame } );

=head2 send_frame

If this module does not provide enough help for sending frames, you
may construct your own frame and send it:

  # write your own frame
  my $frame = Net::Stomp::Frame->new(
       { command => $command, headers => $conf, body => $body } );
  $self->send_frame($frame);

=head1 SEE ALSO

L<Net::Stomp::Frame>.

=head1 AUTHOR

Leon Brocard <acme@astray.com>.

=head1 COPYRIGHT

Copyright (C) 2006-9, Leon Brocard

This module is free software; you can redistribute it or modify it
under the same terms as Perl itself.

