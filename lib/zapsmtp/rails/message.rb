# frozen_string_literal: true

module ZapSMTP
  module Rails
    # Turns a Mail::Message into emails.send parameters.
    module Message
      # Headers the message's own fields already carry, or the API sets.
      SKIPPED_HEADERS = %w[
        from to cc bcc reply-to subject date message-id mime-version content-type content-transfer-encoding
        content-disposition content-id return-path received dkim-signature
        x-zapsmtp-options x-zapsmtp-email-id
      ].freeze

      module_function

      # @param message [Mail::Message]
      # @param options [Hash{String => Object}] see ZapSMTP::Rails.set_options
      # @return [Hash{String => Object}]
      def params(message, options = {})
        params = {}
        from = addresses(message, :from)
        params["from"] = from.first if from
        { "to" => :to, "cc" => :cc, "bcc" => :bcc, "reply_to" => :reply_to }.each do |key, field|
          list = addresses(message, field)
          params[key] = list if list
        end
        params["subject"] = message.subject unless message.subject.nil?
        add_bodies(params, message) unless options.key?("template")
        headers = custom_headers(message)
        params["headers"] = headers unless headers.empty?
        attachments = message.attachments.map { |part| attachment(part) }
        params["attachments"] = attachments unless attachments.empty?
        params.merge(options).compact
      end

      # A field's addresses, formatted with their display names; nil when
      # the field is absent or empty.
      def addresses(message, name)
        field = message[name]
        return nil if field.nil?

        list = field.field.respond_to?(:addrs) ? field.addrs.map(&:format) : [field.value.to_s]
        list.empty? ? nil : list
      end

      def add_bodies(params, message)
        if message.multipart?
          params["html"] = message.html_part&.decoded
          params["text"] = message.text_part&.decoded
        elsif message.mime_type == "text/html"
          params["html"] = message.decoded
        else
          params["text"] = message.decoded
        end
      end

      # The message's other header fields: In-Reply-To, References, List-Unsubscribe, X-...
      def custom_headers(message)
        message.header.fields.each_with_object({}) do |field, out|
          next if SKIPPED_HEADERS.include?(field.name.downcase)

          out[field.name] = field.value.to_s
        end
      end

      def attachment(part)
        out = { "filename" => part.filename, "content" => [part.body.decoded].pack("m0"),
                "content_type" => part.mime_type }
        out["content_id"] = part.cid if part.inline?
        out.compact
      end
    end
  end
end
