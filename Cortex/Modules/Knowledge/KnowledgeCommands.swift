import Foundation
import CortexCore

/// What a filing command hands to the palette to confirm.
enum KnowledgeReviewContent: Sendable, Equatable {
    /// `$note`, `$todo`: the item to write.
    case proposal(KnowledgeFiling.Proposal)
    /// `$tidy`: what to do with each inbox item.
    case tidy([KnowledgeFiling.TidyProposal])
}

/// `$note`, `$todo` and `$tidy` (docs/modules/KNOWLEDGE.md, "AI filing"),
/// contributed to Commands while AI is on. Each sends what it files, the projects
/// and the tags to the AI module's vendor, then hands the proposal to the
/// palette, where ⏎ writes it: nothing is written unseen. Like AI's own commands,
/// they resolve to a job and are `isRemote`, so nothing is sent before ⏎ and never
/// a clip marked sensitive; typed text that looks like a secret is refused too,
/// and `$tidy` leaves such inbox items out.
struct KnowledgeFilingCommand: Command {
    enum Kind: String, Sendable, CaseIterable {
        case note, todo, tidy
    }

    let kind: Kind
    let vendor: AIVendorID
    let model: String
    let index: KnowledgeIndex
    /// The AI module's send: its key, its usage counts.
    let send: @Sendable (AIRequest) async throws -> AIResponse
    /// Shows the proposal in the palette.
    let review: @MainActor @Sendable (KnowledgeReviewContent) -> Void

    var id: String { "knowledge.ai-\(kind.rawValue)" }
    var name: String { kind.rawValue }

    var title: String {
        switch kind {
        case .note: "File as Note"
        case .todo: "File as To-Do"
        case .tidy: "Tidy the Inbox"
        }
    }

    var summary: String {
        switch kind {
        case .note: "\(vendor.name) picks the project, title and tags and writes the note; you see it before it is saved."
        case .todo: "\(vendor.name) picks the project, title, tags, due day and checklist; you see the to-do before it is added."
        case .tidy: "\(vendor.name) proposes a project, title and tags, or a merge, for each inbox item; you choose which to apply."
        }
    }

    var symbol: String {
        switch kind {
        case .note: "square.and.pencil"
        case .todo: "checklist"
        case .tidy: "tray.and.arrow.up"
        }
    }

    var keywords: [String] {
        let own: [String] = switch kind {
        case .note: ["knowledge", "save", "capture", "file", "skill"]
        case .todo: ["task", "add", "capture", "file", "reminder"]
        case .tidy: ["inbox", "sort", "organize", "file", "clean"]
        }
        return ["ai", vendor.name] + own
    }

    var argument: CommandArgument? {
        switch kind {
        case .note:
            CommandArgument(
                title: "Text", placeholder: "potrace only reads bitmaps, convert with magick first", kind: .prompt,
                suggestions: .clipboardText)
        case .todo:
            CommandArgument(title: "Text", placeholder: "fix the restic backup by friday", kind: .prompt, suggestions: .clipboardText)
        case .tidy:
            nil
        }
    }

    var isRemote: Bool { true }

    /// Says what will be sent to whom. Nothing is read or sent here: the job
    /// reads the knowledge base and asks the vendor.
    func resolve(_ invocation: CommandInvocation) async throws -> CommandOutcome {
        let plan = switch kind {
        case .note, .todo:
            "Sends the text, your project names and summaries and your tags to \(vendor.name) (\(model)), then shows the \(kind == .note ? "note" : "to-do") for ⏎ to save."
        case .tidy:
            "Sends the inbox (titles and the first 400 characters of each item, leaving out any that look like a password or key), your projects and your tags to \(vendor.name) (\(model)), then lists the proposals for you to apply."
        }
        let input = invocation.input
        return .job(plan: plan) { _ in try await file(input) }
    }

    /// Asks the vendor, then hands the proposal to the palette.
    private func file(_ input: ActionInput) async throws -> ActionOutput {
        let filing = KnowledgeFiling.Context(projects: try index.projects(), tags: try index.tags().map(\.tag))
        switch kind {
        case .note, .todo:
            guard let text = input.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                throw QuickActionError("\(title) needs a text")
            }
            // Typed text is never marked sensitive, so `isRemote` alone
            // would let a pasted key through.
            guard !SensitiveTextDetector.looksSensitive(text) else {
                throw QuickActionError("It looks like a password or key, so it is not sent to \(vendor.name). Save it with ? instead.")
            }
            let target: KnowledgeFiling.Target = kind == .note ? .note : .todo
            let answer = try await ask(KnowledgeFiling.request(target, text: text, context: filing))
            let proposal = try KnowledgeFiling.proposal(target, from: answer, text: text, context: filing)
            await review(.proposal(proposal))
            return .handled
        case .tidy:
            let entries = try KnowledgeFiling.tidyEntries(index: index)
            guard !entries.isEmpty else { return .done("The inbox is empty.") }
            let answer = try await ask(KnowledgeFiling.tidyRequest(entries, context: filing))
            let proposals = try KnowledgeFiling.tidyProposals(from: answer, entries: entries, context: filing)
            guard !proposals.isEmpty else { return .done("\(vendor.name) would leave every inbox item where it is.") }
            await review(.tidy(proposals))
            return .handled
        }
    }

    private func ask(_ request: KnowledgeFiling.Request) async throws -> String {
        guard case .text(let answer) = try await send(request.ai(model: model)).content else {
            throw QuickActionError("\(vendor.name) sent no text")
        }
        return answer
    }
}
