# frozen_string_literal: true

require "test_helper"
require "mail"
require "pathname"
require "tempfile"
require "zapsmtp/rails"

# Regressions from Codex's review of the Ruby SDK (.codex-test/20261028-093517-codex-sdk-ruby).
class CodexDeliveryRetryTest < Minitest::Test
  def delivery(transport)
    ZapSMTP::Rails::DeliveryMethod.new(client: client(transport, max_retries: 0))
  end

  def keys(transport)
    transport.calls.map { |request| request.headers["Idempotency-Key"] }
  end

  def test_retrying_a_failed_delivery_preserves_the_explicit_idempotency_key
    transport = StubTransport.new(Errno::ECONNRESET.new, json(200, { id: "email-1" }))
    sender = delivery(transport)
    message = Mail.new(from: "a@example.test", to: "b@example.test", subject: "Receipt", body: "Paid")
    ZapSMTP::Rails.set_options(message, idempotency_key: "receipt-42")

    # the first send may have been taken before its answer was lost
    assert_raises(ZapSMTP::ConnectionError) { sender.deliver!(message) }
    sender.deliver!(message)

    assert_equal %w[receipt-42 receipt-42], keys(transport)
  end

  def test_retrying_a_failed_delivery_preserves_the_template_and_other_send_options
    transport = StubTransport.new(api_error(503, "service_unavailable"), json(200, { id: "email-1" }))
    sender = delivery(transport)
    message = Mail.new(from: "a@example.test", to: "b@example.test", subject: "Fallback", body: "Fallback body")
    ZapSMTP::Rails.set_options(message, template: { id: "receipt", variables: { total: 42 } },
                                        subject: nil, metadata: { order: "42" }, stream: "broadcast")

    assert_raises(ZapSMTP::ServerError) { sender.deliver!(message) }
    sender.deliver!(message)

    first, second = transport.calls.map { |request| JSON.parse(request.body) }
    assert_equal "receipt", first.fetch("template").fetch("id")
    assert_equal({ "order" => "42" }, first["metadata"])
    assert_equal "broadcast", first["stream"]
    refute first.key?("text")
    refute first.key?("subject")
    refute first.key?("headers") # the SDK's own headers are never sent as custom headers
    assert_equal first, second
    assert_equal 1, keys(transport).uniq.size
    assert_nil message[ZapSMTP::Rails::OPTIONS_HEADER]
    assert_equal "email-1", message[ZapSMTP::Rails::EMAIL_ID_HEADER].value
  end

  def test_a_message_without_a_key_gets_one_that_its_retries_reuse
    transport = StubTransport.new(Errno::ECONNRESET.new, json(200, { id: "email-1" }))
    sender = delivery(transport)
    message = Mail.new(from: "a@example.test", to: "b@example.test", subject: "Hi", body: "x")

    assert_raises(ZapSMTP::ConnectionError) { sender.deliver!(message) }
    kept = ZapSMTP::Rails.options(message)["idempotency_key"]
    assert_match(/\A[0-9a-f-]{36}\z/, kept)
    sender.deliver!(message)
    assert_equal [kept, kept], keys(transport)
    refute JSON.parse(transport.calls.last.body).key?("idempotency_key")

    # delivered again on purpose after it was sent: a new send, a new key
    sender.deliver!(message)
    refute_equal kept, keys(transport).last
    refute JSON.parse(transport.calls.last.body).key?("headers")
  end
end

class CodexPathnameUploadTest < Minitest::Test
  def test_a_pathname_upload_preserves_the_basename_content_type_and_bytes
    transport = StubTransport.new(json(201, { id: "asset-1" }))
    zap = client(transport)
    bytes = "\x89PNG\r\n\x1a\n\x00\xff".b

    Tempfile.create(["codex-sdk-ruby", ".png"]) do |file|
      file.binmode
      file.write(bytes)
      file.flush
      zap.template_assets.upload_file(Pathname.new(file.path))

      request = transport.calls.last
      assert_includes request.body, "filename=\"#{File.basename(file.path)}\"\r\nContent-Type: image/png".b
      assert_includes request.body, "\r\n\r\n".b + bytes + "\r\n".b
    end
  end
end

class CodexTruncatedBodyTest < Minitest::Test
  # A response Net::HTTP read partly, without sockets.
  def partial(encoding, decode_content: true)
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response["Content-Length"] = "100"
    response["Content-Encoding"] = encoding if encoding
    response.decode_content = decode_content
    response.define_singleton_method(:body) { '{"id":"email-1"}' }
    response.define_singleton_method(:read_body) { body }
    response
  end

  def read(response)
    ZapSMTP::Transport::NetHTTP.new.send(:read_body, response)
  end

  def test_identity_content_encoding_does_not_disable_truncation_detection
    assert_raises(EOFError) { read(partial("identity")) }
    assert_raises(EOFError) { read(partial("IDENTITY")) }
  end

  def test_an_encoding_net_http_did_not_inflate_is_still_checked
    assert_raises(EOFError) { read(partial("br")) }
    assert_raises(EOFError) { read(partial("gzip", decode_content: false)) }
  end

  def test_an_inflated_body_is_not_measured_against_the_compressed_length
    assert_nil read(partial("gzip"))
    assert_nil read(partial("Deflate"))
  end
