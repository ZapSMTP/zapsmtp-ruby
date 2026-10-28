# frozen_string_literal: true

require_relative "lib/zapsmtp/version"

Gem::Specification.new do |spec|
  spec.name = "zapsmtp"
  spec.version = ZapSMTP::VERSION
  spec.authors = ["ZapSMTP"]
  spec.email = ["support@zapsmtp.com"]
  spec.summary = "The official Ruby library for the ZapSMTP email API, with a Rails delivery method"
  spec.description = "Send, receive and track email with ZapSMTP: every API operation, safe retries with " \
                     "idempotency keys, paging over every list, webhook signature verification and an " \
                     "ActionMailer delivery method. No dependencies beyond Ruby's standard library."
  spec.homepage = "https://zapsmtp.com/docs/sdks/"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "documentation_uri" => "https://zapsmtp.com/docs/",
    "source_code_uri" => "https://github.com/zapsmtp/zapsmtp-ruby",
    "changelog_uri" => "https://github.com/zapsmtp/zapsmtp-ruby/releases",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]
end
