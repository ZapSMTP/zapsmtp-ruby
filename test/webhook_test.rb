# frozen_string_literal: true

require "test_helper"
require "openssl"
require "stringio"

class WebhookTest < Minitest::Test
  VECTORS = JSON.parse(File.read(File.join(SDKS, "spec/webhook-vectors.json")))["vectors"]
  FIRST = VECTORS.first

  def verify(vector, headers = { "Zap-Signature" => vector["header"] }, method: :verify)
    options = { now: vector["now"], tolerance: vector["tolerance"] }.compact
    ZapSMTP::Webhook.public_send(method, vector["payload"], headers, vector["secret"], **options)
  end

  def test_has_every_vector
    assert_equal 17, VECTORS.size
  end

  VECTORS.each_with_index do |vector, i|
    define_method("test_vector_#{i}_#{vector["name"].gsub(/\W+/, "_")}") do
      payload = JSON.parse(vector["payload"], symbolize_names: true)
      if !vector["valid"]
        assert_raises(ZapSMTP::WebhookVerificationError) { verify(vector) }
        assert_raises(ZapSMTP::WebhookVerificationError) { verify(vector, method: :verify_events) }
      elsif vector["batch"]
        error = assert_raises(ZapSMTP::WebhookVerificationError) { verify(vector) }
        assert_match(/batch of events: use verify_events/, error.message)
        assert_equal payload, verify(vector, method: :verify_events).map(&:to_h)
      else
        event = verify(vector)
        assert_instance_of ZapSMTP::WebhookEvent, event
        assert_equal payload, event.to_h
        assert_equal [payload], verify(vector, method: :verify_events).map(&:to_h)
      end
    end
  end

  def test_refuses_a_signed_body_that_is_not_an_event
    t = 1_700_000_000
    ["42", "null", "[1]", "[[]]", '"s"'].each do |body|
      header = sign("whsec_x", t, body)
      error = assert_raises(ZapSMTP::WebhookVerificationError) do
        ZapSMTP::Webhook.verify_events(body, header, "whsec_x", now: t)
      end
      assert_match(/not an event/, error.message)
      next if body.start_with?("[")

      error = assert_raises(ZapSMTP::WebhookVerificationError) { ZapSMTP::Webhook.verify(body, header, "whsec_x", now: t) }
      assert_match(/not an event/, error.message)
    end
    zap = ZapSMTP::Client.new(api_key: "k", transport: StubTransport.new)
    assert_equal [{}], zap.webhooks.verify_events("{}", sign("whsec_x", t, "{}"), "whsec_x", now: t).map(&:to_h)
  end

  def test_refuses_an_oversized_timestamp
    assert_match(/Malformed/, refusal("{}", "t=1234567890123,v1=#{"0" * 64}", "s"))
  end

  def test_takes_headers_in_any_form_bytes_and_the_client_method
    event = verify(FIRST)
    assert_equal ["evt_1", "email.delivered", "2026-01-01T00:00:00Z"], [event.id, event.type, event.created_at]
    assert_equal "Привет ✓", event.data[:subject]
    assert_equal "evt_1", verify(FIRST, FIRST["header"]).id
    assert_equal "evt_1", verify(FIRST, { "zap-signature" => [FIRST["header"]] }).id
    assert_equal "evt_1", verify(FIRST, { "HTTP_ZAP_SIGNATURE" => FIRST["header"], "rack.input" => StringIO.new }).id
    assert_equal "evt_1", verify(FIRST, { zap_signature: FIRST["header"] }).id
    binary = FIRST["payload"].b
    assert_equal "evt_1", ZapSMTP::Webhook.verify(binary, FIRST["header"], FIRST["secret"], now: FIRST["now"]).id
    zap = ZapSMTP::Client.new(api_key: "k", transport: StubTransport.new)
    assert_equal "evt_1", zap.webhooks.verify(FIRST["payload"], FIRST["header"], FIRST["secret"], now: FIRST["now"]).id
  end

  def test_checks_against_the_clock_by_default
    t = Time.now.to_i
    payload = '{"id":"evt_2","type":"email.sent"}'
    assert_equal "evt_2", ZapSMTP::Webhook.verify(payload, sign("whsec_x", t - 10, payload), "whsec_x").id
    error = assert_raises(ZapSMTP::WebhookVerificationError) do
      ZapSMTP::Webhook.verify(payload, sign("whsec_x", t - 301, payload), "whsec_x")
    end
    assert_match(/too old/, error.message)
    assert_equal "evt_2", ZapSMTP::Webhook.verify(payload, sign("whsec_x", t - 301, payload), "whsec_x",
                                                  tolerance: 600).id
  end

  def test_refuses_a_missing_header_or_secret_a_malformed_header_and_a_body_that_is_not_json
    assert_match(/Missing Zap-Signature/, refusal("{}", {}, "s"))
    assert_match(/Missing Zap-Signature/, refusal("{}", nil, "s"))
    assert_match(/Missing Zap-Signature/, refusal("{}", "", "s"))
    assert_match(/Missing Zap-Signature/, refusal("{}", { "Other" => "x" }, "s"))
    assert_match(/Missing webhook secret/, refusal("{}", "t=1,v1=00", ""))
    assert_match(/Missing webhook secret/, refusal("{}", "t=1,v1=00", nil))
    assert_match(/Malformed/, refusal("{}", "t=abc,v1=00", "s"))
    assert_match(/Malformed/, refusal("{}", "t=1", "s"))
    assert_match(/Malformed/, refusal("{}", "v1=00,junk,,x", "s"))
    assert_match(/does not match/, refusal("{}", "t=#{Time.now.to_i},v1=zz", "s"))
    t = 1_700_000_000
    assert_match(/not JSON/, refusal("not json", sign("whsec_x", t, "not json"), "whsec_x", now: t))
    bad = "\xff\xfe".b
    assert_match(/not JSON/, refusal(bad, sign("whsec_x", t, bad), "whsec_x", now: t))
  end

  private

  def sign(secret, time, payload)
    "t=#{time},v1=#{OpenSSL::HMAC.hexdigest("SHA256", secret, "#{time}.#{payload}")}"
  end

  def refusal(payload, headers, secret, **options)
    assert_raises(ZapSMTP::WebhookVerificationError) do
      ZapSMTP::Webhook.verify(payload, headers, secret, **options)
    end.message
  end