end

# Rules every SDK shares (Codex, .NET review): empty Idempotency-Keys, header case,
# numbers that are not finite, absurd Retry-After values.
class CodexSharedRulesTest < Minitest::Test
  def refused(transport, &block)
    error = assert_raises(ZapSMTP::ValidationError, &block)
    assert_equal ["idempotency_key must not be empty", "invalid_parameter", 0],
                 [error.message, error.code, error.status]
    assert_empty transport.calls
  end

  def test_an_empty_or_blank_idempotency_key_is_refused_before_sending
    transport = StubTransport.new(json(200, { id: "e1" }))
    zap = client(transport)
    params = { from: "a", to: "b", subject: "s", text: "t" }
    ["", "   ", "\t"].each do |key|
      refused(transport) { zap.emails.send(params, request_options: { idempotency_key: key }) }
      refused(transport) { zap.emails.send(params, request_options: { headers: { "idempotency-key" => key } }) }
      refused(transport) do
        zap.domains.create({ name: "a.test" }, request_options: { headers: { "IDEMPOTENCY-KEY" => key } })
      end
    end
    refused(transport) { client(transport, default_headers: { "Idempotency-Key" => " " }).usage.get }
  end

  def test_the_callers_header_replaces_the_sdks_own_whatever_its_case
    transport = StubTransport.new(json(200, { id: "e1" }))
    zap = client(transport, default_headers: { "user-agent" => "mine/1.0", "X-Team" => "a" })
    zap.emails.send({ from: "a", to: "b", subject: "s" },
                    request_options: { idempotency_key: "k1", headers: { "idempotency-key" => "k2", "x-team" => "b" } })
    headers = transport.calls[0].headers
    assert_equal({ "authorization" => "Bearer zap_test_key", "accept" => "application/json", "user-agent" => "mine/1.0",
                   "idempotency-key" => "k2", "x-team" => "b", "content-type" => "application/json" },
                 headers.transform_keys(&:downcase))
    assert_equal(1, headers.keys.count { |k| k.casecmp?("idempotency-key") })
    zap.emails.send_batch([{ from: "a" }], request_options: { headers: { "X-BATCH-VALIDATION" => "strict" } })
    assert_equal({ "X-BATCH-VALIDATION" => "strict" }, transport.calls[1].headers.select { |k, _| k =~ /batch/i })
  end

  def test_the_rails_delivery_method_refuses_an_empty_key
    transport = StubTransport.new(json(200, { id: "e1" }))
    sender = ZapSMTP::Rails::DeliveryMethod.new(client: client(transport))
    message = Mail.new(from: "a@example.test", to: "b@example.test", subject: "Hi", body: "x")
    ZapSMTP::Rails.set_options(message, idempotency_key: " ")
    error = assert_raises(ZapSMTP::ValidationError) { sender.deliver!(message) }
    assert_equal "idempotency_key must not be empty", error.message
    assert_empty transport.calls
  end

  def test_a_number_that_is_not_finite_becomes_nil
    body = '{"id":"e1","score":1e400,"low":-1e400,"ok":1.5,"n":NaN,"list":[Infinity,2],"deep":{"x":-Infinity}}'
    email = client(StubTransport.new(raw(200, body))).emails.get("e1")
    assert_equal({ id: "e1", score: nil, low: nil, ok: 1.5, n: nil, list: [nil, 2], deep: { x: nil } }, email.to_h)
    t = 1_700_000_000
    payload = '{"type":"x","data":{"v":1e400}}'
    header = "t=#{t},v1=#{OpenSSL::HMAC.hexdigest("SHA256", "whsec_x", "#{t}.#{payload}")}"
    assert_nil ZapSMTP::Webhook.verify(payload, header, "whsec_x", now: t).data[:v]
  end

  def test_retry_after_never_raises_on_an_absurd_value
    ["1e400", "-1e400", "NaN", "Infinity", "Thu, 01 Jan 99999999999999999999 00:00:00 GMT", "9" * 400,
     "Mon, 99 Foo 2026 99:99:99 GMT", "\u0000"].each do |value|
      seconds = ZapSMTP::Retry.retry_after({ "retry-after" => value })
      assert(seconds.nil? || (seconds.finite? && seconds >= 0), "#{value.inspect} -> #{seconds.inspect}")
    end
    transport = StubTransport.new(api_error(503, "s", "Retry-After" => "1e400"), json(200, { id: "e1" }))
    zap = client(transport)
    assert_equal "e1", zap.emails.get("e1").id
    assert_operator zap.slept[0], :<=, 1.0
    assert_equal 60.0, ZapSMTP::Retry.backoff(0, ZapSMTP::Retry.retry_after({ "retry-after" => "9" * 300 }))
  end
end
