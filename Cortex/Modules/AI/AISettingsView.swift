import SwiftUI
import CortexCore

/// The AI page below its options: what the actions used since the last
/// reset, by model, and an estimate of what it cost.
struct AISettingsView: View {
    let service: AIService
    @State private var confirmingReset = false

    var body: some View {
        let usage = service.usage
        Section {
            LabeledContent("Estimated cost") {
                Text(Self.dollars(usage.estimatedCost))
                    .font(.body.monospacedDigit())
            }
            LabeledContent("Requests", value: usage.requests.formatted())
            ForEach(usage.entries) { entry in
                LabeledContent {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(entry.unpricedRequests == entry.requests ? "No price known" : Self.dollars(entry.estimatedCost))
                            .font(.body.monospacedDigit())
                        Text("\(entry.requests.formatted()) requests · \(Self.tokens(entry.inputTokens)) in · \(Self.tokens(entry.outputTokens)) out")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    Text(entry.model)
                        .font(.body.monospaced())
                }
            }
            HStack {
                Text(usage.unpricedRequests > 0
                     ? "\(usage.unpricedRequests.formatted()) requests to models without a known price are counted in tokens only."
                     : "Estimated from list prices as of \(AIPricing.asOf); your bill is what counts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { confirmingReset = true }
                    .disabled(usage.requests == 0)
            }
        } header: {
            Text("Usage since \(usage.since.formatted(date: .abbreviated, time: .omitted))")
        }
        .confirmationDialog("Reset the usage totals?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive) { service.resetUsage() }
        } message: {
            Text("Counting starts again from zero. Nothing changes at \(service.settings.vendor.name).")
        }
    }

    /// Cents are too coarse for a few proofreads: small sums get four places.
    static func dollars(_ amount: Double) -> String {
        let places = amount > 0 && amount < 1 ? 4 : 2
        return amount.formatted(.currency(code: "USD").precision(.fractionLength(places)))
    }

    static func tokens(_ count: Int) -> String {
        "\(count.formatted(.number.notation(.compactName))) tokens"
    }
}
