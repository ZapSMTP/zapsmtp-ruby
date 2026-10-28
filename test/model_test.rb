# frozen_string_literal: true

require "test_helper"

class ModelTest < Minitest::Test
  class Box < ZapSMTP::Model
    attribute :id
    attribute :tags, [:array, "Deleted"]
    attribute :by_name, [:map, "Deleted"]
    attribute :one, "Deleted"
    attribute :method
    attribute :hash
  end

  def box
    Box.new({ "id" => "b1", tags: [{ id: "t1" }, "raw"], by_name: { a: { id: "x" } }, one: { id: "o" },
              method: "GET", hash: "h", extra: { deep: ["v"] } })
  end

  def test_reads_documented_fields_converted_and_keeps_the_rest
    b = box
    assert_equal "b1", b.id
    assert_equal "b1", b[:id]
    assert_equal "b1", b["id"]
    assert_equal [ZapSMTP::Models::Deleted.new(id: "t1"), "raw"], b.tags
    assert_same b.tags, b.tags
    assert_equal "x", b.by_name[:a].id
    assert_equal "o", b.one.id
    assert_nil b.one.http_response
    assert_equal({ deep: ["v"] }, b[:extra])
    assert_equal "v", b.dig(:extra, :deep, 0)
    assert_nil b.dig(:missing, :x)
    assert_equal "GET", b[:method]
    assert_equal "h", b[:hash]
    assert_kind_of Integer, b.hash
    assert_kind_of Method, b.method(:id)
    assert b.key?(:extra)
    refute b.key?("nope")
    assert_includes b.keys, :extra
  end

  def test_is_lenient_about_shapes
    odd = Box.new(tags: "not a list", by_name: [1], one: "text")
    assert_equal "not a list", odd.tags
    assert_equal [1], odd.by_name
    assert_equal "text", odd.one
    assert_nil Box.new.id
    assert_nil ZapSMTP::Models::Email.new.to_h[:id]
  end

  def test_to_h_is_a_deep_copy
    b = box
    h = b.to_h
    h[:extra][:deep] << "w"
    h[:id] << "!"
    assert_equal ["v"], b[:extra][:deep]
    assert_equal "b1", b.id
    assert_equal "b1", b.to_h[:id]
  end

  def test_equality_json_inspect_and_pattern_matching
    assert_equal box, box
    assert box.eql?(box)
    assert_equal box.hash, box.hash
    refute_equal box, ZapSMTP::Models::Deleted.new(box.to_h)
    assert_equal box.to_h.to_json, box.to_json
    assert_equal "b1", JSON.parse(JSON.generate({ b: box }))["b"]["id"]
    assert_match(/\A#<ModelTest::Box \{.*id/, box.inspect)
    assert_equal box.inspect, box.to_s
    matched = case box
              in { id: "b1", one: { id: } } then id
              end
    assert_equal "o", matched
  end

  def test_an_unknown_key_never_shadows_a_known_field_or_a_method
    b = Box.new({ id: "b1", to_h: "x", http_response: "y", attribute_types: "z", cache: "c" })
    assert_equal "b1", b.id
    assert_kind_of Hash, b.to_h
    assert_nil b.http_response
    assert_equal "y", b[:http_response]
    assert_equal "c", b[:cache]
    page = ZapSMTP::Page.new({ data: [{ id: "a" }], has_more: false, next_page: "n", http_response: "h" },
                             model: Box, query: {}, paging: :before, loader: nil)
    assert_nil page.next_page
    assert_nil page.http_response
    assert_equal "n", page[:next_page]
  end

  def test_build_leaves_other_values_alone
    assert_nil ZapSMTP::Model.build(Box, nil)
    assert_equal [1], ZapSMTP::Model.build(Box, [1])
    assert_equal({ a: 1 }, ZapSMTP::Model.build(nil, { a: 1 }))
  end

  def test_generated_models_have_readers
    email = ZapSMTP::Models::Email.new(id: "e", tags: [{ name: "n", value: "v" }], last_event: "delivered")
    assert_equal "e", email.id
    assert_equal "delivered", email.last_event
    log = ZapSMTP::Models::Log.new(method: "POST")
    assert_equal "POST", log[:method]
    assert_kind_of Method, log.method(:to_h)
  end
end