end

class WebhookMiddlewareTest < Minitest::Test
  SECRET = "whsec_mw"

  def app
    ->(env) { [200, {}, [env["zapsmtp.event"]&.type.to_s, env["zapsmtp.events"]&.size.to_s]] }
  end

  def env(body, signature, path = "/webhooks/zapsmtp")
    { "PATH_INFO" => path, "rack.input" => StringIO.new(body), "HTTP_ZAP_SIGNATURE" => signature }
  end

  def signed(body)
    t = Time.now.to_i
    "t=#{t},v1=#{OpenSSL::HMAC.hexdigest("SHA256", SECRET, "#{t}.#{body}")}"
  end

  def test_passes_a_signed_request_with_its_event
    body = '{"id":"evt_1","type":"email.bounced"}'
    mw = ZapSMTP::WebhookMiddleware.new(app, secret: SECRET, path: "/webhooks/zapsmtp")
    request = env(body, signed(body))
    status, _, out = mw.call(request)
    assert_equal [200, ["email.bounced", "1"]], [status, out]
    assert_equal body, request["rack.input"].read
  end

  def test_refuses_a_bad_signature
    mw = ZapSMTP::WebhookMiddleware.new(app, secret: SECRET)
    status, headers, out = mw.call(env("{}", "t=1,v1=00"))
    assert_equal 400, status
    assert_equal "application/json", headers["content-type"]
    assert_match(/too old/, JSON.parse(out.first)["error"])
    status, = mw.call({ "PATH_INFO" => "/x" })
    assert_equal 400, status
  end

  def test_leaves_other_paths_alone
    mw = ZapSMTP::WebhookMiddleware.new(app, secret: SECRET, path: "/webhooks/zapsmtp")
    assert_equal 200, mw.call(env("{}", "bad", "/other")).first
  end

  def test_reads_an_input_that_cannot_rewind
    body = '{"type":"email.sent"}'
    input = Object.new
    input.define_singleton_method(:read) { body }
    with_env("ZAP_WEBHOOK_SECRET" => SECRET) do
      mw = ZapSMTP::WebhookMiddleware.new(app)
      assert_equal ["email.sent", "1"], mw.call({ "rack.input" => input, "HTTP_ZAP_SIGNATURE" => signed(body) }).last
    end
  end

  def test_passes_a_batch_with_its_events
    body = '[{"type":"email.sent"},{"type":"email.delivered"}]'
    mw = ZapSMTP::WebhookMiddleware.new(app, secret: SECRET)
    assert_equal [200, ["", "2"]], mw.call(env(body, signed(body))).values_at(0, 2)
    t = Time.now.to_i
    status, = mw.call(env("[1]", "t=#{t},v1=#{OpenSSL::HMAC.hexdigest("SHA256", SECRET, "#{t}.[1]")}"))
    assert_equal 400, status
  end
end
