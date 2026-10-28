# frozen_string_literal: true

require "test_helper"

class RetriesTest < Minitest::Test
  def test_retries_safe_requests_on_5xx_and_network_errors_honouring_retry_after
    transport = StubTransport.new(api_error(503, "service_unavailable", "Retry-After" => "2"),
                                  Errno::ECONNRESET.new, json(200, { id: "e1" }))
    zap = client(transport)
    assert_equal "e1", zap.emails.get("e1").id
    assert_equal 3, transport.calls.size
    assert_equal 2.0, zap.slept[0]
    assert_operator zap.slept[1], :>=, 0.5
    assert_operator zap.slept[1], :<=, 1.0
  end

  def test_retries_a_send_with_the_same_idempotency_key
    transport = StubTransport.new(api_error(502, "bad_gateway"), json(200, { id: "e1" }))
    client(transport).emails.send(from: "a", to: "b", subject: "s")
    keys = transport.calls.map { |c| c.headers["Idempotency-Key"] }
    assert_equal 2, keys.size
    assert_equal keys[0], keys[1]
  end

  def test_does_not_retry_a_create_on_5xx_or_a_lost_connection_but_does_on_429
    five = StubTransport.new(api_error(500, "internal_error"))
    assert_raises(ZapSMTP::ServerError) { client(five).domains.create(name: "a.test") }
    assert_equal 1, five.calls.size
    lost = StubTransport.new(Errno::ECONNRESET.new)
    assert_raises(ZapSMTP::ConnectionError) { client(lost).domains.create(name: "a.test") }
    assert_equal 1, lost.calls.size
    limited = StubTransport.new(api_error(429, "rate_limit_exceeded", "Retry-After" => "1"), json(201, { id: "d1" }))
    zap = client(limited)
    assert_equal "d1", zap.domains.create(name: "a.test").id
    assert_equal [1.0], zap.slept
  end

  def test_retries_puts_and_deletes
    transport = StubTransport.new(api_error(504, "gateway_timeout"), raw(204, ""))
    assert_nil client(transport).domains.delete("d1")
    assert_equal 2, transport.calls.size
  end

  def test_gives_up_after_max_retries
    transport = StubTransport.new(api_error(503, "service_unavailable", "Retry-After" => "0"))
    zap = client(transport, max_retries: 3)
    assert_raises(ZapSMTP::ServerError) { zap.emails.get("x") }
    assert_equal 4, transport.calls.size
    assert_equal [0.0, 0.0, 0.0], zap.slept
    once = StubTransport.new(api_error(503, "service_unavailable"))
    assert_raises(ZapSMTP::ServerError) { client(once).emails.get("x", request_options: { max_retries: 0 }) }
    assert_equal 1, once.calls.size
  end

  def test_decides_what_is_worth_retrying
    assert ZapSMTP::Retry.retryable?(429, "overloaded", false)
    refute ZapSMTP::Retry.retryable?(429, "daily_quota_exceeded", true)
    refute ZapSMTP::Retry.retryable?(429, "monthly_quota_exceeded", true)
    refute ZapSMTP::Retry.retryable?(429, "thread_reply_limit", true)
    assert ZapSMTP::Retry.retryable?(409, "idempotency_request_in_progress", true)
    refute ZapSMTP::Retry.retryable?(409, "idempotency_key_reused", true)
    assert ZapSMTP::Retry.retryable?(503, "service_unavailable", true)
    assert ZapSMTP::Retry.retryable?(408, "request_timeout", true)
    refute ZapSMTP::Retry.retryable?(503, "service_unavailable", false)
    refute ZapSMTP::Retry.retryable?(422, "invalid_parameter", true)
  end

  def test_retries_an_idempotency_conflict_in_progress
    transport = StubTransport.new(api_error(409, "idempotency_request_in_progress"), json(200, { id: "e1" }))
    assert_equal "e1", client(transport).emails.send(from: "a", to: "b", subject: "s").id
  end

  def test_backs_off_exponentially_with_jitter_capped_or_as_retry_after_says
    8.times do |attempt|
      cap = [0.5 * (2**attempt), 8.0].min
      delay = ZapSMTP::Retry.backoff(attempt, nil)
      assert_operator delay, :>=, cap / 2
      assert_operator delay, :<=, cap
    end
    assert_equal 3.0, ZapSMTP::Retry.backoff(0, 3)
    assert_equal 60.0, ZapSMTP::Retry.backoff(0, 600)
  end

  def test_reads_retry_after_as_seconds_or_an_http_date
    assert_equal 1.5, ZapSMTP::Retry.retry_after({ "retry-after" => " 1.5 " })
    assert_equal 0.0, ZapSMTP::Retry.retry_after({ "retry-after" => "-3" })
    at = Time.now + 30
    assert_in_delta 30, ZapSMTP::Retry.retry_after({ "retry-after" => at.httpdate }), 1.5
    assert_equal 0.0, ZapSMTP::Retry.retry_after({ "retry-after" => "Thu, 01 Jan 2025 00:00:00 GMT" })
    assert_nil ZapSMTP::Retry.retry_after({ "retry-after" => "soon" })
    assert_nil ZapSMTP::Retry.retry_after({ "retry-after" => " " })
    assert_nil ZapSMTP::Retry.retry_after({})
    assert_nil ZapSMTP::Retry.retry_after(nil)
  end

  def test_waits_as_an_http_date_retry_after_says
    at = (Time.now + 3).httpdate
    transport = StubTransport.new(api_error(503, "s", "Retry-After" => at), json(200, {}))
    zap = client(transport)
    zap.emails.get("x")
    assert_in_delta 3, zap.slept[0], 1.5
    bad = client(StubTransport.new(api_error(429, "overloaded", "Retry-After" => "soon")), max_retries: 0)
    assert_nil assert_raises(ZapSMTP::RateLimitError) { bad.emails.get("x") }.retry_after
  end

  def test_sleeps_for_real_by_default
    zap = ZapSMTP::Client.new(api_key: "k", transport: StubTransport.new(api_error(503, "s", "Retry-After" => "0.01"),
                                                                         json(200, { id: "e" })))
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_equal "e", zap.emails.get("e").id
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :>=, 0.01
  end
end
