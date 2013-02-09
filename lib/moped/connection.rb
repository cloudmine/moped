require "timeout"
require "moped/sockets/connectable"
require "moped/sockets/tcp"
require "moped/sockets/ssl"

module Moped

  # This class contains behaviour of database socket connections.
  #
  # @api private
  class Connection

    attr_reader :host, :port, :timeout, :options, :pinned_to

    # Determine if the Connection is equal to another.
    #
    # @example Are the Connections equal?
    #   connection == other
    #
    # @param [ Object ] other The other object.
    #
    # @return [ true, false ] If the Connection is equal to the other.
    #
    # @since 2.0.0
    def ==(other)
      address == other.address &&
        timeout == other.timeout && options == other.options
    end

    # Get the address of the Connection in host:port format.
    #
    # @example Get the Connection address.
    #   connection.address
    #
    # @return [ String ] The address of the Connection.
    #
    # @since 2.0.0
    def address
      @address ||= "#{host}:#{port}"
    end

    # Is the connection alive?
    #
    # @example Is the connection alive?
    #   connection.alive?
    #
    # @return [ true, false ] If the connection is alive.
    #
    # @since 1.0.0
    def alive?
      connected? ? @sock.alive? : false
    end

    # Connect to the server defined by @host, @port without timeout @timeout.
    #
    # @example Open the connection
    #   connection.connect
    #
    # @return [ TCPSocket ] The socket.
    #
    # @since 1.0.0
    def connect
      @sock = if !!options[:ssl]
        Sockets::SSL.connect(host, port, timeout)
      else
        Sockets::TCP.connect(host, port, timeout)
      end
    end

    # Is the connection connected?
    #
    # @example Is the connection connected?
    #   connection.connected?
    #
    # @return [ true, false ] If the connection is connected.
    #
    # @since 1.0.0
    def connected?
      !!@sock
    end

    # Disconnect from the server.
    #
    # @example Disconnect from the server.
    #   connection.disconnect
    #
    # @return [ nil ] nil.
    #
    # @since 1.0.0
    def disconnect
      @sock.close
    rescue
    ensure
      @sock = nil
    end

    # Initialize the connection.
    #
    # @example Initialize the connection.
    #   Connection.new("localhost", 27017, 5)
    #
    # @param [ String ] host The host to connect to.
    # @param [ Integer ] post The server port.
    # @param [ Integer ] timeout The connection timeout.
    # @param [ Hash ] options Options for the connection.
    #
    # @option options [ Boolean ] :ssl Connect using SSL
    # @since 1.0.0
    def initialize(host, port, timeout, options = {})
      @sock = nil
      @request_id = 0
      @host, @port, @timeout, @options = host, port, timeout, options
    end

    # Pin the Connection to a specific thread instance. We pin to the object_id
    # of the Thread instead of the instance itself so the Thread can be garbage
    # collected if terminated.
    #
    # @example Pin the Connection to a thread.
    #   connection.pin_to(thread.object_id)
    #
    # @param [ Integer ] The instance object_id of the Thread.
    #
    # @return [ Integer ] The instance object_id of the Thread.
    #
    # @since 2.0.0
    def pin_to(thread_id)
      @pinned_to = thread_id
    end

    def pinned?
      !!@pinned_to
    end

    def unpin
      @pinned_to = nil
    end

    # Read from the connection.
    #
    # @example Read from the connection.
    #   connection.read
    #
    # @return [ Hash ] The returned document.
    #
    # @since 1.0.0
    def read
      with_connection do |socket|
        reply = Protocol::Reply.allocate
        data = read_data(socket, 36)
        response = data.unpack('l<5q<l<2')
        reply.length,
            reply.request_id,
            reply.response_to,
            reply.op_code,
            reply.flags,
            reply.cursor_id,
            reply.offset,
            reply.count = response

        if reply.count == 0
          reply.documents = []
        else
          sock_read = read_data(socket, reply.length - 36)
          buffer = StringIO.new(sock_read)
          reply.documents = reply.count.times.map do
            BSON::Document.deserialize(buffer)
          end
        end
        reply
      end
    end

    # Get the replies to the database operation.
    #
    # @example Get the replies.
    #   connection.receive_replies(operations)
    #
    # @param [ Array<Message> ] operations The query or get more ops.
    #
    # @return [ Array<Hash> ] The returned deserialized documents.
    #
    # @since 1.0.0
    def receive_replies(operations)
      operations.map do |operation|
        operation.receive_replies(self)
      end
    end

    # Write to the connection.
    #
    # @example Write to the connection.
    #   connection.write(data)
    #
    # @param [ Array<Message> ] operations The database operations.
    #
    # @return [ Integer ] The number of bytes written.
    #
    # @since 1.0.0
    def write(operations)
      buf = ""
      operations.each do |operation|
        operation.request_id = (@request_id += 1)
        operation.serialize(buf)
      end
      with_connection do |socket|
        socket.write(buf)
      end
    end

    private

    # Read data from the socket until we get back the number of bytes that we
    # are expecting.
    #
    # @api private
    #
    # @example Read the number of bytes.
    #   connection.read_data(socket, 36)
    #
    # @param [ TCPSocket ] socket The socket to read from.
    # @param [ Integer ] length The number of bytes to read.
    #
    # @return [ String ] The read data.
    #
    # @since 1.2.9
    def read_data(socket, length)
      data = socket.read(length)
      unless data
        raise Errors::ConnectionFailure.new(
          "Attempted to read #{length} bytes from the socket but nothing was returned."
        )
      end
      if data.length < length
        data << read_data(socket, length - data.length)
      end
      data
    end

    # Yields a connected socket to the calling back. It will attempt to reconnect
    # the socket if it is not connected.
    #
    # @example Write to the connection.
    #   with_connection do |socket|
    #     socket.write(buf)
    #   end
    #
    # @return The yielded block
    #
    # @since 1.3.0
    def with_connection
      connect if @sock.nil? || !@sock.alive?
      yield @sock
    end
  end
end
