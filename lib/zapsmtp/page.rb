# frozen_string_literal: true

module ZapSMTP
  # One page of a list. #each walks this page; #auto_paging_each walks every
  # page, asking for the next one only when the previous is used up.
  #
  #   page = zap.emails.list(limit: 50)
  #   page.data              # this page's emails
  #   page.next_page         # the next page, or nil
  #   zap.emails.list(status: "bounced").auto_paging_each { |email| ... }
  #   zap.emails.list.auto_paging_each.lazy.select { ... }.first(10)
  class Page
    include Enumerable

    # @return [Array<ZapSMTP::Model>] this page's items
    attr_reader :data
    # @return [String, nil] the cursor of the next page, for lists paged by cursor
    attr_reader :next_cursor
    # @return [ZapSMTP::Response, nil] the status, headers and request id of this page's answer
    attr_reader :http_response

    # @api private
    def initialize(body, model:, query:, paging:, loader:, http_response: nil)
      @body = body.is_a?(Hash) ? body : {}
      items = @body[:data].is_a?(Array) ? @body[:data] : []
      @data = items.map { |item| Model.build(model, item) }
      @has_more = @body[:has_more] == true
      @next_cursor = @body[:next_cursor]
      @http_response = http_response
      @next_query = @has_more ? Page.next_query(query || {}, items, @next_cursor, paging) : nil
      @loader = loader
    end

    # @return [String] "list"
    def object
      @body.fetch(:object, "list")
    end

    # Whether the API said there are more items after this page.
    def has_more?
      @has_more
    end
    alias has_more has_more?

    # Whether there is a next page to ask for. Makes no request.
    def next_page?
      !@next_query.nil?
    end

    # The next page (one request), or nil after the last one.
    #
    # @return [ZapSMTP::Page, nil]
    def next_page
      @next_query && @loader.call(@next_query)
    end

    # Yields this page's items.
    def each(&block)
      return enum_for(:each) { @data.size } unless block

      @data.each(&block)
      self
    end

    # Yields every item of this page and the pages after it, loading each
    # page when the previous one is used up. Without a block, an Enumerator
    # (use .lazy to stop early without loading further pages).
    def auto_paging_each(&block)
      return enum_for(:auto_paging_each) unless block

      each_page { |page| page.data.each(&block) }
      nil
    end

    # Yields this page and every page after it.
    def each_page
      return enum_for(:each_page) unless block_given?

      page = self
      while page
        yield page
        page = page.next_page
      end
      nil
    end

    # A field of the list object, by name.
    def [](key)
      key.to_sym == :data ? @data : @body[key.to_sym]
    end

    # The list object as parsed, keys as symbols (a copy).
    def to_h
      Model.deep_dup(@body)
    end

    def inspect
      "#<#{self.class.name} data=#{@data.size} items has_more=#{@has_more}>"
    end

    # The query of the page after one (docs/DESIGN-sdks.md, paging): the
    # caller's query plus where the next page starts, or nil when there is no
    # way to ask for it.
    #
    # @api private
    def self.next_query(query, items, cursor, paging)
      first = items.first
      last = items.last
      case paging
      when :cursor then present(cursor) && query.merge("after" => cursor)
      when :before then (id = field(last, :id)) && query.merge("before" => id)
      when :after then (id = field(last, :id)) && query.merge("after" => id)
      when :logs then logs_query(query, first, last)
      when :thread then thread_query(query, last)
      end
    end

    # With after, logs come oldest-first from the server and newest-first in
    # the page: the next newer page starts after the page's newest entry.
    #
    # @api private
    def self.logs_query(query, first, last)
      if query["after"].nil?
        (id = field(last, :id)) && query.merge("before" => id)
      else
        (id = field(first, :id)) && query.merge("after" => id)
      end
    end

    # @api private
    def self.thread_query(query, last)
      id = field(last, :id)
      at = field(last, :last_message_at)
      id && at && query.merge("before" => at, "before_id" => id)
    end

    # @api private
    def self.field(item, key)
      present(item.is_a?(Hash) ? item[key] : nil)
    end

    # @api private
    def self.present(value)
      value.nil? || value == "" ? nil : value
    end
  end
end
