# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tempfile"

class ClientTest < Minitest::Test
  def test_reads_the_key_and_base_url_from_the_environment
    with_env("ZAP_API_KEY" => "zap_env", "ZAP_BASE_URL" => "https://env.test/v1") do
      transport = StubTransport.new(json(200, { id: "e1" }))
      zap = ZapSMTP::Client.new(transport: transport)
      assert_equal "zap_env", zap.api_key
      zap.emails.get("e1")
      assert_equal "https://env.test/v1/emails/e1", transport.calls[0].url
      assert_equal "Bearer zap_env", transport.calls[0].headers["Authorization"]
    end
  end

  def test_defaults
    with_env("ZAP_BASE_URL" => nil) do
      zap = ZapSMTP::Client.new(api_key: "k")
      assert_equal "https://api.zapsmtp.com/v1", zap.base_url
      assert_equal 60, zap.timeout
      assert_equal 2, zap.max_retries
      assert_instance_of ZapSMTP::Transport::NetHTTP, zap.transport
    end
    with_env("ZAP_BASE_URL" => "") do
      assert_equal "https://api.zapsmtp.com/v1", ZapSMTP::Client.new(api_key: "k").base_url
    end
  end

  def test_needs_a_key
    with_env("ZAP_API_KEY" => nil) do
      error = assert_raises(ZapSMTP::Error) { ZapSMTP::Client.new }
      assert_match(/Missing API key/, error.message)
      assert_raises(ZapSMTP::Error) { ZapSMTP::Client.new(api_key: "") }
    end
  end

  def test_does_not_show_the_key
    zap = ZapSMTP::Client.new(api_key: "zap_secret", transport: StubTransport.new)
    refute_includes zap.inspect, "zap_secret"
    assert_includes zap.inspect, "https://api.zapsmtp.com/v1"
  end

  def test_sends_the_headers_every_request_carries
    transport = StubTransport.new(json(200, { id: "x" }))
    zap = client(transport, default_headers: { "X-Team" => "mail" })
    zap.emails.get("a/b c", request_options: { headers: { "X-Extra" => 1 } })
    h = transport.calls[0].headers
    assert_equal "https://api.test/v1/emails/a%2Fb%20c", transport.calls[0].url
    assert_equal "zapsmtp-ruby/#{ZapSMTP::VERSION} (ruby/#{RUBY_VERSION})", h["User-Agent"]
    assert_match(%r{\Azapsmtp-ruby/\d+\.\d+\.\d+ }, h["User-Agent"])
    assert_equal "application/json", h["Accept"]
    assert_equal "mail", h["X-Team"]
    assert_equal "1", h["X-Extra"]
    assert_nil h["Content-Type"]
    assert_nil transport.calls[0].body
    assert_equal "GET", transport.calls[0].http_method
    assert_equal 60, transport.calls[0].timeout
  end

  def test_refuses_an_id_that_cannot_be_a_path_segment_before_sending
    transport = StubTransport.new(json(200, {}))
    zap = client(transport)
    [["", "id must not be empty"], [nil, "id must not be empty"], [".", 'id must not be "."'],
     ["..", 'id must not be ".."']].each do |id, message|
      error = assert_raises(ZapSMTP::ValidationError) { zap.emails.get(id) }
      assert_equal [message, "invalid_parameter", 0], [error.message, error.code, error.status]
    end
    error = assert_raises(ZapSMTP::ValidationError) { zap.emails.receiving.attachments.get("m1", "") }
    assert_equal "aid must not be empty", error.message
    assert_empty transport.calls
    zap.emails.get("...")
    zap.suppressions.get("a+b@x.test")
    assert_equal %w[https://api.test/v1/emails/... https://api.test/v1/suppressions/a%2Bb%40x.test],
                 transport.calls.map(&:url)
  end

  def test_sends_empty_collections_the_caller_set
    transport = StubTransport.new(json(200, { id: "e1" }))
    client(transport).emails.send(from: "a", to: [], subject: "s", tags: [], metadata: {}, headers: {})
    assert_equal({ "from" => "a", "to" => [], "subject" => "s", "tags" => [], "metadata" => {}, "headers" => {} },
                 JSON.parse(transport.calls[0].body))
  end

  def test_refuses_unknown_request_options
    zap = client(StubTransport.new(json(200, {})))
    error = assert_raises(ArgumentError) { zap.usage.get(request_options: { idempotencyKey: "x" }) }
    assert_match(/idempotencyKey/, error.message)
    zap.usage.get(request_options: { "timeout" => 5 })
    zap.usage.get(request_options: nil)
  end

  def test_serializes_query_parameters
    transport = StubTransport.new(json(200, { object: "list", data: [], has_more: false }))
    zap = client(transport)
    zap.emails.list(limit: 5, q: nil, metadata: { order_id: "A-1", "a b" => "c" })
    assert_equal "https://api.test/v1/emails?limit=5&metadata%5Border_id%5D=A-1&metadata%5Ba+b%5D=c",
                 transport.calls[0].url
    zap.request(method: :get, path: "/x",
                query: { tag: %w[a b], none: nil, at: Time.utc(2026, 1, 2, 3, 4, 5), on: true })
    assert_equal "https://api.test/v1/x?tag=a&tag=b&at=2026-01-02T03%3A04%3A05Z&on=true", transport.calls[1].url
  end

  def test_takes_params_as_a_hash_or_keywords
    transport = StubTransport.new(json(200, { id: "e1" }))
    zap = client(transport)
    zap.emails.send({ from: "a@x.test", "to" => "b@y.test" }, subject: "Hi")
    assert_equal({ "from" => "a@x.test", "to" => "b@y.test", "subject" => "Hi" }, JSON.parse(transport.calls[0].body))
    error = assert_raises(ArgumentError) { zap.emails.send("from") }
    assert_match(/params must be a Hash/, error.message)
  end

  def test_sends_json_bodies_and_an_idempotency_key_on_sends
    transport = StubTransport.new(json(200, { id: "e1" }))
    zap = client(transport)
    result = zap.emails.send(from: "a@x.test", to: "b@y.test", subject: "Hi", text: "Hello",
                             scheduled_at: Time.utc(2026, 1, 2), tags: [ZapSMTP::Models::Deleted.new(id: "t")])
    assert_instance_of ZapSMTP::Models::SendEmailResponse, result
    assert_equal "e1", result.id
    h = transport.calls[0].headers
    assert_equal "application/json", h["Content-Type"]
    assert_match(/\A[0-9a-f-]{36}\z/, h["Idempotency-Key"])
    assert_equal({ "from" => "a@x.test", "to" => "b@y.test", "subject" => "Hi", "text" => "Hello",
                   "scheduled_at" => "2026-01-02T00:00:00Z", "tags" => [{ "id" => "t" }] },
                 JSON.parse(transport.calls[0].body))
    zap.emails.send({ from: "a", to: "b", subject: "s" }, request_options: { idempotency_key: "order-1" })
    assert_equal "order-1", transport.calls[1].headers["Idempotency-Key"]
    zap.domains.create({ name: "a.test" }, request_options: { idempotency_key: "ignored" })
    assert_nil transport.calls[2].headers["Idempotency-Key"]
  end

  def test_sends_an_empty_body_for_a_body_operation_without_params
    transport = StubTransport.new(json(200, { id: "a" }))
    client(transport).api_keys.update("k1")
    assert_equal "{}", transport.calls[0].body
    assert_equal "PATCH", transport.calls[0].http_method
  end

  def test_sends_a_batch_with_its_validation_mode
    transport = StubTransport.new(json(200, { data: [] }))
    zap = client(transport)
    zap.emails.send_batch([{ from: "a", to: "b", subject: "s" }])
    refute transport.calls[0].headers.key?("x-batch-validation")
    assert_equal [{ "from" => "a", "to" => "b", "subject" => "s" }], JSON.parse(transport.calls[0].body)
    zap.emails.send_batch([{ from: "a", to: "b", subject: "s" }], validation: "permissive")
    assert_equal "permissive", transport.calls[1].headers["x-batch-validation"]
  end

  def test_answers_nil_for_204
    assert_nil client(StubTransport.new(raw(204, ""))).domains.delete("d1")
    assert_nil client(StubTransport.new(raw(204, nil))).domains.delete("d1")
  end

  def test_keeps_a_body_that_is_not_json_as_text
    assert_equal "plain", client(StubTransport.new(raw(200, "plain"))).usage.get
    assert_equal [1, 2], client(StubTransport.new(raw(200, "[1,2]"))).usage.get
  end

  def test_gives_the_status_headers_and_request_id
    transport = StubTransport.new(json(200, { id: "e1" }, "RateLimit-Remaining" => "9", "X-Multi" => %w[a b]))
    zap = client(transport)
    email = zap.emails.get("e1")
    assert_equal 200, email.http_response.status
    assert_equal "req_1", email.http_response.request_id
    assert_equal "9", email.http_response["ratelimit-remaining"]
    assert_equal "9", email.http_response["RateLimit-Remaining"]
    assert_equal "a, b", email.http_response.headers["x-multi"]
    assert_match(/status=200 request_id="req_1"/, email.http_response.inspect)

    data, response = zap.with_response.emails.get("e1")
    assert_equal "e1", data.id
    assert_equal "req_1", response.request_id
    result = zap.with_response.domains.delete("d1")
    assert_instance_of ZapSMTP::Result, result
    assert_equal({ id: "e1" }, result.data.to_h)
    page, page_response = zap.with_response.emails.list
    assert_instance_of ZapSMTP::Page, page
    assert_equal 200, page_response.status
    refute_same zap.emails, zap.with_response.emails
  end

  def test_uploads_an_image_file_as_multipart
    transport = StubTransport.new(json(201, { id: "img" }))
    zap = client(transport)
    asset = zap.template_assets.upload_file(StringIO.new("\x89PNG".b), name: "logo.png")
    assert_equal "img", asset.id
    req = transport.calls[0]
    boundary = req.headers["Content-Type"][%r{\Amultipart/form-data; boundary=(.+)\z}, 1]
    refute_nil boundary
    assert_equal Encoding::BINARY, req.body.encoding
    assert_equal "--#{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"logo.png\"\r\n" \
                 "Content-Type: image/png\r\n\r\n\x89PNG\r\n--#{boundary}\r\n" \
                 "Content-Disposition: form-data; name=\"name\"\r\n\r\nlogo.png\r\n--#{boundary}--\r\n".b, req.body

    zap.template_assets.upload_file(StringIO.new("x"), filename: "a\"b.gif")
    assert_includes transport.calls[1].body, "filename=\"a%22b.gif\"\r\nContent-Type: image/gif"
    refute_includes transport.calls[1].body, "name=\"name\""

    zap.template_assets.upload_file(StringIO.new("x"))
    assert_includes transport.calls[2].body, "filename=\"image\"\r\nContent-Type: application/octet-stream"

    Tempfile.create(["banner", ".webp"]) do |f|
      f.write("RIFF")
      f.flush
      zap.template_assets.upload_file(f.path)
      assert_includes transport.calls[3].body, "filename=\"#{File.basename(f.path)}\"\r\nContent-Type: image/webp"
      assert_includes transport.calls[3].body, "RIFF"
      f.rewind
      zap.template_assets.upload_file(f)
      assert_includes transport.calls[4].body, File.basename(f.path)
    end
    zap.template_assets.upload_file(StringIO.new("x"), name: "line\r\nbreak")
    assert_includes transport.calls[5].body, "filename=\"line%0D%0Abreak\""
  end

  def test_splits_params_between_query_and_body
    params = ZapSMTP::Util.params({ a: 1 }, { b: 2, c: nil })
    assert_equal({ "a" => 1, "c" => nil }, ZapSMTP::Util.pick(params, %w[a c x]))
    assert_nil ZapSMTP::Util.pick(params, %w[x])
  end

  def test_json_upload_by_url
    transport = StubTransport.new(json(201, { id: "img" }))
    client(transport).template_assets.upload(url: "https://x.test/a.png")
    assert_equal({ "url" => "https://x.test/a.png" }, JSON.parse(transport.calls[0].body))
  end
end
