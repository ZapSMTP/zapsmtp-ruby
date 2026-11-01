# frozen_string_literal: true

require "test_helper"

# Every API operation, called through the SDK against the conformance mock
# (sdks/conformance/server.mjs), which checks the exact request it gets. The
# server's URL comes from ZAP_CONFORMANCE_URL (sdks/scripts/docker-test.sh),
# else the test starts it with node.
class ConformanceTest < Minitest::Test
  CASES = JSON.parse(File.read(File.join(SDKS, "conformance/cases.json")))

  def self.server_url
    @server_url ||= ENV.fetch("ZAP_CONFORMANCE_URL") { start_server }
  end

  def self.start_server
    io = IO.popen(["node", File.join(SDKS, "conformance/server.mjs"), "0"])
    at_exit { Process.kill("TERM", io.pid) }
    "http://127.0.0.1:#{io.gets[/listening (\d+)/, 1]}/v1"
  end

  def zap
    @zap ||= ZapSMTP::Client.new(api_key: "zap_test_conformance", base_url: self.class.server_url, max_retries: 0)
  end

  def snake(name)
    name.gsub(/([a-z0-9])([A-Z])/, '\1_\2').downcase
  end

  def symbolize(value)
    JSON.parse(JSON.generate(value), symbolize_names: true)
  end

  def test_covers_every_operation_once
    assert_equal 114, CASES.size
    assert_equal CASES.size, CASES.map { |c| c["id"] }.uniq.size
  end

  CASES.each_with_index do |c, i|
    define_method("test_#{c["id"].tr("-", "_")}") do
      call = c["call"]
      target = call["resource"].reduce(zap) { |t, r| t.public_send(snake(r)) }
      name = snake(call["method"])
      assert_respond_to target, name
      args = call["pathArgs"].dup
      result =
        if call["items"]
          target.public_send(name, *args, call["items"], **call["options"].transform_keys(&:to_sym))
        elsif call["params"] && i.even?
          target.public_send(name, *args, **call["params"].transform_keys(&:to_sym)) # keyword arguments
        elsif call["params"]
          target.public_send(name, *args, call["params"]) # a Hash
        else
          target.public_send(name, *args)
        end
      expected = c["response"]["body"]
      if expected.nil?
        assert_nil result
      elsif result.is_a?(ZapSMTP::Page)
        assert_equal symbolize(expected["data"]), result.data.map(&:to_h)
        assert_equal "req_conformance", result.http_response.request_id
      else
        assert_kind_of ZapSMTP::Model, result
        assert_equal symbolize(expected), result.to_h
        assert_equal c["response"]["status"], result.http_response.status
      end
    end
  end
end
