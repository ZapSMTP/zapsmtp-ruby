# frozen_string_literal: true

module ZapSMTP
  # An error answer of the API, or no answer at all (ConnectionError). Every
  # error the library raises is a ZapSMTP::Error.
  class Error < StandardError
    # @return [Integer] the HTTP status; 0 when there was no answer
    attr_reader :status
    # @return [String] the API's error code, e.g. "invalid_parameter"; "" when there is none
    attr_reader :code
    # @return [String] the error type, e.g. "invalid_request_error"; "" when there is none
    attr_reader :type
    # @return [String, nil] X-Request-Id: quote it to support
    attr_reader :request_id
    # @return [Hash{String => String}, nil] the response headers, names in lower case
    attr_reader :headers
    # @return [Object] the parsed error body (a Hash with symbol keys), or its text
    attr_reader :body

    def initialize(message = nil, status: 0, code: "", type: "", request_id: nil, headers: nil, body: nil)
      super(message)
      @status = status
      @code = code
      @type = type
      @request_id = request_id
      @headers = headers
      @body = body
    end

    # The error class for an error answer.
    #
    # @api private
    def self.from_response(status, body, headers)
      hash = body.is_a?(Hash) ? body : {}
      error = hash[:error].is_a?(Hash) ? hash[:error] : {}
      code = error[:code] || hash[:name] || ""
      message = error[:message] || hash[:message] || "HTTP #{status}"
      class_for(status).new(message.to_s, status: status, code: code.to_s, type: (error[:type] || "").to_s,
                                          request_id: headers["x-request-id"], headers: headers, body: body)
    end

    # @api private
    def self.class_for(status)
      case status
      when 401 then AuthenticationError
      when 403 then PermissionError
      when 404 then NotFoundError
      when 409 then ConflictError
      when 400, 413, 422 then ValidationError
      when 429 then RateLimitError
      when 500.. then ServerError
      else Error
      end
    end
  end

  # 401: the API key is missing or invalid.
  class AuthenticationError < Error; end

  # 403: the key may not do this, or the domain is not verified.
  class PermissionError < Error; end

  # 404: no such resource.
  class NotFoundError < Error; end

  # 409: a conflict, e.g. the same Idempotency-Key with another request.
  class ConflictError < Error; end

  # 400, 413, 422: the request is wrong.
  class ValidationError < Error; end

  # 429: too many requests, or a quota is used up.
  class RateLimitError < Error
    # @return [Float, nil] seconds the API asked to wait (Retry-After), when it said
    def retry_after
      Retry.retry_after(headers)
    end
  end

  # 5xx: the API failed.
  class ServerError < Error; end

  # No answer: a network failure or a timeout. #cause holds the underlying error.
  class ConnectionError < Error; end

  # A webhook request whose signature is missing, wrong or too old, or whose body is not JSON.
  class WebhookVerificationError < Error; end
end
