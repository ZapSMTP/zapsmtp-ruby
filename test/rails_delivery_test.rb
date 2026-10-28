# frozen_string_literal: true

require "test_helper"
require "mail"
require "zapsmtp/rails"

# The delivery method with the Mail gem alone.
class RailsDeliveryTest < Minitest::Test
  def setup
    @transport = StubTransport.new(json(200, { id: "019a-email" }))
    @zap = client(@transport)
  end

  def sent
    JSON.parse(@transport.calls.last.body)
  end

  def deliver(message, settings = {})
    message.delivery_method(ZapSMTP::Rails::DeliveryMethod, { client: @zap }.merge(settings))
    message.deliver
  end

  def test_maps_a_multipart_message_with_attachments_and_headers
    message = Mail.new do
      from "Acme Store <hello@acme.test>"
      to ["Jane Doe <jane@example.org>", "bob@example.org"]
      cc "carol@example.org"
      bcc "audit@acme.test"
      reply_to "support@acme.test"
      subject "Your receipt ✓"
      text_part { body "Thanks, Jane." }
      html_part do
        content_type "text/html; charset=UTF-8"
        body "<p>Thanks, Jane. <img src=\"cid:logo@acme\"></p>"
      end
    end
    message["In-Reply-To"] = "<prev@acme.test>"
    message["List-Unsubscribe"] = "<https://acme.test/u>"
    message.attachments["invoice.pdf"] = { mime_type: "application/pdf", content: "%PDF-1".b }
    message.attachments.inline["logo.png"] = { mime_type: "image/png", content: "\x89PNG".b,
                                               content_id: "<logo@acme>" }
    deliver(message)

    body = sent
    assert_equal "Acme Store <hello@acme.test>", body["from"]
    assert_equal ["Jane Doe <jane@example.org>", "bob@example.org"], body["to"]
    assert_equal ["carol@example.org"], body["cc"]
    assert_equal ["audit@acme.test"], body["bcc"]
    assert_equal ["support@acme.test"], body["reply_to"]
    assert_equal "Your receipt ✓", body["subject"]
    assert_equal "Thanks, Jane.", body["text"]
    assert_equal "<p>Thanks, Jane. <img src=\"cid:logo@acme\"></p>", body["html"]
    assert_equal({ "In-Reply-To" => "<prev@acme.test>", "List-Unsubscribe" => "<https://acme.test/u>" },
                 body["headers"])
    pdf, logo = body["attachments"]
    assert_equal({ "filename" => "invoice.pdf", "content" => ["%PDF-1"].pack("m0"),
                   "content_type" => "application/pdf" }, pdf)
    assert_equal({ "filename" => "logo.png", "content" => ["\x89PNG".b].pack("m0"), "content_type" => "image/png",
                   "content_id" => "logo@acme" }, logo)
    assert_equal "019a-email", message[ZapSMTP::Rails::EMAIL_ID_HEADER].value
    assert_match(/\A[0-9a-f-]{36}\z/, @transport.calls.last.headers["Idempotency-Key"])
  end

  def test_sends_a_plain_text_or_html_only_message
    deliver(Mail.new(from: "a@x.test", to: "b@y.test", subject: "Hi", body: "Just text"))
    assert_equal "Just text", sent["text"]
    refute sent.key?("html")
    refute sent.key?("headers")
    refute sent.key?("attachments")
    refute sent.key?("cc")

    html = Mail.new(from: "a@x.test", to: "b@y.test", body: "<b>Hi</b>")
    html.content_type = "text/html; charset=UTF-8"
    deliver(html)
    assert_equal "<b>Hi</b>", sent["html"]
    refute sent.key?("text")
    refute sent.key?("subject")
  end

  def test_sends_an_html_only_multipart_message
    message = Mail.new(from: "a@x.test", to: "b@y.test", subject: "s")
    message.html_part = Mail::Part.new do
      content_type "text/html; charset=UTF-8"
      body "<p>x</p>"
    end
    message.attachments["a.txt"] = "plain attachment"
    deliver(message)
    assert_equal "<p>x</p>", sent["html"]
    refute sent.key?("text")
    assert_equal "text/plain", sent["attachments"][0]["content_type"]
  end

  def test_sends_a_text_only_multipart_message_without_from_or_recipients
    message = Mail.new(to: "undisclosed-recipients:;", subject: "s")
    message.text_part = Mail::Part.new { body "only text" }
    message.attachments["x.qqq"] = "z"
    deliver(message)
    assert_equal "only text", sent["text"]
    refute sent.key?("html")
    refute sent.key?("from")
    refute sent.key?("to")
    assert_equal "text/plain", sent["attachments"][0]["content_type"]
  end

  def test_applies_the_zapsmtp_options_and_removes_their_header
    message = Mail.new(from: "a@x.test", to: "b@y.test", subject: "Hi", body: "x")
    ZapSMTP::Rails.set_options(message, { tags: [{ name: "category", value: "welcome" }],
                                          metadata: { user_id: "42", note: "Привет" }, stream: "broadcast",
                                          idempotency_key: "welcome-42" })
    ZapSMTP::Rails.set_options(message, { tags: [{ name: "category", value: "receipt" }], metadata: { k: "Привет" },
                                          idempotency_key: "receipt-42" })
    assert_equal(1, message.header.fields.count { |f| f.name == ZapSMTP::Rails::OPTIONS_HEADER })
    deliver(message)
    body = sent
    assert_equal [{ "name" => "category", "value" => "receipt" }], body["tags"]
    assert_equal({ "k" => "Привет" }, body["metadata"])
    refute body.key?("stream")
    refute body.key?("idempotency_key")
    refute body.key?("headers")
    assert_equal "receipt-42", @transport.calls.last.headers["Idempotency-Key"]
    assert_nil message[ZapSMTP::Rails::OPTIONS_HEADER]
  end

  def test_sends_a_template_without_bodies_and_can_drop_the_subject
    message = Mail.new(from: "a@x.test", to: "b@y.test", subject: "Default subject", body: "ignored")
    ZapSMTP::Rails.set_options(message, { template: { id: "welcome", variables: { name: "Jane" } }, subject: nil })
    deliver(message)
    assert_equal({ "id" => "welcome", "variables" => { "name" => "Jane" } }, sent["template"])
    refute sent.key?("text")
    refute sent.key?("subject")
  end

  def test_refuses_options_that_are_not_a_json_object
    ["[1]", "{nope"].each do |value|
      message = Mail.new(from: "a@x.test", to: "b@y.test", body: "x")
      message[ZapSMTP::Rails::OPTIONS_HEADER] = value
      error = assert_raises(ZapSMTP::Error) { deliver(message) }
      assert_match(/must be a JSON object/, error.message)
    end
  end

  def test_keeps_an_address_header_mail_cannot_parse
    message = Mail.new(from: "a@x.test", body: "x")
    message["To"] = "not an address <"
    deliver(message)
    assert_equal ["not an address <"], sent["to"]
  end

  def test_returns_the_response_with_return_response
    message = Mail.new(from: "a@x.test", to: "b@y.test", body: "x")
    message.delivery_method(ZapSMTP::Rails::DeliveryMethod, client: @zap, return_response: true)
    result = message.deliver!
    assert_instance_of ZapSMTP::Models::SendEmailResponse, result
    assert_equal "019a-email", result.id
  end

  def test_raises_the_api_error
    @transport = StubTransport.new(api_error(422, "invalid_parameter"))
    @zap = client(@transport, max_retries: 0)
    error = assert_raises(ZapSMTP::ValidationError) { deliver(Mail.new(from: "a@x.test", to: "b", body: "x")) }
    assert_equal "invalid_parameter", error.code
  end

  def test_builds_and_shares_a_client_from_the_settings
    settings = { api_key: "zap_settings", base_url: "https://api.test/v1", transport: @transport, return_response: 1 }
    one = ZapSMTP::Rails::DeliveryMethod.new(settings)
    two = ZapSMTP::Rails::DeliveryMethod.new(settings.transform_keys(&:to_s))
    assert_same one.client, two.client
    assert_equal "zap_settings", one.client.api_key
    assert_equal 1, two.settings[:return_response]
    refute_same one.client, ZapSMTP::Rails::DeliveryMethod.new(settings.merge(api_key: "other")).client
    one.deliver!(Mail.new(from: "a@x.test", to: "b@y.test", body: "x"))
    assert_equal "Bearer zap_settings", @transport.calls.last.headers["Authorization"]
  end
end
