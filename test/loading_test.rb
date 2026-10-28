# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

# require "zapsmtp" loads the Rails integration only when Rails is loaded.
class LoadingTest < Minitest::Test
  LIB = File.expand_path("../lib", __dir__)

  def run_ruby(code)
    out, status = Open3.capture2e(RbConfig.ruby, "-W:deprecated", "-I", LIB, "-e", code)
    assert status.success?, out
    out
  end

  def test_without_rails
    out = run_ruby('require "zapsmtp"; p [defined?(ZapSMTP::Client), defined?(ZapSMTP::Rails)]')
    assert_equal %(["constant", nil]\n), out
  end

  def test_with_rails
    out = run_ruby('require "rails"; require "action_mailer/railtie"; require "zapsmtp"; ' \
                   "p defined?(ZapSMTP::Rails::Railtie)")
    assert_equal %("constant"\n), out
  end

  def test_the_mail_delivery_method_alone
    out = run_ruby('require "zapsmtp/rails"; p [defined?(ZapSMTP::Client), defined?(ZapSMTP::Rails::DeliveryMethod)]')
    assert_equal %(["constant", "constant"]\n), out
  end

  def test_loads_without_warnings
    out = run_ruby('$VERBOSE = true; require "zapsmtp"; require "zapsmtp/rails"')
    assert_equal "", out
  end
end
