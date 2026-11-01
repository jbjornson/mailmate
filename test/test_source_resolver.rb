# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"

# SourceResolver tests. Builds a synthetic IMAP tree under a tmpdir with the
# standard MailMate mailbox layout (INBOX.mailbox, Sent Messages.mailbox,
# Trash.mailbox, etc.), points config at it, and exercises the special-UUID
# resolution paths.
class TestSourceResolver < Minitest::Test
  include Mailmate::TestHelpers

  def with_imap_tree
    Dir.mktmpdir("mm-source-resolver") do |dir|
      imap = File.join(dir, "Messages.noindex", "IMAP")
      # Account 1: iCloud-style flat layout
      FileUtils.mkdir_p(File.join(imap, "acct1.imap", "INBOX.mailbox", "Messages"))
      FileUtils.mkdir_p(File.join(imap, "acct1.imap", "Sent Messages.mailbox", "Messages"))
      FileUtils.mkdir_p(File.join(imap, "acct1.imap", "Archive.mailbox", "Messages"))
      FileUtils.mkdir_p(File.join(imap, "acct1.imap", "Deleted Messages.mailbox", "Messages"))
      FileUtils.mkdir_p(File.join(imap, "acct1.imap", "Junk.mailbox", "Messages"))
      # Account 2: Gmail-style nested layout
      FileUtils.mkdir_p(File.join(imap, "acct2.imap", "INBOX.mailbox", "Messages"))
      FileUtils.mkdir_p(File.join(imap, "acct2.imap", "[Gmail].mailbox", "Sent Mail.mailbox", "Messages"))
      FileUtils.mkdir_p(File.join(imap, "acct2.imap", "[Gmail].mailbox", "Trash.mailbox", "Messages"))

      with_config(env: { "MAILMATE_APP_SUPPORT_DIR" => dir }) do
        yield
      end
    end
  end

  def empty_graph
    Mailmate::MailboxGraph.new
  end

  # ---- per-account specials ----

  def test_inbox_resolves_across_accounts
    with_imap_tree do
      sr = Mailmate::SourceResolver.new(empty_graph)
      dirs = sr.resolve("INBOX")[:dirs]
      assert_equal 2, dirs.size
      assert dirs.any? { |d| d.include?("acct1.imap/INBOX.mailbox") }
      assert dirs.any? { |d| d.include?("acct2.imap/INBOX.mailbox") }
    end
  end

  def test_sent_handles_both_flat_and_gmail_nested
    with_imap_tree do
      sr = Mailmate::SourceResolver.new(empty_graph)
      dirs = sr.resolve("SENT")[:dirs]
      assert dirs.any? { |d| d.include?("Sent Messages.mailbox") },        "flat sent missing"
      assert dirs.any? { |d| d.include?("[Gmail].mailbox/Sent Mail.mailbox") }, "gmail sent missing"
    end
  end

  def test_trash_excludes_inbox
    with_imap_tree do
      sr = Mailmate::SourceResolver.new(empty_graph)
      dirs = sr.resolve("TRASH")[:dirs]
      refute dirs.any? { |d| d.include?("/INBOX.mailbox/") }
      assert dirs.any? { |d| d.include?("Deleted Messages.mailbox") || d.include?("Trash.mailbox") }
    end
  end

  # ---- ALL_MESSAGES ----

  def test_all_messages_excludes_trash_and_junk
    with_imap_tree do
      sr = Mailmate::SourceResolver.new(empty_graph)
      dirs = sr.resolve("ALL_MESSAGES")[:dirs]
      assert dirs.any? { |d| d.include?("INBOX.mailbox") }
      refute dirs.any? { |d| d =~ %r{/Trash\.mailbox/} },          "trash leaked into ALL"
      refute dirs.any? { |d| d =~ %r{/Junk\.mailbox/} },           "junk leaked into ALL"
      refute dirs.any? { |d| d =~ %r{/Deleted Messages\.mailbox/} }, "deleted leaked into ALL"
    end
  end

  # ---- smart-mailbox set chain ----

  def test_smart_mailbox_set_chain_accumulates_filters
    with_imap_tree do
      graph = empty_graph
      # Outer smart mailbox "MyFiltered" points to inner "Stage1" via set;
      # both have filters that must be ANDed when resolving the outer.
      graph.by_uuid["outer"] = { uuid: "outer", name: "MyFiltered", set: "inner", filter: "subject ~ 'a'" }
      graph.by_uuid["inner"] = { uuid: "inner", name: "Stage1",     set: "INBOX", filter: "subject ~ 'b'" }
      graph.by_name["MyFiltered"] = "outer"
      graph.by_name["Stage1"]     = "inner"

      res = Mailmate::SourceResolver.new(graph).resolve("outer")
      assert_includes res[:filters], "subject ~ 'a'"
      assert_includes res[:filters], "subject ~ 'b'"
      refute_empty res[:dirs]
    end
  end

  def test_unresolvable_mailbox_raises
    with_imap_tree do
      graph = empty_graph
      graph.by_uuid["floating"] = { uuid: "floating", name: "Floating" }
      assert_raises(ArgumentError) do
        Mailmate::SourceResolver.new(graph).resolve("floating")
      end
    end
  end

  # ---- set expressions ({"operator" => ..., "subSets" => [...]}) ----

  ACCT_A = "me%40example.com@imap.example.com"
  ACCT_B = "other%40example.org@imap.example.org"

  A_INBOX    = "#{ACCT_A}/INBOX.mailbox/Messages"
  A_SENT     = "#{ACCT_A}/Sent Messages.mailbox/Messages"
  A_TRASH    = "#{ACCT_A}/Deleted Messages.mailbox/Messages"
  A_JUNK     = "#{ACCT_A}/Junk.mailbox/Messages"
  A_PROJECTS = "#{ACCT_A}/Projects.mailbox/Messages"
  A_ALPHA    = "#{ACCT_A}/Projects.mailbox/Alpha.mailbox/Messages"
  A_SPACED   = "#{ACCT_A}/My Folder.mailbox/Messages"
  B_INBOX    = "#{ACCT_B}/INBOX.mailbox/Messages"
  B_SENT     = "#{ACCT_B}/[Gmail].mailbox/Sent Mail.mailbox/Messages"
  B_TRASH    = "#{ACCT_B}/[Gmail].mailbox/Trash.mailbox/Messages"

  A_ALL = [A_INBOX, A_SENT, A_TRASH, A_JUNK, A_PROJECTS, A_ALPHA, A_SPACED].freeze
  B_ALL = [B_INBOX, B_SENT, B_TRASH].freeze

  # Account dirs named the way MailMate names them on disk, so `imap://`
  # source URLs map straight onto them.
  def with_set_tree
    Dir.mktmpdir("mm-source-sets") do |dir|
      @imap_root = File.join(dir, "Messages.noindex", "IMAP")
      (A_ALL + B_ALL).each { |rel| FileUtils.mkdir_p(File.join(@imap_root, rel)) }
      with_config(env: { "MAILMATE_APP_SUPPORT_DIR" => dir }) { yield }
    end
  end

  # Resolve and return dirs relative to the IMAP root, sorted.
  def rel_dirs(graph, spec)
    res = Mailmate::SourceResolver.new(graph).resolve(spec)
    res[:dirs].map { |d| d.delete_prefix("#{@imap_root}/") }.sort
  end

  def any(*subs)  = { "operator" => "Any",  "subSets" => subs }
  def all(*subs)  = { "operator" => "All",  "subSets" => subs }
  def none(*subs) = { "operator" => "None", "subSets" => subs }

  def test_imap_account_url_is_every_dir_in_that_account
    with_set_tree do
      assert_equal A_ALL.sort, rel_dirs(empty_graph, "imap://#{ACCT_A}")
    end
  end

  def test_imap_url_with_path_is_that_one_folder
    with_set_tree do
      assert_equal [A_ALPHA], rel_dirs(empty_graph, "imap://#{ACCT_A}/Projects/Alpha")
      assert_equal [A_PROJECTS], rel_dirs(empty_graph, "imap://#{ACCT_A}/Projects")
      assert_equal [A_SPACED], rel_dirs(empty_graph, "imap://#{ACCT_A}/My%20Folder")
      assert_empty rel_dirs(empty_graph, "imap://#{ACCT_A}/Nope")
    end
  end

  def test_any_is_union
    with_set_tree do
      dirs = rel_dirs(empty_graph, any("imap://#{ACCT_A}/Projects/Alpha", "INBOX"))
      assert_equal [A_ALPHA, A_INBOX, B_INBOX].sort, dirs
    end
  end

  def test_all_is_intersection
    with_set_tree do
      assert_equal [A_INBOX], rel_dirs(empty_graph, all("imap://#{ACCT_A}", "INBOX"))
      assert_empty rel_dirs(empty_graph, all("imap://#{ACCT_B}", "imap://#{ACCT_A}/Projects"))
    end
  end

  def test_none_is_everything_minus_union
    with_set_tree do
      dirs = rel_dirs(empty_graph, none("imap://#{ACCT_B}", "TRASH"))
      assert_equal (A_ALL - [A_TRASH]).sort, dirs
    end
  end

  # Shape of a real "today" smart mailbox: some accounts, minus one account
  # and the trash.
  def test_nested_all_any_none
    with_set_tree do
      expr = all(any("imap://#{ACCT_A}", "imap://#{ACCT_B}"), none("imap://#{ACCT_B}", "TRASH"))
      assert_equal (A_ALL - [A_TRASH]).sort, rel_dirs(empty_graph, expr)
    end
  end

  def test_all_junk_deleted_is_every_dir
    with_set_tree do
      assert_equal (A_ALL + B_ALL).sort, rel_dirs(empty_graph, "ALL_JUNK_DELETED")
      # Unlike ALL_MESSAGES, it keeps trash and junk.
      assert_equal A_ALL.sort, rel_dirs(empty_graph, all("ALL_JUNK_DELETED", none("imap://#{ACCT_B}")))
    end
  end

  def test_account_scoped_special
    with_set_tree do
      assert_equal [B_INBOX], rel_dirs(empty_graph, "INBOX:#{ACCT_B}")
      assert_equal [A_INBOX, B_INBOX].sort,
                   rel_dirs(empty_graph, any("INBOX:#{ACCT_A}", "INBOX:#{ACCT_B}"))
    end
  end

  # MailMate keeps per-account icons as graph entries keyed "INBOX:<account>"
  # with no set; they must not hide the account-scoped meaning.
  def test_account_scoped_special_with_icon_only_graph_entry
    with_set_tree do
      graph = empty_graph
      key = "INBOX:#{ACCT_B}"
      graph.by_uuid[key] = { uuid: key, name: nil, set: nil, filter: nil, symbol: "star" }
      assert_equal [B_INBOX], rel_dirs(graph, any(key))
    end
  end

  def test_smart_mailbox_with_expression_set_keeps_its_filter
    with_set_tree do
      graph = empty_graph
      graph.by_uuid["today"] = {
        uuid: "today", name: "today", filter: "#date-received > 1 day ago",
        set: all("ALL_MESSAGES", none("imap://#{ACCT_B}", "TRASH")),
      }
      graph.by_name["today"] = "today"

      res = Mailmate::SourceResolver.new(graph).resolve("today")
      assert_equal ["#date-received > 1 day ago"], res[:filters]
      assert_equal (A_ALL - [A_TRASH, A_JUNK]).sort, rel_dirs(graph, "today")
    end
  end

  def test_filtered_mailbox_leaf_under_all_ands_its_filter
    with_set_tree do
      graph = empty_graph
      graph.by_uuid["tags"] = { uuid: "tags", name: "Tagged", set: "ALL_MESSAGES", filter: "#tags exists" }
      graph.by_uuid["box"]  = { uuid: "box", name: "Box", set: all("imap://#{ACCT_A}", "tags"), filter: "x = 1" }

      res = Mailmate::SourceResolver.new(graph).resolve("box")
      assert_equal ["x = 1", "#tags exists"], res[:filters]
      assert_equal (A_ALL - [A_TRASH, A_JUNK]).sort, rel_dirs(graph, "box")
    end
  end

  def test_unfiltered_mailbox_leaf_works_under_any_and_none
    with_set_tree do
      graph = empty_graph
      graph.by_uuid["projects"] = { uuid: "projects", name: "Projects", set: any("imap://#{ACCT_A}/Projects") }

      assert_equal [A_PROJECTS, B_INBOX].sort, rel_dirs(graph, any("projects", "INBOX:#{ACCT_B}"))
      assert_equal (A_ALL - [A_PROJECTS]).sort, rel_dirs(graph, none("projects", "imap://#{ACCT_B}"))
    end
  end

  def test_any_with_the_same_filter_on_every_branch_is_allowed
    with_set_tree do
      graph = empty_graph
      graph.by_uuid["f1"] = { uuid: "f1", name: "F1", set: "INBOX", filter: "x = 1" }
      graph.by_uuid["f2"] = { uuid: "f2", name: "F2", set: "SENT",  filter: "x = 1" }

      res = Mailmate::SourceResolver.new(graph).resolve(any("f1", "f2"))
      assert_equal ["x = 1"], res[:filters]
      assert_equal [A_INBOX, A_SENT, B_INBOX, B_SENT].sort, rel_dirs(graph, any("f1", "f2"))
    end
  end

  def test_per_branch_filters_raise
    with_set_tree do
      graph = empty_graph
      graph.by_uuid["filtered"] = { uuid: "filtered", name: "Filtered", set: "INBOX", filter: "x = 1" }
      sr = Mailmate::SourceResolver.new(graph)

      err = assert_raises(ArgumentError) { sr.resolve(any("filtered", "imap://#{ACCT_B}")) }
      assert_match(/'Any'.*per-branch filters/, err.message)

      err = assert_raises(ArgumentError) { sr.resolve(all("ALL_MESSAGES", none("filtered"))) }
      assert_match(/'None'.*per-branch filters/, err.message)
    end
  end

  def test_unknown_leaf_and_operator_raise
    with_set_tree do
      sr = Mailmate::SourceResolver.new(empty_graph)
      err = assert_raises(ArgumentError) { sr.resolve(any("INBOX", "NOT_A_SOURCE")) }
      assert_match(/NOT_A_SOURCE/, err.message)
      err = assert_raises(ArgumentError) { sr.resolve({ "operator" => "Xor", "subSets" => ["INBOX"] }) }
      assert_match(/Xor/, err.message)
    end
  end

  def test_cycle_through_set_expression_raises_but_shared_leaf_does_not
    with_set_tree do
      graph = empty_graph
      graph.by_uuid["a"] = { uuid: "a", name: "A", set: any("INBOX", "b") }
      graph.by_uuid["b"] = { uuid: "b", name: "B", set: all("ALL_MESSAGES", "a") }
      err = assert_raises(ArgumentError) { Mailmate::SourceResolver.new(graph).resolve("a") }
      assert_match(/Cycle/, err.message)

      # The same mailbox in two branches is a DAG, not a cycle.
      graph.by_uuid["inbox"] = { uuid: "inbox", name: "In", set: "INBOX" }
      assert_equal [A_INBOX, B_INBOX].sort, rel_dirs(graph, any("inbox", all("inbox", "ALL_MESSAGES")))
    end
  end
end
