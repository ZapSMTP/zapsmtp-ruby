# frozen_string_literal: true

require "json"

module ZapSMTP
  # Rack middleware that checks the signature of ZapSMTP webhook requests
  # (Rails, Sinatra, Hanami, any Rack app). A request to +path+ (or every
  # request, without one) with a valid signature reaches the app with its
  # events in env["zapsmtp.events"] (one, or every event of a batch) and,
  # unless it is a batch, its event in env["zapsmtp.event"]; any other is
  # answered 400.
  #
  #   # config/application.rb
  #   config.middleware.use ZapSMTP::WebhookMiddleware, path: "/webhooks/zapsmtp",
  #                                                     secret: ENV["ZAP_WEBHOOK_SECRET"]
  #   # the controller then reads request.env["zapsmtp.event"]
  class WebhookMiddleware
    EVENT_KEY = "zapsmtp.event"
    EVENTS_KEY = "zapsmtp.events"

    def initialize(app, secret: ENV.fetch("ZAP_WEBHOOK_SECRET", nil), path: nil, tolerance: Webhook::DEFAULT_TOLERANCE)
      @app = app
      @secret = secret
      @path = path
      @tolerance = tolerance
    end

    def call(env)
      return @app.call(env) unless @path.nil? || env["PATH_INFO"] == @path

      begin
        body = Webhook.verified(read_body(env), env, @secret, tolerance: @tolerance, now: nil)
        events = (body.is_a?(Array) ? body : [body]).map { |item| Webhook.event(item) }
      rescue WebhookVerificationError => e
        return [400, { "content-type" => "application/json" }, [JSON.generate(error: e.message)]]
      end
      env[EVENTS_KEY] = events
      env[EVENT_KEY] = events.first unless body.is_a?(Array)
      @app.call(env)
    end

    private

    # The raw body, the input left rewound for the app.
    def read_body(env)
      input = env["rack.input"]
      return "" if input.nil?

      input.rewind if input.respond_to?(:rewind)
      body = input.read.to_s
      input.rewind if input.respond_to?(:rewind)
      body
    end
  end
end
