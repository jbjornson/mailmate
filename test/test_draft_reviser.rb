# frozen_string_literal: true

require_relative "test_helper"
require "mailmate/draft_reviser"
require "tmpdir"

class TestDraftReviser < Minitest::Test
  R = Mailmate::DraftReviser

  # A stand-in for AppleScriptDriver that records calls and answers from a
  # script, so no MailMate is needed.
  class FakeDriver
    attr_reader :performed, :closed, :evaluated
    attr_accessor :window_list, :evaluate_result, :spawn_viewer, :close_fails

    def initialize(window_list: [])
      @window_list = window_list
      @performed = []
      @closed = []
      @evaluated = []
      @evaluate_result = "moved"
      @spawn_viewer = true
      @close_fails = false
    end

    def windows = @window_list
    def window_ids = @window_list.map(&:first)

    def perform(selector, *args)
      @performed << [selector, *args]
      @window_list += [[999, "Drafts"]] if selector == "newMessagesViewerWindow:" && @spawn_viewer
    end

    def evaluate(script)
      @evaluated << script
      @evaluate_result
    end

    def close_windows(ids)
      @closed.concat(ids)
      @window_list = @window_list.reject { |id, _| ids.include?(id) } unless @close_fails
    end

    def applescript_escape(s) = Mailmate::AppleScriptDriver.new.applescript_escape(s)
  end

  OLD = {
    "from" => "me@example.com", "to" => "Ann <ann@example.com>", "cc" => "cc@example.com", "bcc" => "",
    "subject" => "Re: Plans", "body" => "old body", "message_id" => "abc@example.com",
    "in_reply_to" => "parent@example.com", "references" => "<root@example.com> <parent@example.com>"
  }.freeze

  # ---- compose_args ----

  def test_compose_args_keeps_unchanged_fields_and_threading
    out = R.compose_args(OLD, { "body" => "new body" })
    assert_equal "new body", out["body"]
    assert_equal "Ann <ann@example.com>", out["to"]
    assert_equal "Re: Plans", out["subject"]
    assert_equal "me@example.com", out["from"]
    assert_equal "parent@example.com", out["in_reply_to"]
    assert_equal "<root@example.com> <parent@example.com>", out["references"]
  end

  def test_compose_args_drops_empty_optional_fields_so_a_field_can_be_cleared
    out = R.compose_args(OLD, { "cc" => "" })
    refute out.key?("cc")
    refute out.key?("bcc"), "an empty old bcc must not become an empty -b"
  end

  def test_compose_args_never_passes_the_old_message_id_or_send_now
    out = R.compose_args(OLD, { "send_now" => true, "message_id" => "x" })
    refute out.key?("send_now")
    refute out.key?("message_id")
  end

  # ---- location checks ----

  def test_draft_path_and_source_checks
    assert R.draft_path?("/s/IMAP/acct/Drafts.mailbox/Messages/1.eml")
    assert R.draft_path?("/s/IMAP/acct/INBOX.mailbox/drafts.mailbox/Messages/1.eml")
    refute R.draft_path?("/s/IMAP/acct/INBOX.mailbox/Messages/1.eml")
    assert R.drafts_source?("imap://me%40x.com@imap.x.com/Drafts")
    assert R.drafts_source?("imap://p1@mail.x.de/INBOX/Drafts")
    refute R.drafts_source?("imap://me%40x.com@imap.x.com/INBOX")
    assert R.trash_source?("imap://me%40x.com@imap.x.com/Trash")
    refute R.trash_source?("imap://me%40x.com@imap.x.com/Drafts")
  end

  # ---- reading a draft ----

  def test_read_fields_extracts_headers_body_and_threading
    Dir.mktmpdir do |dir|
      path = File.join(dir, "1.eml")
      File.write(path, <<~EML.gsub("\n", "\r\n"))
        From: Me <me@example.com>
        To: Ann <ann@example.com>, bob@example.com
        Subject: Re: Plans
        Message-ID: <abc@example.com>
        In-Reply-To: <parent@example.com>
        References: <root@example.com> <parent@example.com>
        Content-Type: text/plain; charset=utf-8

        Hello
        there
      EML
      f = R.read_fields(path)
      assert_equal "me@example.com", f["from"]
      assert_equal "Ann <ann@example.com>, bob@example.com", f["to"]
      assert_equal "Re: Plans", f["subject"]
      assert_equal "abc@example.com", f["message_id"]
      assert_equal "parent@example.com", f["in_reply_to"]
      assert_equal "<root@example.com> <parent@example.com>", f["references"]
      assert_equal "Hello\nthere\n", f["body"]
    end
  end

  # ---- revise: guards ----

  def with_lookup(path:, eml_id: 42, &blk)
    Mailmate::EmlLookup.stub(:resolve_id, eml_id) do
      Mailmate::EmlLookup.stub(:path_for, path, &blk)
    end
  end

  def test_revise_refuses_a_message_outside_drafts
    with_lookup(path: "/s/IMAP/acct/INBOX.mailbox/Messages/42.eml") do
      res = R.revise({ "id" => "42", "body" => "x" }, compose: ->(_a) { flunk "must not compose" }, driver: FakeDriver.new)
      assert res[:isError]
      assert_match(/not in a Drafts mailbox/, res[:content].first[:text])
    end
  end

  def test_revise_returns_a_compose_error_and_leaves_the_old_draft_alone
    driver = FakeDriver.new
    with_lookup(path: "/s/IMAP/acct/Drafts.mailbox/Messages/42.eml") do
      R.stub(:read_fields, OLD.dup) do
        R.stub(:draft_files, []) do
          res = R.revise({ "id" => "42" }, compose: ->(_a) { { content: [{ type: "text", text: "boom" }], isError: true } }, driver: driver)
          assert res[:isError]
        end
      end
    end
    assert_empty driver.performed
  end

  def test_revise_leaves_the_old_draft_when_the_new_one_never_appears
    driver = FakeDriver.new
    with_lookup(path: "/s/IMAP/acct/Drafts.mailbox/Messages/42.eml") do
      R.stub(:read_fields, OLD.dup) do
        R.stub(:draft_files, ["/s/IMAP/acct/Drafts.mailbox/Messages/42.eml"]) do
          R.stub(:save_timeout, 0.05) do
            res = R.revise({ "id" => "42", "body" => "new" }, compose: ->(_a) { { content: [], isError: false } }, driver: driver)
            refute res[:isError]
            report = JSON.parse(res[:content].first[:text])
            assert_nil report["new_draft"]
            assert_equal "left in place", report["old_draft"]["status"]
          end
        end
      end
    end
    assert_empty driver.performed, "no UI work when the new draft wasn't confirmed"
  end

  # ---- trash_old / select_and_trash ----

  def stub_source(seq, &blk)
    calls = 0
    Mailmate::EmlLookup.stub(:source_url_for, ->(_id) { v = seq[[calls, seq.size - 1].min]; calls += 1; v }, &blk)
  end

  def test_trash_old_moves_only_after_closing_the_old_composer
    driver = FakeDriver.new(window_list: [[7, "Re: Plans"], [8, "Inbox (3 messages)"]])
    status = nil
    stub_source(["imap://me@x/Drafts", "imap://me@x/Trash"]) do
      R.stub(:settle, 0) do
        status, = R.trash_old(42, OLD, driver.windows, driver)
      end
    end
    assert_equal "moved to Trash", status
    assert_equal [7, 999], driver.closed, "closes the old composer, then our own viewer"
    assert_includes driver.performed, ["goToMailbox:", "imap://me@x/Drafts"]
    assert_includes driver.performed, ["selectWithFilter:", "message-id = 'abc@example.com'"]
    assert_match(/item 1 of u is "message:\/\/%3Cabc@example.com%3E"/, driver.evaluated.first)
  end

  def test_trash_old_stops_when_the_selection_is_not_the_draft
    driver = FakeDriver.new
    driver.evaluate_result = "selection was not exactly the old draft (0 selected)"
    status = reason = nil
    stub_source(["imap://me@x/Drafts"]) do
      R.stub(:settle, 0) do
        status, reason = R.trash_old(42, OLD, [], driver)
      end
    end
    assert_equal "left in place", status
    assert_match(/not exactly the old draft/, reason)
    assert_equal [999], driver.closed, "our viewer is always closed"
  end

  def test_trash_old_stops_when_an_old_window_will_not_close
    driver = FakeDriver.new(window_list: [[7, "Re: Plans"]])
    driver.close_fails = true
    status = nil
    stub_source(["imap://me@x/Drafts"]) do
      status, = R.trash_old(42, OLD, driver.windows, driver)
    end
    assert_equal "left in place", status
    refute(driver.performed.any? { |sel, *| sel == "newMessagesViewerWindow:" })
  end

  def test_trash_old_refuses_a_message_id_that_cannot_go_in_a_filter
    driver = FakeDriver.new
    status = nil
    stub_source(["imap://me@x/Drafts"]) do
      status, = R.trash_old(42, OLD.merge("message_id" => "a'b@example.com"), [], driver)
    end
    assert_equal "left in place", status
    assert_empty driver.performed
  end

  def test_trash_old_requires_mailmate_to_list_it_in_drafts
    driver = FakeDriver.new
    status = nil
    stub_source(["imap://me@x/INBOX"]) do
      status, = R.trash_old(42, OLD, [], driver)
    end
    assert_equal "left in place", status
    assert_empty driver.performed
  end
end
