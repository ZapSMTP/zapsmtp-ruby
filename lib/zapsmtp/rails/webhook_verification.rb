# frozen_string_literal: true

module ZapSMTP
  module Rails
    # A controller concern that verifies ZapSMTP webhook requests. A request
    # whose signature is missing, wrong or too old is answered 400.
    #
    #   class ZapsmtpWebhooksController < ActionController::API
    #     include ZapSMTP::Rails::WebhookVerification
    #
    #     def create
    #       event = zapsmtp_webhook_event # zapsmtp_webhook_events for a webhook with batch delivery
    #       EmailBounce.record(event.data) if event.type == "email.bounced"
    #       head :ok
    #     end
    #   end
    #
    # The secret is ENV["ZAP_WEBHOOK_SECRET"]; override #zapsmtp_webhook_secret
    # to take it from elsewhere (credentials). In an ActionController::Base
    # controller, skip_forgery_protection for the action.
    module WebhookVerification
      def self.included(controller)
        controller.rescue_from(ZapSMTP::WebhookVerificationError) do |error|
          render json: { error: error.message }, status: :bad_request
        end
      end

      private

      # The verified event of this request.
      #
      # @return [ZapSMTP::WebhookEvent]
      # @raise [ZapSMTP::WebhookVerificationError]
      def zapsmtp_webhook_event
        @zapsmtp_webhook_event ||= ZapSMTP::Webhook.verify(request.raw_post, request.headers,
                                                           zapsmtp_webhook_secret,
                                                           tolerance: zapsmtp_webhook_tolerance)
      end

      # The verified events of this request: every event of a batch (a
      # webhook with batch: true), or its one event.
      #
      # @return [Array<ZapSMTP::WebhookEvent>]
      # @raise [ZapSMTP::WebhookVerificationError]
      def zapsmtp_webhook_events
        @zapsmtp_webhook_events ||= ZapSMTP::Webhook.verify_events(request.raw_post, request.headers,
                                                                   zapsmtp_webhook_secret,
                                                                   tolerance: zapsmtp_webhook_tolerance)
      end

      # A before_action: refuses a request whose signature is not valid.
      def verify_zapsmtp_webhook!
        zapsmtp_webhook_events
      end

      # @return [String]
      def zapsmtp_webhook_secret
        ENV.fetch("ZAP_WEBHOOK_SECRET", nil)
      end

      # @return [Integer] seconds
      def zapsmtp_webhook_tolerance
        ZapSMTP::Webhook::DEFAULT_TOLERANCE
      end
    end
  end
end
