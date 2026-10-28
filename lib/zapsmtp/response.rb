# frozen_string_literal: true

module ZapSMTP
  # What the API answered besides the body: the status, the headers (rate
  # limits, quotas) and the request id.
  class Response
    # @return [Integer]
    attr_reader :status
    # @return [Hash{String => String}] names in lower case
    attr_reader :headers
    # @return [String, nil] X-Request-Id: quote it to support
    attr_reader :request_id

    def initialize(status, headers)
      @status = status
      @headers = headers
      @request_id = headers["x-request-id"]
    end

    # A header's value, its name in any case.
    #
    # @return [String, nil]
    def [](name)
      headers[name.to_s.downcase]
    end

    def inspect
      "#<#{self.class.name} status=#{status} request_id=#{request_id.inspect}>"
    end
  end

  # A result with its response, from ZapSMTP::Client#with_response:
  #
  #   email, response = zap.with_response.emails.get(id)
  Result = Struct.new(:data, :response) do
    def to_ary
      [data, response]
    end
  end
end
