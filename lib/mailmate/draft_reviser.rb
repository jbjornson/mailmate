# frozen_string_literal: true

require "json"
require "mailmate/applescript_driver"
require "mailmate/eml_lookup"
require "mailmate/mid_url"

module Mailmate
  # @api private
  #
  # Replace a saved draft with a revised copy (the MCP `revise_draft` tool).
  #
  # MailMate can't edit a draft in place from outside: opening a draft's
  # `mid:` URL opens a composer, where `deleteMessage:` does nothing, and a
  # rename on disk isn't picked up. So this
  #
  #   1. composes the new version through the normal draft path, copying
  #      every field the caller didn't change (including reply threading),
  #   2. waits for the new draft's .eml to land in a Drafts mailbox,
  #   3. closes windows that were already showing the old draft,
  #   4. opens its own viewer, selects the old draft with selectWithFilter:,
  #      and moves it to Trash only if the selection is exactly that draft.
  #
  # Any step that can't be confirmed leaves the old draft where it is and
  # says so in the result. Nothing here can send mail.
  module DraftReviser
    extend self

    EDITABLE      = %w[from to cc bcc subject body].freeze
    SAVE_TIMEOUT  = 15.0
    TRASH_TIMEOUT = 10.0
    POLL          = 0.25

    # ---- reading the old draft ----------------------------------------------

    # A draft is something stored in a Drafts mailbox. MailMate's own source
    # index has to agree before we act on it through the UI.
    def draft_path?(path)
      path.to_s.match?(%r{/drafts\.mailbox/Messages/[^/]+\.eml\z}i)
    end

    def drafts_source?(source)
      source.to_s.match?(%r{\Aimap://[^/]+/(?:.+/)?drafts\z}i)
    end

    # Header fields and body of the draft at `path`, in the shape the
    # `draft` tool takes.
    def read_fields(path)
      require "mail"
      m = Mail.read(path)
      refs = Array(m.references).map { |r| "<#{r}>" }.join(" ")
      {
        "from"        => Array(m.from).first.to_s,
        "to"          => Array(m[:to]&.formatted).join(", "),
        "cc"          => Array(m[:cc]&.formatted).join(", "),
        "bcc"         => Array(m[:bcc]&.formatted).join(", "),
        "subject"     => m.subject.to_s,
        "body"        => body_text(m),
        "message_id"  => m.message_id.to_s,
        "in_reply_to" => Array(m.in_reply_to).first.to_s,
        "references"  => refs,
      }
    end

    def body_text(mail)
      part = mail.text_part || (mail.multipart? ? nil : mail)
      return "" unless part
      part.decoded.to_s.dup.force_encoding("UTF-8").scrub.gsub("\r\n", "\n")
    end

    # Arguments for the `draft` tool: what the caller passed wins, everything
    # else comes from the old draft. Empty optional fields are dropped so no
    # empty -c / -b reaches emate.
    def compose_args(old, args)
      out = {}
      EDITABLE.each do |k|
        v = args.key?(k) ? args[k].to_s : old[k].to_s
        out[k] = v unless v.empty? && k != "body"
      end
      out["in_reply_to"] = old["in_reply_to"] unless old["in_reply_to"].to_s.empty?
      out["references"]  = old["references"]  unless old["references"].to_s.empty?
      out
    end

    # ---- the whole operation -------------------------------------------------

    # `compose` is a callable taking draft-tool args and returning an MCP
    # result hash (the MCP server passes its own `call_draft`).
    def revise(args, compose:, driver: Mailmate::AppleScriptDriver.new)
      id = args["id"].to_s
      return error("revise_draft needs `id` (eml-id or Message-ID of the draft).") if id.empty?

      eml_id = Mailmate::EmlLookup.resolve_id(id)
      return error("Not found: #{id.inspect}") if eml_id.nil? || eml_id.zero?

      path = Mailmate::EmlLookup.path_for(eml_id)
      return error("Not found: #{eml_id}.eml") unless path
      return error("#{eml_id} is not in a Drafts mailbox; revise_draft only replaces drafts.") unless draft_path?(path)

      old = read_fields(path)
      before_files   = draft_files
      before_windows = driver.windows

      res = compose.call(compose_args(old, args))
      return res if res[:isError]

      new_path = wait_for_new_draft(before_files)
      report = {
        new_draft: new_path ? { eml_id: File.basename(new_path, ".eml").to_i, mailbox: mailbox_of(new_path) } : nil,
        old_draft: { eml_id: eml_id, message_id: old["message_id"] },
      }

      if new_path.nil?
        report[:old_draft][:status] = "left in place"
        report[:old_draft][:reason] = "the new draft did not appear in a Drafts mailbox within #{save_timeout.to_i}s; " \
                                      "check MailMate before deleting the old one"
      else
        status, reason = trash_old(eml_id, old, before_windows, driver)
        report[:old_draft][:status] = status
        report[:old_draft][:reason] = reason if reason
      end

      { content: [{ type: "text", text: JSON.pretty_generate(report) }], isError: false }
    rescue ArgumentError, Mailmate::AppleScriptDriver::Error => e
      error("#{e.class}: #{e.message}")
    end

    # ---- removing the old draft ---------------------------------------------

    # Returns [status, reason_or_nil]. status is "moved to Trash" or
    # "left in place".
    def trash_old(eml_id, old, before_windows, driver)
      source = Mailmate::EmlLookup.source_url_for(eml_id).to_s
      return ["left in place", "MailMate does not list it in a Drafts mailbox (#{source.empty? ? "no source" : source})"] unless drafts_source?(source)

      bare = old["message_id"].to_s.sub(/\A</, "").sub(/>\z/, "")
      return ["left in place", "its Message-ID can't be used in a MailMate filter"] if bare.empty? || bare.match?(/['"\\\s]/)

      # Windows that were already showing the old draft (usually its
      # composer, left open by `draft`). An open composer could save it back.
      stale = before_windows.select { |_id, name| name == old["subject"] && !name.to_s.empty? }.map(&:first)
      unless stale.empty?
        driver.close_windows(stale)
        still_open = driver.windows.map(&:first) & stale
        return ["left in place", "a window showing it did not close (unsaved changes?)"] unless still_open.empty?
      end

      outcome = select_and_trash(driver, source, bare, Mailmate::MidUrl.message_url_for(bare))
      return ["left in place", outcome] unless outcome == "moved"

      if wait_until { trash_source?(Mailmate::EmlLookup.source_url_for(eml_id).to_s) }
        ["moved to Trash", nil]
      else
        ["left in place", "MailMate accepted the move but did not report it in Trash within #{trash_timeout.to_i}s; check MailMate"]
      end
    end

    # Open our own viewer, go to the draft's mailbox, select it by
    # Message-ID, and trash it only if exactly that message is selected.
    # Returns "moved" or a reason it didn't.
    def select_and_trash(driver, source, bare_id, expected_url)
      ids_before = driver.window_ids
      driver.perform("newMessagesViewerWindow:")
      viewer = nil
      wait_until(timeout: 3.0) { (viewer = (driver.window_ids - ids_before).first) }
      return "could not open a MailMate viewer window" unless viewer

      begin
        driver.perform("goToMailbox:", source)
        sleep settle
        driver.perform("selectWithFilter:", "message-id = '#{bare_id}'")
        sleep settle
        url = driver.applescript_escape(expected_url)
        result = driver.evaluate(<<~AS)
          tell application "MailMate"
            set u to message url of every message
            if (count of u) is 1 then
              if item 1 of u is "#{url}" then
                perform {"moveToMailbox:", "trash"}
                return "moved"
              end if
            end if
            return "selection was not exactly the old draft (" & (count of u) & " selected)"
          end tell
        AS
        result.to_s
      ensure
        driver.close_windows([viewer])
      end
    end

    # ---- helpers --------------------------------------------------------------

    def trash_source?(source)
      source.match?(%r{/(?:trash|deleted messages|deleted items)\z}i)
    end

    def draft_files
      Dir.glob(File.join(Mailmate.config.imap_root, "*", "**", "[Dd]rafts.mailbox", "Messages", "*.eml"))
    end

    def wait_for_new_draft(before)
      found = nil
      wait_until(timeout: save_timeout) { (found = (draft_files - before).max_by { |p| File.mtime(p) rescue Time.at(0) }) }
      found
    end

    def mailbox_of(path)
      path.sub("#{Mailmate.config.imap_root}/", "").sub(%r{/Messages/[^/]+\.eml\z}, "")
    end

    def save_timeout  = SAVE_TIMEOUT
    def trash_timeout = TRASH_TIMEOUT
    def settle        = 0.8

    def wait_until(timeout: trash_timeout)
      deadline = Time.now + timeout
      loop do
        return true if yield
        return false if Time.now >= deadline
        sleep POLL
      end
    end

    def error(msg)
      { content: [{ type: "text", text: msg }], isError: true }
    end
  end
end
