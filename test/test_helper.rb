# frozen_string_literal: true

require "simplecov"
SimpleCov.start do
  enable_coverage :branch
  add_filter "/test/"
  minimum_coverage line: 100, branch: 100
end

require "minitest/autorun"
require "json"
require "zapsmtp"

SDKS = File.expand_path("../..", __dir__)

# A transport that answers from a list (the last answer repeats) and records each request.
class StubTransport
  attr_reader :calls

  def initialize(*answers)
    @answers = answers
    @calls = []
  end

  def call(request)
    @calls << request
    answer = @answers.length > 1 ? @answers.shift : @answers.first
    raise answer if answer.is_a?(Exception)

    answer.respond_to?(:call) ? answer.call(request) : answer
  end
end

module Helpers
  def json(status, body, headers = {})
    ZapSMTP::Transport::Response.new(
      status: status, body: JSON.generate(body),
      headers: { "Content-Type" => "application/json", "X-Request-Id" => "req_1" }.merge(headers)
    )
  end

  def api_error(status, code, headers = {})
    json(status, { statusCode: status, name: code, message: "#{code} happened",
                   error: { code: code, message: "#{code} happened", type: "invalid_request_error" } }, headers)
  end

  def raw(status, body, headers = {})
    ZapSMTP::Transport::Response.new(status: status, body: body, headers: headers)
  end

  # A client on a stub transport that records its sleeps instead of sleeping.
  def client(transport, **options)
    zap = ZapSMTP::Client.new(api_key: "zap_test_key", base_url: "https://api.test/v1/", transport: transport,
                              **options)
    slept = []
    zap.define_singleton_method(:sleep_for) { |seconds| slept << seconds }
    zap.define_singleton_method(:slept) { slept }
    zap
  end

  def page(ids, more, extra = {})
    json(200, { object: "list", has_more: more, data: ids.map { |id| { id: id } } }.merge(extra))
  end

  def query(request)
    URI.decode_www_form(URI(request.url).query.to_s).each_with_object({}) { |(k, v), h| (h[k] ||= []) << v }
  end

  def with_env(values)
    saved = values.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
    values.each { |k, v| ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| ENV[k] = v }
  end
end

Minitest::Test.include(Helpers)
