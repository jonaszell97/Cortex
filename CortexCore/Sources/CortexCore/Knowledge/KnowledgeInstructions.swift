import Foundation

/// What a model is told when it files text into the knowledge base or
/// tidies the inbox (docs/modules/KNOWLEDGE.md, "AI filing" and "The MCP
/// server"). The MCP prompts `file-this` and `tidy-inbox` use these with the MCP
/// tools; `$note`, `$todo` and `$tidy` use the same rules with a JSON answer.
public enum KnowledgeInstructions {
    /// How items are filed: the same for every way in.
    public static let filingRules = """
        The knowledge base is a folder of Markdown files, one folder per project. Each item is one of:
        - a note: something to look up again later (how something works, a command, a decision, a reference);
        - a skill: instructions for doing a task, step by step, written so that an agent can follow them;
        - a to-do: something to do, with an optional checklist and an optional due day.

        Filing rules:
        - Project: the one whose name and summary fit best. When none clearly fits, use the inbox. Never make up a project.
        - Title: short and specific, worded the way it would be searched for ("Convert a PNG to an SVG with potrace"), sentence case, no full stop. A to-do's title says what to do ("Rotate the S3 key on atlas").
        - Tags: at most three, lowercase, hyphens instead of spaces. Prefer tags that already exist; do not repeat the project as a tag.
        - Body: Markdown. Keep the wording, and every command, path, URL and number exactly as given; fix only obvious typos. Commands and code go into fenced code blocks with a language. No heading that repeats the title. Add nothing that is not in the text.
        - Skill rather than note: only when the text describes how to do a recurring task and reads as instructions. A skill's name is lowercase with hyphens ("deploy-with-ansible"); its description says what it does and when to use it, in one sentence.
        - To-dos: sub-steps become a checklist. A due day only when the text gives one, as YYYY-MM-DD.
        """

    /// The projects and tags a model chooses from.
    public static func context(projects: [KnowledgeProject], tags: [String], current: String? = nil) -> String {
        var lines = ["Projects (id: name — summary):"]
        for project in projects {
            var line = "- \(project.id): \(project.name)"
            if let summary = project.summary, !summary.isEmpty { line += " — \(summary)" }
            if project.isInbox { line += " (where unsorted items go)" }
            if project.id == current { line += " (linked to the current working directory)" }
            lines.append(line)
        }
        lines.append("")
        lines.append(tags.isEmpty ? "No tags are in use yet." : "Tags in use, most used first: \(tags.prefix(80).joined(separator: ", ")).")
        return lines.joined(separator: "\n")
    }

    /// The MCP prompt `file-this`: file `text` with the tools.
    public static func fileThis(_ text: String, projects: [KnowledgeProject], tags: [String], current: String?) -> String {
        """
        File the text below into my Cortex knowledge base.

        \(filingRules)

        \(context(projects: projects, tags: tags, current: current))

        Steps:
        1. Search the knowledge base (the `search` tool) for an item on the same subject. If one exists, add to it (`append_note`, or `update_note`/`update_todo`) instead of creating a duplicate.
        2. Otherwise create it with `create_note`, `create_skill` or `create_todo`, passing the project id.
        3. Answer with one line: what was written, and its path.

        The text:

        \(text)
        """
    }

    /// One inbox item as `tidy-inbox` lists it.
    public struct InboxEntry: Sendable {
        public var path: String
        public var kind: KnowledgeKind
        public var title: String
        public var tags: [String]
        public var body: String

        public init(_ item: KnowledgeItem) {
            path = item.path
            kind = item.kind
            title = item.title
            tags = item.tags
            body = item.body
        }
    }

    /// The MCP prompt `tidy-inbox`: a proposal per inbox item, applied
    /// after I confirm.
    public static func tidyInbox(_ entries: [InboxEntry], projects: [KnowledgeProject], tags: [String], excerptLength: Int = 400) -> String {
        let listed = entries.map { entry in
            var text = "### \(entry.path)\n\(entry.kind.rawValue): \(entry.title)"
            if !entry.tags.isEmpty { text += "\ntags: \(entry.tags.joined(separator: ", "))" }
            let body = entry.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                text += "\n\n" + (body.count > excerptLength ? String(body.prefix(excerptLength)) + " […]" : body)
            }
            return text
        }
        return """
            Tidy the inbox of my Cortex knowledge base.

            \(filingRules)

            \(context(projects: projects, tags: tags))

            For every inbox item below, propose one of: move it to a project (and retitle or tag it), merge it into an existing item (search first; then `append_note` to the existing one and `delete` this one), turn a note into a to-do or skill, or leave it in the inbox. Read an item with `read` when its excerpt is cut off.

            List all proposals first, numbered, one line each, and wait for me to confirm all or some of them. Then apply the confirmed ones: `update_note` or `update_todo` with `project` moves an item; a new title renames its file.

            \(entries.isEmpty ? "The inbox is empty: say so and stop." : "The inbox (\(entries.count) \(entries.count == 1 ? "item" : "items")):\n\n" + listed.joined(separator: "\n\n"))
            """
    }
}
