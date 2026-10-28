# frozen_string_literal: true

require "test_helper"
require "socket"
require "stringio"
require "zlib"

# The default transport against small local HTTP servers.
class TransportTest < Minitest::Test
  # A server that runs handler(client socket, request text) for each connection.
  def serve(handler)
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      loop do
        socket = server.accept
        Thread.new(socket) do |s|
          handler.call(s)
        rescue IOError, SystemCallError
          nil
        ensure
          s.close unless s.closed?
        end
      end
    rescue IOError
      nil
    end
    yield "http://127.0.0.1:#{server.addr[1]}"
  ensure
    server&.close
    thread&.kill
  end

  # Reads one request (head and body) from a socket.
  def read_request(socket)
    head = +""
    head << socket.readpartial(4096) until head.include?("\r\n\r\n")
    head, body = head.split("\r\n\r\n", 2)
    length = head[/content-length: (\d+)/i, 1].to_i
    body << socket.readpartial(4096) while body.bytesize < length
    [head, body]
  end

  def respond(socket, body, status: "200 OK", extra: "")
    socket.write("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\nX-Request-Id: req_t\r\n#{extra}" \
                 "Content-Length: #{body.bytesize}\r\n\r\n#{body}")
  end

  def test_sends_requests_and_keeps_the_connection_alive
    seen = Queue.new
    connections = Queue.new
    handler = lambda do |socket|
      connections << socket
      loop do
        head, body = read_request(socket)
        seen << [head, body]
        respond(socket, %({"id":"e1","subject":"Привет"}), extra: "Set-Cookie: a=1\r\nSet-Cookie: b=2\r\n")
      end
    end
    serve(handler) do |url|
      zap = ZapSMTP::Client.new(api_key: "zap_t", base_url: "#{url}/v1")
      email = zap.emails.send(from: "a@x.test", to: "b@y.test", subject: "Привет", text: "x")
      assert_equal "Привет", email[:subject]
      assert_equal Encoding::UTF_8, email[:subject].encoding
      assert_equal "a=1, b=2", email.http_response["set-cookie"]
      assert_equal "req_t", email.http_response.request_id
      head, body = seen.pop
      assert_match(%r{\APOST /v1/emails HTTP/1.1}, head)
      assert_match(/^Authorization: Bearer zap_t/i, head)
      assert_match(/^Idempotency-Key: [0-9a-f-]{36}/i, head)
      assert_equal "Привет", JSON.parse(body.force_encoding("UTF-8"))["subject"]
      zap.emails.get("e1")
      head, = seen.pop
      assert_match(%r{\AGET /v1/emails/e1 HTTP/1.1}, head)
      assert_equal 1, connections.size
    end
  end

  def test_a_forked_process_does_not_reuse_its_parents_connections
    connections = Queue.new
    handler = lambda do |socket|
      connections << socket
      loop do
        read_request(socket)
        respond(socket, "{}")
      end
    end
    serve(handler) do |url|
      transport = ZapSMTP::Transport::NetHTTP.new
      zap = ZapSMTP::Client.new(api_key: "k", base_url: url, transport: transport)
      zap.usage.get
      Thread.current[transport.instance_variable_get(:@key)][:pid] = -1 # as if forked
      zap.usage.get
      assert_equal 2, connections.size
    end
  end

  def test_a_refused_connection_is_a_connection_error
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    zap = ZapSMTP::Client.new(api_key: "k", base_url: "http://127.0.0.1:#{port}", max_retries: 0)
    error = assert_raises(ZapSMTP::ConnectionError) { zap.usage.get }
    assert_kind_of SystemCallError, error.cause
  end

  def test_tls_to_a_plain_server_fails_as_a_connection_error
    serve(->(socket) { socket.write("HTTP/1.1 200 OK\r\n\r\n") }) do |url|
      zap = ZapSMTP::Client.new(api_key: "k", base_url: url.sub("http:", "https:"), max_retries: 0, timeout: 2)
      assert_raises(ZapSMTP::ConnectionError) { zap.usage.get }
    end
  end

  def test_times_out_when_the_answer_never_comes
    serve(->(socket) { read_request(socket) && sleep(2) }) do |url|
      zap = ZapSMTP::Client.new(api_key: "k", base_url: url, max_retries: 0, timeout: 0.2)
      error = assert_raises(ZapSMTP::ConnectionError) { zap.usage.get }
      assert_equal "timed out after 0.2 s", error.message
      assert_equal 0, error.status
      assert_kind_of Net::ReadTimeout, error.cause.cause
    end
  end

  def test_the_timeout_also_bounds_reading_the_response_body
    stall = lambda do |socket|
      read_request(socket)
      socket.write("HTTP/1.1 200 OK\r\nX-Request-Id: req_stall\r\nContent-Length: 100\r\n\r\n{")
      sleep 2
    end
    serve(stall) do |url|
      zap = ZapSMTP::Client.new(api_key: "k", base_url: url, max_retries: 0, timeout: 0.2)
      error = assert_raises(ZapSMTP::ConnectionError) { zap.emails.get("e") }
      assert_match(/timed out after 0.2 s/, error.message)
      assert_equal [200, "req_stall"], [error.status, error.request_id]
    end
  end

  def test_inflates_a_compressed_answer
    gzip = lambda do |socket|
      read_request(socket)
      packed = StringIO.new.tap { |io| Zlib::GzipWriter.wrap(io) { |gz| gz.write(%({"id":"gz"})) } }.string
      respond(socket, packed, extra: "Content-Encoding: gzip\r\n")
    end
    serve(gzip) do |url|
      zap = ZapSMTP::Client.new(api_key: "k", base_url: url, max_retries: 0)
      assert_equal "gz", zap.emails.get("e").id
    end
  end

  def test_a_body_cut_short_is_retried_when_safe
    calls = Queue.new
    handler = lambda do |socket|
      read_request(socket)
      calls << 1
      if calls.size == 1
        socket.write("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n{\"id\"")
      else
        respond(socket, %({"id":"e1"}), extra: "Connection: close\r\n")
      end
    end
    serve(handler) do |url|
      zap = ZapSMTP::Client.new(api_key: "k", base_url: url)
      zap.define_singleton_method(:sleep_for) { |_| nil }
      assert_equal "e1", zap.emails.get("e1").id
      assert_equal 2, calls.size
      zap2 = ZapSMTP::Client.new(api_key: "k", base_url: url, max_retries: 0)
      calls.clear
      error = assert_raises(ZapSMTP::ConnectionError) { zap2.emails.get("e1") }
      assert_match(/cut short: 5 of 100 bytes/, error.message)
      assert_equal 200, error.status
      assert_equal "100", error.headers["content-length"]
    end
  end
end
