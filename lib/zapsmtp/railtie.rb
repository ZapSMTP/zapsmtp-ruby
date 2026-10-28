# frozen_string_literal: true

require_relative "rails"

module ZapSMTP
  module Rails
    # Registers the :zapsmtp delivery method with ActionMailer:
    #
    #   config.action_mailer.delivery_method = :zapsmtp
    #   config.action_mailer.zapsmtp_settings = { api_key: ENV["ZAP_API_KEY"] }
    class Railtie < ::Rails::Railtie
      initializer "zapsmtp.action_mailer", before: "action_mailer.set_configs" do
        ActiveSupport.on_load(:action_mailer) { ZapSMTP::Rails.install(self) }
      end
    end
  end
end
