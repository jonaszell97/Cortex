import SwiftUI
import CortexCore

/// What `$note` or `$todo` will write: kind, title, project (⇥ changes it),
/// path, tags, due day or description, and the Markdown.
struct ProposalReviewView: View {
    let review: ProposalReview

    var body: some View {
        let proposal = review.proposal
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Label(heading(proposal), systemImage: symbol(proposal))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(proposal.title)
                    .font(.title3.bold())
                    .lineLimit(2)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Project").foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            TintedTag(project: review.project)
                            Text("⇥").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    GridRow {
                        Text("File").foregroundStyle(.secondary)
                        Text(review.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    }
                    if !proposal.tags.isEmpty {
                        GridRow {
                            Text("Tags").foregroundStyle(.secondary)
                            Text(proposal.tags.map { "#\($0)" }.joined(separator: " "))
                        }
                    }
                    if let due = proposal.due {
                        GridRow {
                            Text("Due").foregroundStyle(.secondary)
                            Text(due)
                        }
                    }
                    if let description = proposal.description {
                        GridRow {
                            Text("Description").foregroundStyle(.secondary)
                            Text(description).lineLimit(2)
                        }
                    }
                }
                .font(.callout)
            }
            .padding(16)
            Divider()
            if proposal.fullBody.isEmpty {
                Text("No body")
                    .foregroundStyle(.tertiary)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                TextPreview(text: proposal.fullBody)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private func heading(_ proposal: KnowledgeFiling.Proposal) -> String {
        switch proposal.kind {
        case .skill: "New skill"
        case .todo: "New to-do"
        default: "New note"
        }
    }

    private func symbol(_ proposal: KnowledgeFiling.Proposal) -> String {
        switch proposal.kind {
        case .skill: "wand.and.sparkles"
        case .todo: "circle"
        default: "doc.text"
        }
    }
}

/// `$tidy`'s proposals, one row each: ticked ones are applied, ⇥ skips the
/// selected one.
struct TidyReviewView: View {
    let review: TidyReview

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(headline)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(review.proposals.enumerated()), id: \.element.id) { index, proposal in
                            PaletteRow(
                                symbol: review.isIncluded(proposal) ? "checkmark.circle.fill" : "circle",
                                title: proposal.item.title,
                                subtitle: subtitle(proposal),
                                badge: badge(proposal),
                                shortcutNumber: nil,
                                isSelected: index == review.selection)
                            .opacity(review.isIncluded(proposal) ? 1 : 0.5)
                            .id(proposal.id)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: review.selection) { _, selection in
                    guard review.proposals.indices.contains(selection) else { return }
                    proxy.scrollTo(review.proposals[selection].id)
                }
            }
        }
    }

    private var headline: String {
        let count = review.proposals.count
        let included = review.included.count
        let what = count == 1 ? "1 proposal" : "\(count) proposals"
        return included == count ? "\(what) for the inbox. ⏎ applies all; ⇥ skips the selected one."
            : "\(what) for the inbox, \(included) to apply. ⇥ skips or takes back the selected one."
    }

    private func subtitle(_ proposal: KnowledgeFiling.TidyProposal) -> String {
        let change = review.describe(proposal)
        return proposal.reason.isEmpty ? change : "\(change) — \(proposal.reason)"
    }

    private func badge(_ proposal: KnowledgeFiling.TidyProposal) -> String {
        switch proposal.action {
        case .move(let project, _, _): review.projectName(project)
        case .merge: "Merge"
        }
    }
}
