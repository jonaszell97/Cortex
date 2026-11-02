import AppKit
import SwiftUI
import CortexCore

/// `$note`'s or `$todo`'s proposal before it is written: ⇥ and ⇧⇥ change
/// the project, ⏎ writes it, esc discards it.
@MainActor
@Observable
final class ProposalReview {
    private(set) var proposal: KnowledgeFiling.Proposal
    /// The inbox first, then the rest by name, as the model chose from.
    let projects: [KnowledgeProject]

    init(_ proposal: KnowledgeFiling.Proposal, projects: [KnowledgeProject]) {
        self.proposal = proposal
        let inbox = projects.first(where: \.isInbox) ?? KnowledgeProject(id: KnowledgeProject.inboxID)
        self.projects = [inbox] + projects.filter { !$0.isInbox }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var project: KnowledgeProject {
        projects.first { $0.id == proposal.project } ?? KnowledgeProject(id: proposal.project)
    }

    /// The file it will be written to; a taken name gets `-2` on saving.
    var path: String {
        switch proposal.kind {
        case .skill: "\(proposal.project)/skills/\(KnowledgeSlug.make(proposal.title, maxLength: 64))/SKILL.md"
        case .todo: KnowledgeFolder.todoPath(project: proposal.project, title: proposal.title, date: .now)
        default: KnowledgeFolder.notePath(project: proposal.project, title: proposal.title, date: .now)
        }
    }

    /// The next (or previous) project, round the list.
    func changeProject(by delta: Int) {
        guard !projects.isEmpty else { return }
        let current = projects.firstIndex { $0.id == proposal.project } ?? 0
        let next = ((current + delta) % projects.count + projects.count) % projects.count
        proposal.project = projects[next].id
    }
}

/// `$tidy`'s proposals: all are applied with ⏎ except those skipped with
/// ⇥; ↑↓ choose the one ⇥ skips or takes back.
@MainActor
@Observable
final class TidyReview {
    let proposals: [KnowledgeFiling.TidyProposal]
    let projects: [KnowledgeProject]
    private(set) var skipped: Set<String> = []
    private(set) var selection = 0

    init(_ proposals: [KnowledgeFiling.TidyProposal], projects: [KnowledgeProject]) {
        self.proposals = proposals
        self.projects = projects
    }

    var selected: KnowledgeFiling.TidyProposal? {
        proposals.indices.contains(selection) ? proposals[selection] : nil
    }

    var included: [KnowledgeFiling.TidyProposal] {
        proposals.filter { !skipped.contains($0.id) }
    }

    func isIncluded(_ proposal: KnowledgeFiling.TidyProposal) -> Bool {
        !skipped.contains(proposal.id)
    }

    func move(by delta: Int) {
        guard !proposals.isEmpty else { return }
        selection = min(max(selection + delta, 0), proposals.count - 1)
    }

    func toggleSelected() {
        guard let id = selected?.id else { return }
        if skipped.contains(id) { skipped.remove(id) } else { skipped.insert(id) }
    }

    func projectName(_ id: String) -> String {
        projects.first { $0.id == id }?.name ?? KnowledgeProject.defaultName(for: id)
    }

    /// "→ Server config · “Rotate the S3 key” · #backup", "Merge into “Docker”".
    func describe(_ proposal: KnowledgeFiling.TidyProposal) -> String {
        switch proposal.action {
        case .move(let project, let title, let tags):
            var parts: [String] = []
            if project != proposal.item.project { parts.append("→ \(projectName(project))") }
            if title != proposal.item.title { parts.append("“\(title)”") }
            if Set(tags) != Set(proposal.item.tags) {
                parts.append(tags.isEmpty ? "no tags" : tags.map { "#\($0)" }.joined(separator: " "))
            }
            return parts.joined(separator: " · ")
        case .merge(_, let title):
            return "Merge into “\(title)”"
        }
    }
}

/// Opens the palette over whatever is in front with a filing command's
/// proposal, and writes what is confirmed there.
@MainActor
struct KnowledgeReviewPresenter {
    let service: KnowledgeService
    let moduleID: ModuleID
    let palette: @MainActor () -> any PaletteHost
    let notifier: @MainActor (String, String) -> Void

    func present(_ content: KnowledgeReviewContent) {
        let palette = palette()
        // Over the app in front, like a snippet's fill-ins from expansion:
        // esc closes the palette and discards the proposal.
        if palette.isVisible { palette.close() }
        palette.open(moduleID)
        switch content {
        case .proposal(let proposal):
            palette.present(overlay(for: ProposalReview(proposal, projects: service.projects)))
        case .tidy(let proposals):
            palette.present(overlay(for: TidyReview(proposals, projects: service.projects)))
        }
    }

    func overlay(for review: ProposalReview) -> PaletteOverlay {
        PaletteOverlay(
            body: AnyView(ProposalReviewView(review: review)),
            activationHints: [PaletteHint(.primary, review.proposal.kind == .todo ? "Add" : "Save")],
            keys: [
                PaletteKey(.tab, hint: "Change project") {
                    review.changeProject(by: 1)
                    return true
                },
                PaletteKey(.shiftTab) {
                    review.changeProject(by: -1)
                    return true
                },
            ],
            activate: { [service, palette] _ in
                let proposal = review.proposal
                palette().close()
                Task {
                    do {
                        try await service.file(proposal)
                    } catch {
                        Beep.play()
                        Log.logger("knowledge").error("Filing failed: \(error, privacy: .public)")
                    }
                }
            },
            escape: .closePalette)
    }

    func overlay(for review: TidyReview) -> PaletteOverlay {
        PaletteOverlay(
            body: AnyView(TidyReviewView(review: review)),
            activationHints: [PaletteHint(.primary, "Apply")],
            keys: [
                PaletteKey(.tab, hint: "Skip or include") {
                    review.toggleSelected()
                    return true
                },
            ],
            activate: { [service, palette, notifier] _ in
                let included = review.included
                guard !included.isEmpty else {
                    Beep.play()
                    return
                }
                palette().close()
                Task {
                    let result = await service.applyTidy(included)
                    if result.failed > 0 {
                        notifier(
                            "Tidy the Inbox",
                            "\(result.applied) applied; \(result.failed) changed since \(result.failed == 1 ? "it was" : "they were") sent and stayed as \(result.failed == 1 ? "it was" : "they were").")
                    }
                }
            },
            escape: .closePalette,
            move: { step in
                guard case .vertical(let delta) = step else { return false }
                review.move(by: delta)
                return true
            })
    }
}
