# frozen_string_literal: true

module ZapSMTP
  # Builds attachments for emails.send: the content is sent base64-encoded,
  # and the content type follows the file name's extension unless given.
  #
  #   zap.emails.send(..., attachments: [ZapSMTP::Attachment.from_file("invoice.pdf")])
  #   ZapSMTP::Attachment.from_string("report.csv", csv)
  #   ZapSMTP::Attachment.from_file("logo.png", content_id: "logo") # inline: <img src="cid:logo">
  module Attachment
    CONTENT_TYPES = {
      ".pdf" => "application/pdf", ".png" => "image/png", ".jpg" => "image/jpeg", ".jpeg" => "image/jpeg",
      ".gif" => "image/gif", ".webp" => "image/webp", ".svg" => "image/svg+xml", ".txt" => "text/plain",
      ".csv" => "text/csv", ".html" => "text/html", ".ics" => "text/calendar", ".json" => "application/json",
      ".xml" => "application/xml", ".zip" => "application/zip", ".doc" => "application/msword",
      ".docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
      ".xls" => "application/vnd.ms-excel",
      ".xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    }.freeze

    module_function

    # An attachment from bytes or text.
    #
    # @param filename [String]
    # @param data [String] the content (any encoding: its bytes are sent)
    # @param content_type [String, nil] default: from the file name's extension
    # @param content_id [String, nil] makes it inline: reference it as cid:<content_id>
    # @return [Hash] filename, content (base64), content_type, content_id
    def from_string(filename, data, content_type: nil, content_id: nil)
      attachment = { filename: filename, content: [data.to_s].pack("m0") }
      type = content_type || content_type_for(filename)
      attachment[:content_type] = type if type
      attachment[:content_id] = content_id if content_id
      attachment
    end

    # An attachment read from a file.
    #
    # @param path [String, Pathname]
    # @param filename [String, nil] default: the file's own name
    # @return [Hash] filename, content (base64), content_type, content_id
    def from_file(path, filename: nil, content_type: nil, content_id: nil)
      from_string(filename || File.basename(path), File.binread(path),
                  content_type: content_type, content_id: content_id)
    end

    # The content type of a file name's extension, when it is a known one.
    #
    # @return [String, nil]
    def content_type_for(filename)
      CONTENT_TYPES[File.extname(filename.to_s).downcase]
    end
  end
end
