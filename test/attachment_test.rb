# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "pathname"

class AttachmentTest < Minitest::Test
  def test_encodes_bytes_and_text_and_guesses_the_content_type
    assert_equal({ filename: "a.pdf", content: "AQI=", content_type: "application/pdf" },
                 ZapSMTP::Attachment.from_string("a.pdf", "\x01\x02".b))
    assert_equal({ filename: "notes", content: "aGk=", content_type: "text/plain", content_id: "n1" },
                 ZapSMTP::Attachment.from_string("notes", "hi", content_type: "text/plain", content_id: "n1"))
    assert_nil ZapSMTP::Attachment.from_string("x.unknown", "x")[:content_type]
    assert_equal "0J8=", ZapSMTP::Attachment.from_string("u.txt", "П")[:content]
  end

  def test_reads_a_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "Report.PNG")
      File.binwrite(path, "\x89P".b)
      assert_equal({ filename: "Report.PNG", content: "iVA=", content_type: "image/png" },
                   ZapSMTP::Attachment.from_file(path))
      assert_equal "r.png", ZapSMTP::Attachment.from_file(Pathname(path), filename: "r.png")[:filename]
      assert_equal "logo", ZapSMTP::Attachment.from_file(path, content_id: "logo")[:content_id]
    end
  end

  def test_goes_into_a_send
    transport = StubTransport.new(json(200, { id: "e1" }))
    client(transport).emails.send(from: "a", to: "b", subject: "s", text: "t",
                                  attachments: [ZapSMTP::Attachment.from_string("a.txt", "hi")])
    assert_equal [{ "filename" => "a.txt", "content" => "aGk=", "content_type" => "text/plain" }],
                 JSON.parse(transport.calls[0].body)["attachments"]
  end
end
