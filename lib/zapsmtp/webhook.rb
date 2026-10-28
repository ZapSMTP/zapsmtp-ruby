# frozen_string_literal: true

require "json"
require "openssl"

module ZapSMTP
  # Webhook signature verification (docs: Webhook events). Every request
  # ZapSMTP sends carries Zap-Signature: t=<unix seconds>,v1=<hex>, where v1
  # is HMAC-SHA256 over "<t>.<raw body>" keyed with the whole secret (its
  # whsec_ prefix included). Two v1 entries are sent for 24 hours after a
  # rotation.
  module Webhook
    DEFAULT_TOLERANCE = 300
    SIGNATURE_HEADER = "zap-signature"

    module_function

    # Checks a webhook request's signature and returns its event. Pass the
    # body exactly as received, before any JSON parsing. A webhook with batch
    # delivery sends an array of events: use .verify_events.
    #
    #   event = ZapSMTP::Webhook.verify(request.raw_post, request.headers, ENV["ZAP_WEBHOOK_SECRET"])
    #   event.type # => "email.delivered"
    #
    # @param payload [String] the raw request body
    # @param headers [Hash, #each, String] the request headers (a Hash in any
    #   case, a Rack env, ActionDispatch headers), or the Zap-Signature value
    # @param secret [String] the webhook's signing secret, whsec_...
    # @param tolerance [Integer] the oldest signature accepted, in seconds
    # @param now [Integer, nil] the time to check against, in unix seconds (default: now)
    # @return [ZapSMTP::WebhookEvent]
    # @raise [ZapSMTP::WebhookVerificationError]
    def verify(payload, headers, secret, tolerance: DEFAULT_TOLERANCE, now: nil)
      body = verified(payload, headers, secret, tolerance: tolerance, now: now)
      raise WebhookVerificationError, "The body is a batch of events: use verify_events" if body.is_a?(Array)

      event(body)
    end

    # Checks a webhook request's signature and returns its events: every
    # event of a batch (a webhook with batch: true), or the one event of any
    # other request. Takes the arguments of .verify.
    #
    # @return [Array<ZapSMTP::WebhookEvent>]
    # @raise [ZapSMTP::WebhookVerificationError]
    def verify_events(payload, headers, secret, tolerance: DEFAULT_TOLERANCE, now: nil)
      body = verified(payload, headers, secret, tolerance: tolerance, now: now)
      (body.is_a?(Array) ? body : [body]).map { |item| event(item) }
    end

    # Checks the signature and answers the parsed body: an event, or an
    # array of them for a batch.
    #
    # @api private
    def verified(payload, headers, secret, tolerance:, now:)
      signature = headers.is_a?(String) ? headers : signature_header(headers)
      raise WebhookVerificationError, "Missing Zap-Signature header" if signature.nil? || signature.empty?
      raise WebhookVerificationError, "Missing webhook secret" if secret.nil? || secret.to_s.empty?

      timestamp, signatures = parse_signature(signature)
      # unix seconds: at most 12 digits
      unless timestamp.match?(/\A\d{1,12}\z/) && !signatures.empty?
        raise WebhookVerificationError, "Malformed Zap-Signature header"
      end
      if ((now || Time.now.to_i) - timestamp.to_i).abs > tolerance
        raise WebhookVerificationError, "Webhook signature is too old (or from the future)"
      end

      body = payload.to_s.b
      expected = OpenSSL::HMAC.digest("SHA256", secret.to_s, "#{timestamp}.".b + body)
      unless signatures.any? { |hex| matches?(hex, expected) }
        raise WebhookVerificationError, "Webhook signature does not match"
      end

      parse(body)
    end

    # The Zap-Signature value among headers, whatever their case or form
    # (Zap-Signature, zap_signature, Rack's HTTP_ZAP_SIGNATURE).
    #
    # @api private
    def signature_header(headers)
      return nil unless headers.respond_to?(:each)

      headers.each do |name, value|
        name = name.to_s.downcase.tr("_", "-").delete_prefix("http-")
        return value.is_a?(Array) ? value.join(",") : value.to_s if name == SIGNATURE_HEADER
      end
      nil
    end

    # @api private
    def parse_signature(signature)
      timestamp = ""
      signatures = []
      signature.split(",").each do |part|
        key, value = part.split("=", 2).map(&:strip)
        if key == "t"
          timestamp = value.to_s
        elsif key == "v1"
          signatures << value.to_s
        end
      end
      [timestamp, signatures]
    end

    # Compares a v1 entry with the expected HMAC in constant time.
    #
    # @api private
    def matches?(hex, expected)
      return false unless hex.match?(/\A[0-9a-f]{64}\z/i)

      OpenSSL.fixed_length_secure_compare([hex].pack("H*"), expected)
    end

    # @api private
    def parse(body)
      Util.finite(JSON.parse(body.dup.force_encoding(Encoding::UTF_8), symbolize_names: true))
    rescue JSON::ParserError, EncodingError
      raise WebhookVerificationError, "Webhook body is not JSON"
    end

    # @api private
    def event(item)
      raise WebhookVerificationError, "Webhook body is not an event" unless item.is_a?(Hash)

      WebhookEvent.new(item)
    end
  end
end
