# frozen_string_literal: true

require "json"

module ZapSMTP
  # A JSON object the API answered. Every documented field has a reader;
  # every field, documented or not, is kept and can be read with #[] or
  # #to_h. A missing field reads as nil; nothing about a response's shape is
  # ever fatal.
  #
  #   email = zap.emails.get(id)
  #   email.status        # => "delivered"
  #   email[:status]      # the same
  #   email.to_h          # every field, keys as symbols
  #   case email
  #   in { status: "bounced" } then ...
  #   end
  class Model
    class << self
      # The documented fields and how each is converted (see .cast).
      #
      # @api private
      def attribute_types
        @attribute_types ||= {}
      end

      # Declares a documented field and its reader. A field whose name is
      # already a method of every model (such as +method+ or +hash+) gets no
      # reader: read it with #[].
      #
      # @api private
      def attribute(name, type = nil)
        attribute_types[name] = type
        return if Model.public_method_defined?(name)

        define_method(name) { read(name) }
      end

      # The model of a parsed JSON value: a Hash becomes an instance of
      # +model+, anything else (or no model) is returned as it is.
      #
      # @api private
      def build(model, value, http_response = nil)
        return value unless model && value.is_a?(Hash)

        model.new(value, http_response: http_response)
      end

      # Converts a field's value: type is nil (as parsed), a model name, or
      # [:array, type] / [:map, type]. A value of another shape than expected
      # is returned as it is.
      #
      # @api private
      def cast(type, value)
        case type
        when nil then value
        when String then build(Models.const_get(type, false), value)
        else
          kind, inner = type
          if kind == :array
            value.is_a?(Array) ? value.map { |v| cast(inner, v) } : value
          else
            value.is_a?(Hash) ? value.transform_values { |v| cast(inner, v) } : value
          end
        end
      end

      # @api private
      def deep_dup(value)
        case value
        when Hash then value.to_h { |k, v| [k, deep_dup(v)] }
        when Array then value.map { |v| deep_dup(v) }
        when String then value.dup
        else value
        end
      end
    end

    # @return [ZapSMTP::Response, nil] the status, headers and request id of the
    #   answer this model came from (nil for a model nested in another)
    attr_reader :http_response

    # @param attributes [Hash] the parsed JSON object (or its fields as keyword arguments)
    def initialize(attributes = {}, http_response: nil, **fields)
      @attributes = attributes.merge(fields).transform_keys(&:to_sym)
      @http_response = http_response
      @cache = {}
    end

    # A field's value, by name (a String or Symbol). Documented fields are
    # converted like their readers; others are as parsed.
    def [](key)
      key = key.to_sym
      self.class.attribute_types.key?(key) ? read(key) : @attributes[key]
    end

    # Whether the API answered this field.
    def key?(key)
      @attributes.key?(key.to_sym)
    end

    # @return [Array<Symbol>] the names of the fields the API answered
    def keys
      @attributes.keys
    end

    def dig(key, *rest)
      value = self[key]
      rest.empty? || value.nil? ? value : value.dig(*rest)
    end

    # Every field as parsed, keys as symbols (a copy).
    #
    # @return [Hash]
    def to_h
      Model.deep_dup(@attributes)
    end

    def to_json(*args)
      @attributes.to_json(*args)
    end

    def deconstruct_keys(_keys)
      @attributes
    end

    def ==(other)
      other.instance_of?(self.class) && other.to_h == @attributes
    end
    alias eql? ==

    def hash
      [self.class, @attributes].hash
    end

    def inspect
      "#<#{self.class.name} #{@attributes.inspect}>"
    end
    alias to_s inspect

    private

    def read(name)
      return @cache[name] if @cache.key?(name)

      @cache[name] = Model.cast(self.class.attribute_types[name], @attributes[name])
    end
  end

  # A webhook request's body: see ZapSMTP::Webhook.verify.
  class WebhookEvent < Model
    # @!attribute [r] id
    #   @return [String, nil] evt_...; absent on email.received, thread.created and thread.replied (see Zap-Event-Id)
    attribute :id
    # @!attribute [r] type
    #   @return [String] e.g. "email.delivered"
    attribute :type
    # @!attribute [r] created_at
    #   @return [String] RFC 3339
    attribute :created_at
    # @!attribute [r] data
    #   @return [Hash] the event's data, keys as symbols
    attribute :data
  end
end
