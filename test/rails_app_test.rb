# frozen_string_literal: true

require "test_helper"
require "logger"
require "rails"
require "action_mailer/railtie"
require "action_controller/railtie"
require "zapsmtp/railtie"

RAILS_TRANSPORT = StubTransport.new(
  ZapSMTP::Transport::Response.new(status: 200, headers: { "x-request-id" => "req_r" }, body: '{"id":"019a-rails"}')
)

class ZapsmtpTestApp < Rails::Application
  config.eager_load = false
  config.logger = Logger.new(nil)
  config.secret_key_base = "0" * 64
  config.action_mailer.delivery_method = :zapsmtp
  config.action_mailer.zapsmtp_settings = { api_key: "zap_rails", base_url: "https://api.test/v1",
                                            transport: RAILS_TRANSPORT }
end
ZapsmtpTestApp.initialize!

class WelcomeMailer < ActionMailer::Base
  default from: "Acme <hello@acme.test>"

  def welcome(name)
    attachments.inline["logo.png"] = { mime_type: "image/png", content: "\x89PNG".b }
    attachments["terms.pdf"] = { mime_type: "application/pdf", content: "%PDF".b }
    headers["X-Campaign"] = "spring"
    mail(to: "#{name} <jane@example.org>", subject: "Welcome, #{name}",
         zapsmtp: { tags: [{ name: "category", value: "welcome" }], metadata: { user: name },
                    idempotency_key: "welcome-#{name}" }) do |format|
      format.text { render plain: "Hello #{name}" }
      format.html { render html: "<p>Hello #{name} <img src=\"#{attachments["logo.png"].url}\"></p>".html_safe }
    end
  end

  def plain
    mail(to: "bob@example.org", subject: "Plain", body: "No options")
  end

  def templated
    mail(to: "bob@example.org", body: "", zapsmtp: { template: { id: "receipt", variables: { total: 42 } },
                                                     subject: nil })
  end
end

class RailsAppTest < Minitest::Test
  def sent
    JSON.parse(RAILS_TRANSPORT.calls.last.body)
  end

  def test_registers_the_delivery_method
    assert_equal ZapSMTP::Rails::DeliveryMethod, ActionMailer::Base.delivery_methods[:zapsmtp]
    assert_equal "zap_rails", ActionMailer::Base.zapsmtp_settings[:api_key]
    assert_includes ActionMailer::Base.ancestors, ZapSMTP::Rails::MailerOptions
  end

  def test_delivers_a_mailer_message
    message = WelcomeMailer.welcome("Jane").deliver_now
    request = RAILS_TRANSPORT.calls.last
    body = sent
    assert_equal "Bearer zap_rails", request.headers["Authorization"]
    assert_equal "welcome-Jane", request.headers["Idempotency-Key"]
    assert_equal "Acme <hello@acme.test>", body["from"]
    assert_equal ["Jane <jane@example.org>"], body["to"]
    assert_equal "Welcome, Jane", body["subject"]
    assert_equal "Hello Jane", body["text"]
    cid = body["attachments"].find { |a| a["filename"] == "logo.png" }["content_id"]
    refute_nil cid
    assert_equal "<p>Hello Jane <img src=\"cid:#{cid}\"></p>", body["html"]
    assert_equal({ "X-Campaign" => "spring" }, body["headers"])
    assert_equal [{ "name" => "category", "value" => "welcome" }], body["tags"]
    assert_equal({ "user" => "Jane" }, body["metadata"])
    terms = body["attachments"].find { |a| a["filename"] == "terms.pdf" }
    assert_equal ["application/pdf", ["%PDF"].pack("m0")], terms.values_at("content_type", "content")
    refute terms.key?("content_id")
    assert_equal "019a-rails", message[ZapSMTP::Rails::EMAIL_ID_HEADER].value
    assert_nil message[ZapSMTP::Rails::OPTIONS_HEADER]
  end

  def test_delivers_without_options_and_with_a_template
    WelcomeMailer.plain.deliver_now
    assert_equal "No options", sent["text"]
    refute sent.key?("tags")
    WelcomeMailer.templated.deliver_now
    assert_equal({ "id" => "receipt", "variables" => { "total" => 42 } }, sent["template"])
    refute sent.key?("subject")
    refute sent.key?("text")
  end
end

class WebhooksController < ActionController::API
  include ZapSMTP::Rails::WebhookVerification

  before_action :verify_zapsmtp_webhook!

  def create
    render json: { type: zapsmtp_webhook_event.type }
  end
end

class CustomSecretController < ActionController::API
  include ZapSMTP::Rails::WebhookVerification

  def create
    render json: { id: zapsmtp_webhook_event.id }
  end

  private

  def zapsmtp_webhook_secret
    "whsec_custom"
  end

  def zapsmtp_webhook_tolerance
    10
  end
end

class BatchWebhooksController < ActionController::API
  include ZapSMTP::Rails::WebhookVerification

  def create
    render json: { types: zapsmtp_webhook_events.map(&:type) }
  end
end

class WebhookVerificationTest < Minitest::Test
  def call(controller, body, signature)
    env = Rack::MockRequest.env_for("/webhooks", method: "POST", input: body,
                                                 "CONTENT_TYPE" => "application/json",
                                                 "HTTP_ZAP_SIGNATURE" => signature)
    status, _headers, response = controller.action(:create).call(env)
    text = +""
    response.each { |chunk| text << chunk }
    [status, JSON.parse(text)]
  end

  def sign(secret, body, time = Time.now.to_i)
    "t=#{time},v1=#{OpenSSL::HMAC.hexdigest("SHA256", secret, "#{time}.#{body}")}"
  end

  def test_verifies_a_signed_request
    body = '{"id":"evt_9","type":"email.bounced"}'
    with_env("ZAP_WEBHOOK_SECRET" => "whsec_env") do
      assert_equal [200, { "type" => "email.bounced" }], call(WebhooksController, body, sign("whsec_env", body))
      status, json = call(WebhooksController, body, sign("whsec_other", body))
      assert_equal 400, status
      assert_match(/does not match/, json["error"])
    end
  end

  def test_verifies_a_batch
    body = '[{"type":"email.sent"},{"type":"email.opened"}]'
    with_env("ZAP_WEBHOOK_SECRET" => "whsec_env") do
      assert_equal [200, { "types" => %w[email.sent email.opened] }],
                   call(BatchWebhooksController, body, sign("whsec_env", body))
      status, json = call(WebhooksController, body, sign("whsec_env", body))
      assert_equal 400, status # the before_action takes a batch; zapsmtp_webhook_event refuses it
      assert_match(/batch of events/, json["error"])
    end
  end

  def test_takes_the_secret_and_tolerance_from_the_controller
    body = '{"id":"evt_7"}'
    assert_equal [200, { "id" => "evt_7" }], call(CustomSecretController, body, sign("whsec_custom", body))
    status, = call(CustomSecretController, body, sign("whsec_custom", body, Time.now.to_i - 60))
    assert_equal 400, status
  end
end
