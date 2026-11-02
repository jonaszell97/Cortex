import Foundation
import CortexCore

/// Which vendor the AI actions use and which of its models, stored per
/// vendor ("ai.openai.textModel"), so switching vendors never sends one
/// vendor's model name to another.
@MainActor
@Observable
final class AISettings {
    @ObservationIgnored private let defaults: ModuleDefaults

    var vendor: AIVendorID {
        didSet {
            defaults.set(vendor.rawValue, for: "vendor")
            load()
        }
    }

    /// Empty: the vendor's default model.
    var textModel = "" { didSet { defaults.set(textModel, for: .named("\(vendor.rawValue).textModel")) } }
    /// Empty: the vendor's default model.
    var imageModel = "" { didSet { defaults.set(imageModel, for: .named("\(vendor.rawValue).imageModel")) } }

    init(defaults: ModuleDefaults) {
        self.defaults = defaults
        vendor = defaults.string("vendor").flatMap(AIVendorID.init(rawValue:)) ?? .openAI
        load()
    }

    private func load() {
        textModel = defaults.string(.named("\(vendor.rawValue).textModel")) ?? ""
        imageModel = defaults.string(.named("\(vendor.rawValue).imageModel")) ?? ""
    }

    /// The model the text actions ask.
    var effectiveTextModel: String { Self.model(textModel, default: vendor.defaultTextModel) }
    /// The model "Generate Image" asks.
    var effectiveImageModel: String { Self.model(imageModel, default: vendor.defaultImageModel) }

    private static func model(_ typed: String, default fallback: String) -> String {
        let model = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? fallback : model
    }
}
