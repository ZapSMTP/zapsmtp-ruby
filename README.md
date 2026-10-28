# ZapSMTP Ruby SDK

The official Ruby library for the [ZapSMTP](https://zapsmtp.com) email API: send, receive and track
email, manage templates, domains, webhooks and everything else the API does. It includes an
ActionMailer delivery method for Rails.

- Every API operation, with a reader for every documented response field
- Safe automatic retries: sends carry an `Idempotency-Key`, so a retry never sends twice
- Paging over every page of any list, lazily
- Webhook signature verification, with a Rack middleware and a Rails controller concern
- `config.action_mailer.delivery_method = :zapsmtp`
- Ruby 3.0+, no dependencies beyond the standard library

## Install

```ruby
# Gemfile
gem "zapsmtp"
```

## Send an email

```ruby
require "zapsmtp"

zap = ZapSMTP::Client.new(api_key: "zap_...") # or set ZAP_API_KEY and call ZapSMTP::Client.new

email = zap.emails.send(
  from: "Acme <hello@acme.com>",
  to: "jane@example.org",
  subject: "Your receipt",
  html: "<p>Thanks for your order.</p>",
  tags: [{ name: "category", value: "receipt" }],
  metadata: { order_id: "A-1042" }
)
email.id # => "019a1f2e-..."
```

Parameters are keyword arguments, or a Hash, with the API's names (`reply_to`, `scheduled_at`...).
A `Time` is sent as RFC 3339: `scheduled_at: Time.now + 3600`.

With a template:

```ruby
zap.emails.send(
  from: "Acme <hello@acme.com>",
  to: "jane@example.org",
  template: { id: "receipt", variables: { name: "Jane", total: 42 } }
)
```

Attachments:

```ruby
zap.emails.send(
  from: "Acme <hello@acme.com>",
  to: "jane@example.org",
  subject: "Your invoice",
  html: '<p>Attached. <img src="cid:logo"></p>',
  attachments: [
    ZapSMTP::Attachment.from_file("invoice.pdf"),
    ZapSMTP::Attachment.from_file("logo.png", content_id: "logo"), # inline
    ZapSMTP::Attachment.from_string("report.csv", csv)
  ]
)
```

Up to 100 emails at once:

```ruby
result = zap.emails.send_batch(emails, validation: "permissive")
result.data   # the sent ones
result.errors # the refused ones, with their index
```

## Responses

A response is a model with a reader for every documented field. Every field, documented or not,
can be read with `[]` and `to_h` (keys as symbols), and models work with pattern matching:

```ruby
email = zap.emails.get(id)
email.status      # => "delivered"
email[:status]    # the same
email.to_h        # => { id: "...", status: "delivered", ... }

case email
in { status: "bounced", to: } then suppress(to)
end
```

A field the API adds later is kept, never an error. A field whose name is a Ruby method of every
object, such as `method` on a log entry, is read with `[]`: `log[:method]`.

## Lists

A list call answers one page; `auto_paging_each` walks every page, asking for the next one only when
the previous is used up.

```ruby
page = zap.emails.list(limit: 50, status: "bounced")
page.data        # this page's emails
page.next_page?  # makes no request
page.next_page   # the next page, or nil

zap.emails.list(status: "bounced").auto_paging_each do |email|
  puts email.id
end

# an Enumerator: stop early without loading more pages
zap.emails.list.auto_paging_each.lazy.select { |e| e.status == "bounced" }.first(10)
```

## Errors

Every API error raises a `ZapSMTP::Error` subclass with `status`, `code`, `message`, `type`,
`request_id`, `headers` and `body`.

```ruby
begin
  zap.emails.send(**email)
rescue ZapSMTP::ValidationError => e
  warn "#{e.code}: #{e.message}" # e.g. invalid_parameter
rescue ZapSMTP::RateLimitError => e
  warn "retry in #{e.retry_after} s"
end
```

| Class | When |
|---|---|
| `ZapSMTP::AuthenticationError` | 401: missing or invalid key |
| `ZapSMTP::PermissionError` | 403: the key may not do this, or the domain is not verified |
| `ZapSMTP::NotFoundError` | 404 |
| `ZapSMTP::ConflictError` | 409 |
| `ZapSMTP::ValidationError` | 400, 413, 422: the request is wrong (also an id that is empty, `.` or `..`, refused before sending) |
| `ZapSMTP::RateLimitError` | 429: `retry_after` says how long to wait |
| `ZapSMTP::ServerError` | 5xx |
| `ZapSMTP::ConnectionError` | no answer: network failure or timeout (`cause` holds the underlying error) |

## Retries and timeouts

A request that failed on the way (429, 408, 5xx, a lost connection) is tried again twice by default,
waiting as the API's `Retry-After` says or backing off exponentially. Only requests that are safe to
repeat are retried: reads, updates by `PUT`, deletes, and sends, which always carry an
`Idempotency-Key` (pass your own to make retries of your own safe too).

```ruby
zap = ZapSMTP::Client.new(api_key: "zap_...", max_retries: 4, timeout: 20)
zap.emails.get(id, request_options: { timeout: 5, max_retries: 0 })
zap.emails.send(**email, request_options: { idempotency_key: "order-1042-receipt" })
```

`request_options` takes `idempotency_key`, `headers`, `timeout` and `max_retries`.

## Response headers

Every model knows the answer it came from; `with_response` gives the response with any result,
`nil` ones included:

```ruby
email = zap.emails.send(**email)
email.http_response.request_id
email.http_response["ratelimit-remaining"]

result, response = zap.with_response.domains.delete(domain_id)
response.status # => 204
```

## Template assets

```ruby
zap.template_assets.upload_file("logo.png", name: "Logo")       # a path (String or Pathname)
zap.template_assets.upload_file(File.open("banner.webp"))       # or a File, StringIO...
zap.template_assets.upload(url: "https://acme.com/logo.png")    # or a URL
```

## Webhooks

Check the signature on the raw body, before parsing it. `verify` returns the event, or raises
`ZapSMTP::WebhookVerificationError` when the signature is missing, wrong or older than five minutes.
A webhook with batch delivery sends an array of events: use `verify_events`, which returns every
event (one event as a list of one).

```ruby
event = ZapSMTP::Webhook.verify(raw_body, headers, ENV["ZAP_WEBHOOK_SECRET"])
event.type # => "email.bounced"
event.data # => { email_id: "...", to: "jane@example.org", ... }

events = ZapSMTP::Webhook.verify_events(raw_body, headers, ENV["ZAP_WEBHOOK_SECRET"])
```

`headers` may be a Hash in any case, a Rack env, Rails' `request.headers`, or the `Zap-Signature`
value itself. `zap.webhooks.verify` and `zap.webhooks.verify_events` do the same.

Rails:

```ruby
class ZapsmtpWebhooksController < ActionController::API
  include ZapSMTP::Rails::WebhookVerification # answers 400 to a request that fails verification

  def create
    event = zapsmtp_webhook_event # zapsmtp_webhook_events with batch delivery
    Bounce.record!(event.data) if event.type == "email.bounced"
    head :ok
  end

  private

  # default: ENV["ZAP_WEBHOOK_SECRET"]
  def zapsmtp_webhook_secret
    Rails.application.credentials.zapsmtp_webhook_secret
  end
end
```

In an `ActionController::Base` controller, add `skip_forgery_protection`.

Sinatra:

```ruby
post "/webhooks/zapsmtp" do
  event = ZapSMTP::Webhook.verify(request.body.read, request.env, ENV["ZAP_WEBHOOK_SECRET"])
  # ...
  200
rescue ZapSMTP::WebhookVerificationError
  400
end
```

Any Rack app, with the middleware (it answers 400 itself, and passes the events on in
`env["zapsmtp.events"]`, and the one event of a request that is not a batch in
`env["zapsmtp.event"]`):

```ruby
use ZapSMTP::WebhookMiddleware, path: "/webhooks/zapsmtp", secret: ENV["ZAP_WEBHOOK_SECRET"]
```

## Rails: the delivery method

```ruby
# config/environments/production.rb
config.action_mailer.delivery_method = :zapsmtp
config.action_mailer.zapsmtp_settings = { api_key: Rails.application.credentials.zapsmtp_api_key }
```

Mailers stay as they are. From, to, cc, bcc, reply-to, the subject, the HTML and text parts, custom
headers (`In-Reply-To`, `List-Unsubscribe`, `X-...`) and attachments, inline ones included, go to
`emails.send`. ZapSMTP's own options go in `zapsmtp:`:

```ruby
class UserMailer < ApplicationMailer
  def welcome(user)
    attachments.inline["logo.png"] = File.binread("app/assets/images/logo.png")
    mail(
      to: user.email,
      subject: "Welcome, #{user.name}",
      zapsmtp: {
        tags: [{ name: "category", value: "welcome" }],
        metadata: { user_id: user.id.to_s },
        stream: "broadcast",
        idempotency_key: "welcome-#{user.id}" # a retried job never sends twice
      }
    )
  end

  # a stored template: no view needed
  def receipt(order)
    mail(to: order.email, body: "", zapsmtp: {
      template: { id: "receipt", variables: { total: order.total } },
      subject: nil # nil: use the template's subject, not the mailer's
    })
  end
end
```

The options travel in a private header, `X-Zapsmtp-Options`, which is never sent and is removed
once the API has taken the message; any `emails.send` parameter can be set there. Every message is
sent with an `Idempotency-Key`: yours, or one made on its first attempt and kept on the message, so
delivering the same message again after a failure (a lost answer included) never sends it twice. After a send the message carries the email's id in
`X-Zapsmtp-Email-Id`, and with `return_response: true` in the settings `deliver!` answers the API's
response. API errors raise as above (ActionMailer's `raise_delivery_errors` applies).

Settings: `api_key`, `base_url`, `timeout`, `max_retries`, `default_headers`, `transport`, or
`client:` an existing `ZapSMTP::Client`.

Without Rails, the Mail gem can use it too:

```ruby
require "zapsmtp/rails"

message = Mail.new(from: "hello@acme.com", to: "jane@example.org", subject: "Hi", body: "Hello")
ZapSMTP::Rails.set_options(message, { tags: [{ name: "category", value: "hello" }] })
message.delivery_method(ZapSMTP::Rails::DeliveryMethod, api_key: ENV["ZAP_API_KEY"])
message.deliver
```

## Configuration

| Option | Environment | Default |
|---|---|---|
| `api_key` | `ZAP_API_KEY` | required |
| `base_url` | `ZAP_BASE_URL` | `https://api.zapsmtp.com/v1` |
| `timeout` | | 60 s per attempt: connecting, each write and each read, the body's included |
| `max_retries` | | 2 |
| `default_headers` | | |
| `transport` | | `ZapSMTP::Transport::NetHTTP` (keeps a connection alive per thread) |

A client is safe to share between threads, and a forked process (Puma, Unicorn) never reuses its
parent's connections. A transport is any object with `call(request)`; tests can pass a stub.

## Reference

Every method is listed with its parameters in the [API reference](https://zapsmtp.com/docs/), and in
the YARD docs of `lib/zapsmtp/generated/resources.rb`. The resources mirror it: `zap.emails`,
`zap.emails.receiving`, `zap.threads`, `zap.domains`, `zap.webhooks`, `zap.actions`, `zap.templates`,
`zap.variables`, `zap.template_modules`, `zap.template_assets`, `zap.template_timers`, `zap.inbound`,
`zap.suppressions`, `zap.stats`, `zap.api_keys`, `zap.smtp_credentials`, `zap.logs`, `zap.usage`,
`zap.simulator`, `zap.dedicated_ips`.

## Development

The resources and models in `lib/zapsmtp/generated` are generated from the API reference by
`sdks/codegen` (`node sdks/codegen/generate.mjs --only ruby`); change the generator, never those
files. `bundle exec rake` runs the tests (every API operation against the conformance server in
`sdks/conformance`, the core, webhooks, the Rails integration; 100% line and branch coverage) and
RuboCop.
