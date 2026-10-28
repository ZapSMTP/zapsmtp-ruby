# frozen_string_literal: true

require "json"
require_relative "core"

module ZapSMTP
  # The Rails and Mail integration: an ActionMailer delivery method
  # (ZapSMTP::Rails::DeliveryMethod) and a controller concern that verifies
  # webhooks (ZapSMTP::Rails::WebhookVerification). In a Rails app the
  # Railtie registers the delivery method as :zapsmtp; with the Mail gem
  # alone, require "zapsmtp/rails" and use the class.
  module Rails
    # The private header that carries the zapsmtp: options of a mail()
    # call (tags, metadata, stream, template...) to the delivery method,
    # which removes it before sending.
    OPTIONS_HEADER = "X-Zapsmtp-Options"
    # The header the delivery method sets on a sent message: the email's id.
    EMAIL_ID_HEADER = "X-Zapsmtp-Email-Id"

    module_function

    # Registers the delivery method and the zapsmtp: option of mail() on
    # ActionMailer::Base (the Railtie does this).
    def install(mailer_base)
      mailer_base.add_delivery_method(:zapsmtp, DeliveryMethod)
      mailer_base.prepend(MailerOptions)
    end

    # Sets the ZapSMTP options of a Mail::Message: tags, metadata, stream,
    # template, tracking, scheduled_at, tls, idempotency_key, or any other
    # emails.send parameter. A nil value removes that parameter.
    def set_options(message, options)
      message[OPTIONS_HEADER] = nil
      message[OPTIONS_HEADER] = JSON.generate(options, ascii_only: true)
      message
    end

    # Reads the options of a Mail::Message (they stay on it until it is sent).
    #
    # @return [Hash{String => Object}]
    def options(message)
      field = message.header.fields.reverse.find { |f| f.name.casecmp?(OPTIONS_HEADER) }
      return {} unless field

      options = JSON.parse(field.value.to_s)
      raise ArgumentError unless options.is_a?(Hash)

      options
    rescue JSON::ParserError, ArgumentError
      raise Error, "#{OPTIONS_HEADER} must be a JSON object"
    end

    # The zapsmtp: option of ActionMailer's mail():
    #
    #   mail(to: user.email, subject: "Welcome", zapsmtp: { tags: [{ name: "category", value: "welcome" }],
    #                                                        metadata: { user_id: user.id.to_s } })
    module MailerOptions
      def mail(headers = {}, &block)
        return super unless headers.is_a?(Hash) && headers.key?(:zapsmtp)

        message = super(headers.except(:zapsmtp), &block)
        ZapSMTP::Rails.set_options(message, headers[:zapsmtp])
      end
    end
  end
end

require_relative "rails/message"
require_relative "rails/delivery_method"
require_relative "rails/webhook_verification"
