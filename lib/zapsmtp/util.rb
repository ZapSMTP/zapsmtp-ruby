# frozen_string_literal: true

require "securerandom"
require "time"
require "uri"

module ZapSMTP
  # Request building helpers used by the resources.
  #
  # @api private
  module Util
    module_function

    # A call's parameters: a Hash and keyword arguments, merged, with String keys.
    def params(params, kwargs)
      raise ArgumentError, "params must be a Hash, got #{params.class}" unless params.respond_to?(:each_pair)

      merged = {}
      params.each_pair { |k, v| merged[k.to_s] = v }
      kwargs.each_pair { |k, v| merged[k.to_s] = v }
      merged
    end

    # The given keys of params, or nil when it has none of them.
    def pick(params, keys)
      picked = params.slice(*keys)
      picked.empty? ? nil : picked
    end

    # A path segment, escaped. An empty value, "." or ".." can be no id: URL
    # normalization would resolve it into another path (percent-encoded too),
    # so it is refused before anything is sent.
    def seg(name, value)
      value = value.to_s
      if ["", ".", ".."].include?(value)
        raise ValidationError.new("#{name} must not be #{value.empty? ? "empty" : "\"#{value}\""}",
                                  code: "invalid_parameter")
      end
      URI.encode_www_form_component(value).gsub("+", "%20")
    end

    # The query string: nil values are left out, arrays repeat their key and
    # hashes become key[name]=value.
    def query_string(query)
      pairs = []
      (query || {}).each do |key, value|
        case value
        when nil then next
        when Array then value.each { |v| pairs << [key.to_s, scalar(v)] }
        when Hash then value.each { |k, v| pairs << ["#{key}[#{k}]", scalar(v)] }
        else pairs << [key.to_s, scalar(value)]
        end
      end
      URI.encode_www_form(pairs)
    end

    def scalar(value)
      value.respond_to?(:iso8601) ? value.iso8601 : value.to_s
    end

    # A value made ready for JSON: times as RFC 3339, models as hashes.
    def jsonable(value)
      case value
      when Hash then value.to_h { |k, v| [k, jsonable(v)] }
      when Array then value.map { |v| jsonable(v) }
      when Model then value.to_h
      else value.respond_to?(:iso8601) ? value.iso8601 : value
      end
    end

    # A parsed JSON value with every number that is not finite (NaN,
    # Infinity, or one too large for a Float) as nil.
    def finite(value)
      case value
      when Hash then value.transform_values { |v| finite(v) }
      when Array then value.map { |v| finite(v) }
      when Float then value.finite? ? value : nil
      else value
      end
    end

    # A multipart/form-data body.
    Form = Struct.new(:body, :content_type)

    # The multipart body of a file upload: field holds the file; name, when
    # given, is sent as the "name" field.
    def upload_form(field, file, name:, filename:)
      data, own_name = read_file(file)
      filename ||= name || own_name
      boundary = "zapsmtp-#{SecureRandom.hex(16)}"
      body = String.new(encoding: Encoding::BINARY)
      type = Attachment.content_type_for(filename) || "application/octet-stream"
      body << part_head(boundary, field, filename) << "Content-Type: #{type}\r\n\r\n".b << data.b << "\r\n".b
      body << part_head(boundary, "name", nil) << "\r\n".b << name.to_s.b << "\r\n".b unless name.nil?
      body << "--#{boundary}--\r\n".b
      Form.new(body, "multipart/form-data; boundary=#{boundary}")
    end

    def part_head(boundary, field, filename)
      head = "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{quote(field)}\""
      head << "; filename=\"#{quote(filename)}\"" if filename
      (head << "\r\n").b
    end

    # A form-data name or filename, escaped as browsers do.
    def quote(value)
      value.to_s.gsub("\"", "%22").gsub("\r", "%0D").gsub("\n", "%0A")
    end

    # The bytes of a file given by path (a String or Pathname, or a File) or
    # as another IO, and its own name.
    def read_file(file)
      path = file.respond_to?(:to_path) ? file.to_path : file
      return [File.binread(path), File.basename(path)] if path.is_a?(String)

      [file.read, "image"]
    end
  end
end
