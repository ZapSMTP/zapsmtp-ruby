# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :development, :test do
  gem "actionmailer", ">= 7.0"
  gem "mail", "~> 2.8"
  gem "minitest", "~> 5.20"
  gem "railties", ">= 7.0"
  gem "rake", "~> 13.0"
  gem "rubocop", ">= 1.76", require: false
  gem "simplecov", "~> 0.22", require: false

  # ActiveSupport 7.1, the newest for Ruby 3.0, passes JSON.generate an option json 3 removed
  gem "json", "< 3" if RUBY_VERSION < "3.1"
end
