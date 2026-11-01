# frozen_string_literal: true

# Resolves a mailbox UUID (or smart-mailbox `set`) to a list of `Messages/`
# directories on disk, plus the smart-mailbox filters that apply on top.
#
# A smart mailbox's `set` is either a single source or a set expression:
#
#   "ALL_MESSAGES"                         a special id
#   "<uuid>"                               another mailbox (walked recursively)
#   "imap://<account>[/<path>]"            a whole account, or one folder in it
#   "INBOX:<account>"                      a special id limited to one account
#   {"operator" => "Any"|"All"|"None",     a set expression over any of the
#    "subSets" => [...]}                   above, nested as deep as needed
#
# Every .eml lives in exactly one `Messages/` dir, so the expression is
# evaluated at directory granularity: Any = union, All = intersection,
# None = every dir minus the union of its children.
#
# Filters from smart mailboxes along the way are returned as a list to AND
# together. That is exact for a plain chain and for All. A filter inside an
# Any branch (unless every branch has the same filters) or inside None would
# need a per-branch filter, which a flat AND list can't express — those
# raise ArgumentError instead of silently dropping the filter.

module Mailmate
  # @api public
  class SourceResolver
    # Standard-mailbox name patterns. Each special UUID maps to one or more
    # `*.mailbox` directories per account. Gmail nests system folders under
    # `[Gmail]/...`; iCloud is flat with different names.
    SPECIAL_DIRS = {
      "INBOX"   => ["INBOX.mailbox"],
      "DRAFTS"  => ["[Gmail].mailbox/Drafts.mailbox", "Drafts.mailbox"],
      "SENT"    => ["[Gmail].mailbox/Sent Mail.mailbox", "Sent Messages.mailbox"],
      "ARCHIVE" => ["[Gmail].mailbox/Archive.mailbox", "Archive.mailbox"],
      "JUNK"    => ["[Gmail].mailbox/Spam.mailbox", "Junk.mailbox"],
      "TRASH"   => ["[Gmail].mailbox/Trash.mailbox", "Deleted Messages.mailbox"],
    }.freeze

    # ALL_MESSAGES: union of INBOX/SENT/DRAFTS/ARCHIVE plus any custom labels.
    # Excludes Trash/Junk (per MailMate help: "All Messages" is everything except
    # deleted/junk).
    ALL_MESSAGES_EXCLUDES = %r{/(?:Trash|Junk|Spam|Deleted Messages)\.mailbox/Messages/?\z}.freeze

    # Special ids that only appear as set sources (not as mailboxes in the
    # graph). ALL_JUNK_DELETED is "All Messages" including junk and trash.
    SOURCE_ONLY_SPECIALS = %w[ALL_JUNK_DELETED].freeze

    IMAP_URL = %r{\Aimap://([^/]+)(?:/(.*))?\z}.freeze
    ACCOUNT_SCOPED = /\A([A-Z_]+):(.+)\z/.freeze

    def initialize(graph)
      @graph = graph
    end

    # Resolve a mailbox spec to {dirs:, filters:}.
    # `spec` may be a UUID, a name, a special UUID literal, or a set
    # expression Hash as found in a smart mailbox's `set`.
    # Returns:
    #   :dirs    => Array<String> of absolute paths to `Messages/` directories
    #   :filters => Array<String> of filter expressions to AND together
    def resolve(spec)
      resolve_node(spec, [], spec)
    end

    def special_dirs(uuid)
      case uuid
      when "ALL_MESSAGES"
        all_message_dirs
      when "ALL_JUNK_DELETED"
        all_dirs
      when "INBOX", "DRAFTS", "SENT", "ARCHIVE", "JUNK", "TRASH"
        per_account_dirs(SPECIAL_DIRS[uuid])
      else
        # Unknown special — return empty list and let the caller fail loudly.
        []
      end
    end

    # Every `Messages/` dir in the store, junk and trash included.
    def all_dirs
      Dir.glob("#{Mailmate.config.imap_root}/*/**/Messages")
         .select { |p| File.directory?(p) }
    end

    def all_message_dirs
      all_dirs.reject { |p| p =~ ALL_MESSAGES_EXCLUDES }
    end

    def per_account_dirs(suffixes)
      result = []
      Dir.glob("#{Mailmate.config.imap_root}/*").each do |account|
        next unless File.directory?(account)
        suffixes.each do |suffix|
          d = "#{account}/#{suffix}/Messages"
          result << d if File.directory?(d)
        end
      end
      result
    end

    # `imap://<account>` → every `Messages/` dir in that account.
    # `imap://<account>/<a>/<b>` → `<account>/<a>.mailbox/<b>.mailbox/Messages`.
    # A folder that isn't on disk (not synced, account removed) is empty.
    def imap_url_dirs(url)
      match = IMAP_URL.match(url) or raise ArgumentError, "Malformed IMAP source #{url.inspect}"
      account_dir = File.join(Mailmate.config.imap_root, match[1])
      path = match[2].to_s

      if path.empty?
        return Dir.glob("**/Messages", base: account_dir)
                  .map { |rel| File.join(account_dir, rel) }
                  .select { |p| File.directory?(p) }
      end

      segments = path.split("/").reject(&:empty?)
      # Folder names are stored decoded on disk; try the URL form as written
      # first, then percent-decoded, in case MailMate encoded the path.
      [segments, segments.map { |s| percent_decode(s) }].uniq.each do |segs|
        dir = File.join(account_dir, *segs.map { |s| "#{s}.mailbox" }, "Messages")
        return [dir] if File.directory?(dir)
      end
      []
    end

    private

    def resolve_node(node, path, root)
      case node
      when Hash   then resolve_set_expression(node, path, root)
      when String then resolve_leaf(node, path, root)
      else
        raise ArgumentError, "Mailbox #{root.inspect}: unsupported set source #{node.inspect}"
      end
    end

    def resolve_leaf(leaf, path, root)
      return { dirs: imap_url_dirs(leaf), filters: [] } if leaf.start_with?("imap://")

      m = @graph.by_uuid[leaf] || @graph.by_uuid[@graph.by_name[leaf]]
      key = (m && m[:uuid]) || leaf
      raise ArgumentError, "Cycle in mailbox resolution: #{(path + [key]).inspect}" if path.include?(key)

      # Collect this node's filter (if it has one). The special UUIDs
      # FLAGGED / SENT / etc. can themselves be smart mailboxes (e.g.
      # Brian's "Flagged" with filter `#flags.flag = '\Flagged'`); the
      # filter has to be picked up before we resolve the special to dirs.
      own = m && m[:filter] ? [m[:filter]] : []
      set = m && m[:set]

      # If `set` points elsewhere, walk to it (handles nested smart mailboxes
      # and set expressions).
      if set && set != key && set != leaf
        inner = resolve_node(set, path + [key], root)
        return { dirs: inner[:dirs], filters: own + inner[:filters] }
      end

      # Terminal — resolve to on-disk dirs.
      if special?(key)
        return { dirs: special_dirs(key), filters: own }
      end

      # "INBOX:<account>" — a special limited to one account. The graph may
      # hold an entry under that key too (MailMate stores per-account icons
      # that way), but it has no set of its own.
      if (scoped = ACCOUNT_SCOPED.match(key)) && resolvable?(scoped[1])
        inner = resolve_node(scoped[1], path + [key], root)
        prefix = "#{File.join(Mailmate.config.imap_root, scoped[2])}/"
        return { dirs: inner[:dirs].select { |d| d.start_with?(prefix) }, filters: own + inner[:filters] }
      end

      raise ArgumentError, "Mailbox #{root.inspect} can't be resolved to disk paths " \
                           "(uuid=#{leaf.inspect}, name=#{m && m[:name].inspect})"
    end

    def resolve_set_expression(expr, path, root)
      op = expr["operator"]
      subs = expr["subSets"]
      unless subs.is_a?(Array)
        raise ArgumentError, "Mailbox #{root.inspect}: set expression has no subSets list: #{expr.inspect}"
      end

      children = subs.map { |s| resolve_node(s, path, root) }

      case op
      when "Any"
        # (A where F) ∪ (B where F) = (A ∪ B) where F; differing filters can't
        # be merged into one AND list.
        filter_sets = children.map { |c| c[:filters] }.uniq
        if filter_sets.size > 1
          raise ArgumentError, "Mailbox #{root.inspect}: an 'Any' source set mixes branches " \
                               "with different smart-mailbox filters #{filter_sets.inspect}; " \
                               "per-branch filters aren't supported"
        end
        { dirs: children.flat_map { |c| c[:dirs] }.uniq, filters: filter_sets.first || [] }
      when "All"
        # A message is in exactly one dir, so (A where F) ∩ (B where G) =
        # (A ∩ B) where F and G.
        dirs = children.map { |c| c[:dirs] }.reduce(:&) || []
        { dirs: dirs, filters: children.flat_map { |c| c[:filters] }.uniq }
      when "None"
        filtered = children.flat_map { |c| c[:filters] }.uniq
        unless filtered.empty?
          raise ArgumentError, "Mailbox #{root.inspect}: a 'None' source set excludes a smart " \
                               "mailbox with filters #{filtered.inspect}; per-branch filters " \
                               "aren't supported"
        end
        { dirs: all_dirs - children.flat_map { |c| c[:dirs] }, filters: [] }
      else
        raise ArgumentError, "Mailbox #{root.inspect}: unknown set operator #{op.inspect}"
      end
    end

    def special?(id)
      MailboxGraph::SPECIAL_UUIDS.include?(id) || SOURCE_ONLY_SPECIALS.include?(id)
    end

    def resolvable?(id)
      special?(id) || @graph.by_uuid.key?(id)
    end

    def percent_decode(segment)
      segment.b.gsub(/%(\h\h)/) { Regexp.last_match(1).hex.chr }.force_encoding(Encoding::UTF_8)
    end
  end
end
