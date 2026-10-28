# frozen_string_literal: true

require "json"
require "securerandom"

module ZapSMTP
  # The hand-written core of the client: HTTP, retries, errors and paging.
  # The resources (ZapSMTP::Client) are generated from the API reference.
  class BaseClient
    DEFAULT_BASE_URL = "https://api.zapsmtp.com/v1"
    USER_AGENT = "zapsmtp-ruby/#{VERSION} (ruby/#{RUBY_VERSION})".freeze
    REQUEST_OPTIONS = %i[idempotency_key headers timeout max_retries].freeze
    SAFE_METHODS = %w[GET PUT DELETE].freeze

    # One API request, as the resources describe it.
    #
    # @api private
    APIRequest = Struct.new(:http_method, :path, :query, :body, :form, :headers, :idempotent, keyword_init: true)

    # @return [String]
    attr_reader :api_key
    # @return [String] without a trailing slash
    attr_reader :base_url
    # @return [Numeric] seconds per attempt
    attr_reader :timeout
    # @return [Integer] retries of a failed request that is safe to retry
    attr_reader :max_retries
    # @return [Hash{String => String}] headers sent with every request
    attr_reader :default_headers
    # @return [#call] see ZapSMTP::Transport
    attr_reader :transport

    # @param api_key [String, nil] default: ENV["ZAP_API_KEY"]
    # @param base_url [String, nil] default: ENV["ZAP_BASE_URL"], else https://api.zapsmtp.com/v1
    # @param timeout [Numeric] seconds per attempt (connecting, each write and each read)
    # @param max_retries [Integer] retries of a failed request that is safe to retry
    # @param default_headers [Hash{String => String}] sent with every request
    # @param transport [#call, nil] default: ZapSMTP::Transport::NetHTTP
    def initialize(api_key: nil, base_url: nil, timeout: 60, max_retries: 2, default_headers: {}, transport: nil)
      @api_key = presence(api_key) || presence(ENV.fetch("ZAP_API_KEY", nil))
      raise Error, "Missing API key: pass api_key: to ZapSMTP::Client.new or set ZAP_API_KEY" unless @api_key

      @base_url = (presence(base_url) || presence(ENV.fetch("ZAP_BASE_URL", nil)) || DEFAULT_BASE_URL).sub(%r{/+\z}, "")
      @timeout = timeout
      @max_retries = max_retries
      @default_headers = default_headers.to_h { |k, v| [k.to_s, v.to_s] }
      @transport = transport || Transport::NetHTTP.new
      @with_response = false
      build_resources
    end

    # The same client, whose calls answer a ZapSMTP::Result: the data and the
    # ZapSMTP::Response (status, headers, request id) together.
    #
    #   email, response = zap.with_response.emails.send(...)
    #   response.request_id
    #   response["ratelimit-remaining"]
    #
    # @return [ZapSMTP::Client]
    def with_response
      copy = dup
      copy.instance_variable_set(:@with_response, true)
      copy
    end

    def initialize_copy(other)
      super
      build_resources
    end

    def inspect
      "#<#{self.class.name} base_url=#{base_url.inspect}>"
    end

    # @api private
    def request(method:, path:, query: nil, body: nil, form: nil, headers: nil, idempotent: false, model: nil,
                request_options: {})
      req = APIRequest.new(http_method: method.to_s.upcase, path: path, query: query, body: body, form: form,
                           headers: headers, idempotent: idempotent)
      data, response = execute(req, request_options)
      result = Model.build(model, data, response)
      @with_response ? Result.new(result, response) : result
    end

    # @api private
    def request_page(method:, path:, model:, paging:, query: nil, request_options: {})
      req = APIRequest.new(http_method: method.to_s.upcase, path: path, query: query)
      page = load_page(req, model, paging, request_options)
      @with_response ? Result.new(page, page.http_response) : page
    end

    private

    def build_resources; end

    def presence(value)
      value.nil? || value.to_s.empty? ? nil : value.to_s
    end

    def load_page(req, model, paging, request_options)
      data, response = execute(req, request_options)
      loader = ->(query) { load_page(req.dup.tap { |r| r.query = query }, model, paging, request_options) }
      Page.new(data, model: model, query: req.query, paging: paging, loader: loader, http_response: response)
    end

    # Sends a request, retrying it as docs/DESIGN-sdks.md says; answers the
    # parsed body and the response, or raises a ZapSMTP::Error.
    def execute(req, request_options)
      options = request_options(request_options)
      attempt = build_attempt(req, options)
      max_retries = options.fetch(:max_retries, @max_retries)
      safe = SAFE_METHODS.include?(req.http_method) || req.idempotent == true
      tries = 0
      loop do
        response, data, wait = attempt_once(attempt, safe, tries, tries < max_retries)
        return [data, response] unless wait

        sleep_for(wait)
        tries += 1
      end
    end

    # One attempt: [response, data, nil] on success, [nil, nil, seconds to
    # wait] when it should be tried again; raises otherwise.
    def attempt_once(attempt, safe, tries, may_retry)
      begin
        raw = @transport.call(attempt)
      rescue StandardError => e
        # a timeout or a broken connection (sending, or reading the answer):
        # the request may have reached the server, so only a request that is
        # safe to repeat is sent again
        return [nil, nil, Retry.backoff(tries, nil)] if may_retry && safe

        raise connection_error(e)
      end
      response = Response.new(raw.status.to_i, normalize_headers(raw.headers))
      data = parse(raw.body)
      return [response, data, nil] if response.status.between?(200, 299)

      error = Error.from_response(response.status, data, response.headers)
      raise error unless may_retry && Retry.retryable?(response.status, error.code, safe)

      [nil, nil, Retry.backoff(tries, Retry.retry_after(response.headers))]
    end

    # A failed attempt as a ConnectionError; when the answer's head came
    # before its body broke off, with its status, headers and request id.
    def connection_error(error)
      return ConnectionError.new(error.message) unless error.is_a?(Transport::ResponseBodyError)

      headers = normalize_headers(error.headers)
      ConnectionError.new(error.message, status: error.status, headers: headers, request_id: headers["x-request-id"])
    end

    def build_attempt(req, options)
      headers = attempt_headers(req, options)
      body = nil
      if req.form
        headers["Content-Type"] = req.form.content_type
        body = req.form.body
      elsif !req.body.nil?
        headers["Content-Type"] = "application/json"
        body = JSON.generate(Util.jsonable(req.body))
      end
      Transport::Request.new(http_method: req.http_method, url: url(req), headers: headers, body: body,
                             timeout: options.fetch(:timeout, @timeout))
    end

    # The headers of a request. Later ones replace earlier ones whatever
    # their case: the client's defaults, the operation's, the
    # Idempotency-Key, the caller's.
    def attempt_headers(req, options)
      headers = { "Authorization" => "Bearer #{@api_key}", "Accept" => "application/json", "User-Agent" => USER_AGENT }
      @default_headers.each { |k, v| set_header(headers, k, v) }
      (req.headers || {}).each { |k, v| set_header(headers, k, v) unless v.nil? }
      set_header(headers, "Idempotency-Key", options[:idempotency_key] || SecureRandom.uuid) if req.idempotent
      (options[:headers] || {}).each { |k, v| set_header(headers, k, v) }
      # an empty key turns deduplication off on the server, so a retried
      # send could go out twice: refused before anything is sent
      key = headers.find { |k, _| k.casecmp?("idempotency-key") }
      if key && key[1].strip.empty?
        raise ValidationError.new("idempotency_key must not be empty", code: "invalid_parameter")
      end

      headers
    end

    def set_header(headers, name, value)
      name = name.to_s
      headers.delete_if { |k, _| k.casecmp?(name) }
      headers[name] = value.to_s
    end

    def url(req)
      query = Util.query_string(req.query)
      query.empty? ? "#{@base_url}#{req.path}" : "#{@base_url}#{req.path}?#{query}"
    end

    def request_options(options)
      options = (options || {}).transform_keys(&:to_sym)
      unknown = options.keys - REQUEST_OPTIONS
      raise ArgumentError, "unknown request option(s): #{unknown.join(", ")}" unless unknown.empty?

      options
    end

    def normalize_headers(headers)
      (headers || {}).each_with_object({}) do |(k, v), out|
        out[k.to_s.downcase] = v.is_a?(Array) ? v.join(", ") : v.to_s
      end
    end

    def parse(body)
      return nil if body.nil? || body.empty?

      Util.finite(JSON.parse(body, symbolize_names: true, allow_nan: true))
    rescue JSON::ParserError
      body
    end

    def sleep_for(seconds)
      sleep(seconds)
    end
  end
end
