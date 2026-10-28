# frozen_string_literal: true

require "securerandom"

module ZapSMTP
  module Rails
    # A Mail / ActionMailer delivery method that sends through the ZapSMTP API.
    #
    #   # config/environments/production.rb
    #   config.action_mailer.delivery_method = :zapsmtp
    #   config.action_mailer.zapsmtp_settings = { api_key: ENV["ZAP_API_KEY"] }
    #
    # Settings: api_key, base_url, timeout, max_retries, default_headers and
    # transport (as for ZapSMTP::Client.new), or client: a ZapSMTP::Client;
    # return_response: true makes Mail::Message#deliver! answer the API's
    # response. After a send the message carries the email's id in its
    # X-Zapsmtp-Email-Id header.
    class DeliveryMethod
      CLIENT_SETTINGS = %i[api_key base_url timeout max_retries default_headers transport].freeze

      @clients = {}
      @mutex = Mutex.new

      class << self
        # One client per distinct settings, shared by the deliveries that use
        # them (Mail makes a delivery method per message).
        #
        # @api private
        def client_for(settings)
          config = settings.slice(*CLIENT_SETTINGS)
          @mutex.synchronize { @clients[config] ||= ZapSMTP::Client.new(**config) }
        end
      end

      # @return [Hash]
      attr_accessor :settings

      def initialize(settings = {})
        @settings = settings.to_h.transform_keys(&:to_sym)
      end

      # Sends the message; raises a ZapSMTP::Error when the API refuses it.
      #
      # The message keeps its options until the API has taken it, and its
      # Idempotency-Key (the caller's, or one made on the first attempt and
      # kept with the options): delivering the same message again after a
      # failure, a lost answer included, sends the same request and never
      # sends twice.
      #
      # @param message [Mail::Message]
      # @return [ZapSMTP::Models::SendEmailResponse]
      def deliver!(message)
        options = ZapSMTP::Rails.options(message)
        unless options["idempotency_key"]
          options["idempotency_key"] = SecureRandom.uuid
          ZapSMTP::Rails.set_options(message, options)
        end
        key = options.delete("idempotency_key")
        result = client.emails.send(Message.params(message, options), request_options: { idempotency_key: key })
        message[OPTIONS_HEADER] = nil
        message[EMAIL_ID_HEADER] = result.id
        result
      end

      # @return [ZapSMTP::Client]
      def client
        settings[:client] || DeliveryMethod.client_for(settings)
      end
    end
  end
end
