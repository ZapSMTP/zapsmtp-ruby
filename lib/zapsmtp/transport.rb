# frozen_string_literal: true

require "net/http"
require "openssl"
require "uri"

module ZapSMTP
  # How requests reach the API. A transport is any object with
  # #call(request) -> response, taking a Transport::Request and answering a
  # Transport::Response (or anything with status, headers and body); it
  # raises on a network failure or timeout. Pass one as
  # ZapSMTP::Client.new(transport: ...) to use another HTTP library or to
  # stub the API in tests.
  module Transport
    # One HTTP attempt: http_method ("GET"...), url, headers (Hash), body
    # (String or nil) and timeout (seconds).
    Request = Struct.new(:http_method, :url, :headers, :body, :timeout, keyword_init: true)

    # An HTTP answer: status (Integer), headers (Hash) and body (String).
    Response = Struct.new(:status, :headers, :body, keyword_init: true)

    # A timeout: no connection, or no answer, within the timeout.
    class TimeoutError < StandardError; end

    # The answer's head came but its body broke off (or stalled): the
    # status and headers are kept for the ConnectionError.
    class ResponseBodyError < StandardError
      # @return [Integer]
      attr_reader :status
      # @return [Hash]
      attr_reader :headers

      def initialize(message, status:, headers:)
        super(message)
        @status = status
        @headers = headers
      end
    end

    # The default transport: Net::HTTP, keeping one connection alive per
    # thread and host. The timeout bounds connecting, each write and each
    # read, the response body's included.
    class NetHTTP
      TIMEOUTS = [Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout].freeze
      # The encodings Net::HTTP inflates (when it asked for compression itself).
      INFLATED = %w[gzip deflate x-gzip].freeze

      def initialize
        @key = :"zapsmtp_connections_#{object_id}"
      end

      def call(request)
        uri = URI.parse(request.url)
        head = nil
        begin
          http = connection(uri, request.timeout)
          message = Net::HTTPGenericRequest.new(request.http_method, !request.body.nil?, true, uri.request_uri,
                                                request.headers)
          message.body = request.body
          answer = http.request(message) do |response|
            head = response
            read_body(response)
          end
        rescue StandardError => e
          close(uri)
          raise failure(e, head, request.timeout)
        end
        Response.new(status: answer.code.to_i, headers: headers(answer),
                     body: answer.body.to_s.dup.force_encoding(Encoding::UTF_8))
      end

      private

      def headers(response)
        response.to_hash.transform_values { |v| v.join(", ") }
      end

      # The error to raise for a failed attempt: a timeout says so, and a
      # failure after the answer's head keeps its status and headers.
      def failure(error, head, timeout)
        timed_out = TIMEOUTS.any? { |t| error.is_a?(t) }
        message = timed_out ? "timed out after #{timeout} s" : error.message
        return ResponseBodyError.new(message, status: head.code.to_i, headers: headers(head)) if head

        timed_out ? TimeoutError.new(message) : error
      end

      # Reads the body, refusing one cut short: Net::HTTP returns what came
      # before the connection closed. Content-Length counts the bytes on the
      # wire, so it is checked unless Net::HTTP inflated them (a compressed
      # body cut short fails to inflate instead).
      def read_body(response)
        inflated = response.decode_content && INFLATED.include?(response["content-encoding"].to_s.downcase)
        length = response.content_length
        response.read_body
        return if inflated || length.nil? || response.body.to_s.bytesize >= length

        raise EOFError, "response body cut short: #{response.body.to_s.bytesize} of #{length} bytes"
      end

      # This thread's open connection to the URI's host, or a new one. A
      # forked process never reuses its parent's connections.
      def connection(uri, timeout)
        pool = Thread.current[@key]
        pool = Thread.current[@key] = { pid: Process.pid } if pool.nil? || pool[:pid] != Process.pid
        http = pool[origin(uri)]
        unless http&.started?
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = timeout
          http.max_retries = 0 # the client decides what is retried
          http.start
          pool[origin(uri)] = http
        end
        http.read_timeout = timeout
        http.write_timeout = timeout
        http
      end

      def close(uri)
        http = Thread.current[@key].delete(origin(uri))
        http.finish if http&.started?
      end

      def origin(uri)
        "#{uri.scheme}://#{uri.host}:#{uri.port}"
      end
    end
  end
end
