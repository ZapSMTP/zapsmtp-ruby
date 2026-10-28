# frozen_string_literal: true

# The official Ruby library for the ZapSMTP email API (https://zapsmtp.com).
#
#   require "zapsmtp"
#   zap = ZapSMTP::Client.new(api_key: "zap_...")
#   zap.emails.send(from: "Acme <hello@acme.com>", to: "jane@example.org", subject: "Hi", html: "<p>Hi</p>")
module ZapSMTP
end

require_relative "zapsmtp/core"

# The Rails integration (delivery method, webhook concern) loads with Rails;
# without Rails, require "zapsmtp/rails" for the Mail delivery method alone.
# :nocov: a load-time switch, tested in separate processes (test/loading_test.rb)
require_relative "zapsmtp/railtie" if defined?(Rails::Railtie)
# :nocov:
