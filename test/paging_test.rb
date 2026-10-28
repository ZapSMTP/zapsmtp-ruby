# frozen_string_literal: true

require "test_helper"

class PagingTest < Minitest::Test
  def test_walks_every_page_with_before_the_last_id_keeping_the_filters
    transport = StubTransport.new(page(%w[a b], true), page(%w[c], false))
    ids = client(transport).emails.list(limit: 2, after: "2026-01-01T00:00:00Z").auto_paging_each.map(&:id)
    assert_equal %w[a b c], ids
    assert_equal "https://api.test/v1/emails?limit=2&after=2026-01-01T00%3A00%3A00Z&before=b", transport.calls[1].url
  end

  def test_walks_suppressions_with_next_cursor
    transport = StubTransport.new(page(%w[a], true, next_cursor: "cur1"), page(%w[b], true, next_cursor: nil))
    ids = []
    client(transport).suppressions.list.auto_paging_each { |s| ids << s[:id] }
    assert_equal %w[a b], ids
    assert_equal "https://api.test/v1/suppressions?after=cur1", transport.calls[1].url
    assert_equal 2, transport.calls.size
  end

  def test_gives_one_page
    transport = StubTransport.new(page(%w[a], true, total: 9))
    first = client(transport).emails.list
    assert_instance_of ZapSMTP::Page, first
    assert_instance_of ZapSMTP::Models::Email, first.data[0]
    assert_equal({ id: "a" }, first.data[0].to_h)
    assert first.next_page?
    assert first.has_more?
    assert first.has_more
    assert_equal "list", first.object
    assert_equal 9, first[:total]
    assert_same first.data, first["data"]
    assert_equal({ object: "list", has_more: true, data: [{ id: "a" }], total: 9 }, first.to_h)
    assert_equal %w[a], first.map(&:id)
    assert_equal 1, first.each.size
    assert_same(first, first.each { |_| nil })
    assert_equal "req_1", first.http_response.request_id
    assert_match(/data=1 items has_more=true/, first.inspect)
    assert_equal 1, transport.calls.size
  end

  def test_stops_where_no_next_page_can_be_asked_for
    no_id = client(StubTransport.new(json(200, { object: "list", has_more: true, data: [{}] }))).emails.list
    refute no_id.next_page?
    assert_nil no_id.next_page
    unpaged = client(StubTransport.new(page(%w[a], true))).domains.list
    refute unpaged.next_page?
    assert_nil unpaged.next_page
    last = client(StubTransport.new(page(%w[a], false))).emails.list
    assert_nil last.next_page
    empty = client(StubTransport.new(json(200, { object: "list" }))).emails.list
    assert_equal [], empty.data
    refute empty.has_more?
    odd = client(StubTransport.new(json(200, { object: "list", has_more: true, data: ["x", { id: "" }] }))).emails.list
    assert_equal ["x", ZapSMTP::Models::Email.new(id: "")], odd.data
    refute odd.next_page?
    text = client(StubTransport.new(raw(200, "oops"))).emails.list
    assert_equal [], text.data
    assert_equal "list", text.object
  end

  def test_iterates_lazily_and_by_page
    transport = StubTransport.new(page(%w[a b], true), page(%w[c d], true), page(%w[e], false))
    list = client(transport).emails.list
    assert_equal %w[a b c], list.auto_paging_each.lazy.map(&:id).first(3)
    assert_equal 2, transport.calls.size
    again = StubTransport.new(page(%w[a b], true), page(%w[c d], true), page(%w[e], false))
    assert_equal([2, 2, 1], client(again).emails.list.each_page.map { |p| p.data.size })
    assert_nil(list.each_page { |_| nil })
    assert_nil(list.auto_paging_each { |_| nil })
  end

  def test_with_response_pages_on
    transport = StubTransport.new(page(%w[a], true), page(%w[b], false))
    first, response = client(transport).with_response.emails.list
    assert_equal 200, response.status
    assert_instance_of ZapSMTP::Page, first.next_page
  end
end

# Regressions Codex found in the core (paging, body reads): sdks/node/test/codex-regressions.test.ts.
class CodexRegressionsTest < Minitest::Test
  def list(data, more = true)
    json(200, { object: "list", data: data, has_more: more })
  end

  def test_next_page_check_only_inspects_the_page_and_does_not_issue_a_request
    transport = StubTransport.new(list([{ id: "email-1" }]))
    first = client(transport).emails.list
    assert first.next_page?
    assert first.next_page?
    assert first.has_more?
    assert_equal 1, transport.calls.size
  end

  def test_conversation_paging_uses_the_last_activity_time_and_the_tie_breaking_thread_id
    last = { id: "019aaa00-0000-7000-8000-000000000001", last_message_at: "2026-10-28T08:00:00Z" }
    transport = StubTransport.new(list([last]))
    client(transport).threads.list(limit: 1, unread: true).next_page
    q = query(transport.calls[1])
    assert_equal [last[:last_message_at]], q["before"]
    assert_equal [last[:id]], q["before_id"]
    assert_equal ["true"], q["unread"]
    assert_equal ["1"], q["limit"]
    refute client(StubTransport.new(list([{ id: "x" }]))).threads.list.next_page?
  end

  def test_received_attachments_page_forward_after_the_last_id
    transport = StubTransport.new(list([{ id: "a1" }, { id: "a2" }]))
    client(transport).emails.receiving.attachments.list("m1", limit: 2).next_page
    assert_equal ["a2"], query(transport.calls[1])["after"]
    assert_equal "/v1/emails/receiving/m1/attachments", URI(transport.calls[1].url).path
    refute client(StubTransport.new(list([]))).emails.receiving.attachments.list("m1").next_page?
  end

  def test_logs_page_back_with_before_or_forward_after_the_newest_entry_when_paged_with_after
    back = StubTransport.new(list([{ id: "l3" }, { id: "l2" }]))
    client(back).logs.list.next_page
    assert_equal ["l2"], query(back.calls[1])["before"]
    fwd = StubTransport.new(list([{ id: "l9" }, { id: "l8" }]))
    client(fwd).logs.list(after: "l7").next_page
    assert_equal ["l9"], query(fwd.calls[1])["after"]
    assert_nil query(fwd.calls[1])["before"]
    refute client(StubTransport.new(list([]))).logs.list(after: "l7").next_page?
    refute client(StubTransport.new(list([]))).logs.list.next_page?
    refute client(StubTransport.new(list([]))).emails.receiving.list.next_page?
  end

  def test_the_timeout_is_handed_to_the_transport_for_every_attempt
    transport = StubTransport.new(json(200, {}))
    client(transport, timeout: 20).emails.get("e", request_options: { timeout: 0.5 })
    client(transport, timeout: 20).emails.get("e")
    assert_equal [0.5, 20], transport.calls.map(&:timeout)
  end
end
