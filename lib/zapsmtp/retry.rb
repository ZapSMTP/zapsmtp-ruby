# frozen_string_literal: true

require "time"

module ZapSMTP
  # When a failed request is tried again, and after how long
  # (docs/DESIGN-sdks.md, retries).
  module Retry
    RETRY_STATUSES = [408, 429, 500, 502, 503, 504].freeze
    NO_RETRY_429 = %w[monthly_quota_exceeded daily_quota_exceeded thread_reply_limit].freeze

    module_function

    # Whether an error answer is worth another attempt. A 429 was refused
    # before any work, so it is always safe; other statuses only for a
    # request that is safe to repeat.
    def retryable?(status, code, safe)
      return !NO_RETRY_429.include?(code) if status == 429
      return code == "idempotency_request_in_progress" if status == 409

      safe && RETRY_STATUSES.include?(status)
    end

    # Seconds to wait before attempt number attempt + 1: Retry-After up to 60
    # seconds, else exponential backoff (0.5, 1, 2 ... capped at 8) with jitter.
    def backoff(attempt, retry_after)
      return [retry_after, 60].min.to_f if retry_after

      base = [0.5 * (2**attempt), 8.0].min
      (base / 2) + (rand * (base / 2))
    end

    # The Retry-After header in seconds (a number or an HTTP date), or nil.
    def retry_after(headers)
      value = headers && headers["retry-after"]
      return nil if value.nil? || value.strip.empty?

      seconds = Float(value, exception: false)
      return [seconds, 0.0].max if seconds&.finite?

      begin
        [Time.httpdate(value.strip) - Time.now, 0.0].max
      rescue ArgumentError, RangeError
        nil
      end
    end
  end
end
