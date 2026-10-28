# frozen_string_literal: true

require "test_helper"

class ErrorsTest < Minitest::Test
  TABLE = [
    [400, "validation_error", ZapSMTP::ValidationError], [401, "invalid_api_key", ZapSMTP::AuthenticationError],
    [403, "restricted_api_key", ZapSMTP::PermissionError], [404, "not_found", ZapSMTP::NotFoundError],
    [409, "conflict", ZapSMTP::ConflictError], [413, "payload_too_large", ZapSMTP::ValidationError],
    [422, "invalid_parameter", ZapSMTP::ValidationError], [429, "monthly_quota_exceeded", ZapSMTP::RateLimitError],
    [500, "internal_error", ZapSMTP::ServerError], [410, "link_expired", ZapSMTP::Error]
  ].freeze

  TABLE.each do |status, code, klass|
    define_method("test_maps_#{status}_#{code}") do
      zap = client(StubTransport.new(api_error(status, code)), max_retries: 0)
      error = assert_raises(klass) { zap.emails.get("x") }
      assert_equal klass, error.class
      assert_kind_of ZapSMTP::Error, error
      assert_equal status, error.status
      assert_equal code, error.code
      assert_equal "#{code} happened", error.message
      assert_equal "invalid_request_error", error.type
      assert_equal "req_1", error.request_id
      assert_equal "application/json", error.headers["content-type"]
      assert_equal code, error.body[:error][:code]
    end
  end

  def test_reads_the_flat_error_shape_and_a_body_that_is_not_json
    flat = client(StubTransport.new(json(422, { statusCode: 422, name: "missing_required_field",
                                                message: "subject is required" })))
    error = assert_raises(ZapSMTP::ValidationError) { flat.emails.get("x") }
    assert_equal ["missing_required_field", "subject is required", ""], [error.code, error.message, error.type]

    text = client(StubTransport.new(raw(418, "bad gateway")))
    error = assert_raises(ZapSMTP::Error) { text.emails.get("x") }
    assert_equal [418, "", "HTTP 418", nil, "bad gateway"],
                 [error.status, error.code, error.message, error.request_id, error.body]

    odd = client(StubTransport.new(json(400, { error: "nope" })))
    error = assert_raises(ZapSMTP::ValidationError) { odd.emails.get("x") }
    assert_equal ["", "HTTP 400"], [error.code, error.message]
  end

  def test_an_error_built_by_hand
    error = ZapSMTP::Error.new("boom")
    assert_equal [0, "", "", nil, nil, nil],
                 [error.status, error.code, error.type, error.request_id, error.headers, error.body]
  end

  def test_gives_retry_after_on_rate_limits
    zap = client(StubTransport.new(api_error(429, "monthly_quota_exceeded", "Retry-After" => "7")))
    error = assert_raises(ZapSMTP::RateLimitError) { zap.emails.get("x") }
    assert_equal 7.0, error.retry_after
    assert_nil ZapSMTP::RateLimitError.new("x").retry_after
  end

  def test_wraps_network_failures
    failure = Errno::ECONNRESET.new("reset")
    zap = client(StubTransport.new(failure), max_retries: 0)
    error = assert_raises(ZapSMTP::ConnectionError) { zap.emails.get("x") }
    assert_equal 0, error.status
    assert_same failure, error.cause
    assert_match(/reset/, error.message)
  end

  def test_a_broken_response_body_is_a_connection_error_and_a_safe_request_is_retried
    failure = EOFError.new("connection reset while reading body")
    error = assert_raises(ZapSMTP::ConnectionError) { client(StubTransport.new(failure), max_retries: 0).emails.get("e") }
    assert_same failure, error.cause
    transport = StubTransport.new(failure, json(200, { id: "e1" }))
    zap = client(transport)
    assert_equal "e1", zap.emails.get("e1").id
    assert_equal 2, transport.calls.size
    assert_equal 1, zap.slept.size
  end
end
