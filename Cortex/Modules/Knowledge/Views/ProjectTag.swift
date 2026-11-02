import SwiftUI
import CortexCore

/// Shared with the iOS app (project.yml), so SwiftUI only.
extension ProjectColor {
    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .cyan: .cyan
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .brown: .brown
        case .gray: .gray
        }
    }

    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

extension KnowledgeProject {
    var tintColor: Color { tint.color }
}

extension TintedTag {
    /// A project's label: its symbol and name in its colour.
    init(project: KnowledgeProject, showsSymbol: Bool = true, isSelected: Bool = false) {
        self.init(
            title: project.name, symbol: showsSymbol ? project.displaySymbol : nil, tint: project.tintColor,
            isSelected: isSelected)
    }
}
