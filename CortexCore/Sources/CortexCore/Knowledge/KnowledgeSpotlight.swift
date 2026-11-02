import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// Notes and to-dos in the iPhone's Spotlight (plans/IOS.md, M5): what an
/// item looks like there, and which items to index again. The index is on
/// the device only; a result opens the item through its deep link.
public enum KnowledgeSpotlight {
    /// Skills and READMEs stay out: they are for agents and the project list.
    public static let kinds: Set<KnowledgeKind> = [.note, .todo]

    public static let descriptionLength = 200

    /// The item's searchable attributes. The unique identifier is its path.
    public static func attributes(for item: KnowledgeItem, projectName: String) -> CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = item.title
        let body = MarkdownBlock.plainText(MarkdownBlock.parse(item.bodyWithoutTitle))
        var description = [projectName]
        if item.kind == .todo {
            if item.status == .done {
                description.append("Done")
            } else if let due = item.due {
                description.append("Due \(due)")
            }
        }
        let text = item.summary ?? body
        attributes.contentDescription = description.joined(separator: " · ")
            + (text.isEmpty ? "" : "\n" + String(text.prefix(descriptionLength)))
        attributes.textContent = body
        attributes.keywords = item.tags + [projectName]
        attributes.contentCreationDate = item.created
        attributes.contentModificationDate = item.updated
        return attributes
    }

    public static func searchableItem(for item: KnowledgeItem, projectName: String) -> CSSearchableItem {
        CSSearchableItem(
            uniqueIdentifier: item.path, domainIdentifier: item.project,
            attributeSet: attributes(for: item, projectName: projectName))
    }

    /// From the modification dates indexed last time and the ones now:
    /// the paths to index (new or changed) and the ones to remove.
    public static func changes(indexed: [String: Date], current: [String: Date]) -> (update: [String], remove: [String]) {
        let update = current.filter { indexed[$0.key] != $0.value }.keys.sorted()
        let remove = indexed.keys.filter { current[$0] == nil }.sorted()
        return (update, remove)
    }
}
