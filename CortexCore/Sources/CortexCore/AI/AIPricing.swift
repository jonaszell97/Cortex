import Foundation

/// A model's list price in US dollars per million tokens.
public struct AIPrice: Sendable, Equatable {
    public var input: Double
    public var cachedInput: Double
    public var output: Double

    public init(input: Double, cachedInput: Double, output: Double) {
        self.input = input
        self.cachedInput = cachedInput
        self.output = output
    }

    /// What `usage` costs at this price.
    public func cost(of usage: AIUsage) -> Double {
        let cached = min(usage.cachedInputTokens, usage.inputTokens)
        let uncached = usage.inputTokens - cached
        return (Double(uncached) * input + Double(cached) * cachedInput + Double(usage.outputTokens) * output) / 1_000_000
    }
}

/// The vendors' list prices, for estimates only: the vendor's bill is what
/// counts. A model without a price here is counted in tokens but not in
/// dollars.
public enum AIPricing {
    /// When the prices below were looked up.
    public static let asOf = "October 2026"

    /// By vendor, then model ID.
    static let prices: [AIVendorID: [String: AIPrice]] = [
        .openAI: [
            "gpt-6-luna": AIPrice(input: 0.10, cachedInput: 0.01, output: 0.50),
            // Text prompt in, image tokens out.
            "gpt-image-2.5-flare": AIPrice(input: 5.00, cachedInput: 1.25, output: 30.00),
        ],
    ]

    /// The price of `model`, also for a dated snapshot of it
    /// ("gpt-image-2.5-flare-2026-09-08").
    public static func price(of model: String, vendor: AIVendorID) -> AIPrice? {
        guard let table = prices[vendor] else { return nil }
        let model = model.lowercased()
        if let price = table[model] { return price }
        return table.first { name, _ in
            model.hasPrefix(name + "-") && model.dropFirst(name.count + 1).first?.isNumber == true
        }?.value
    }

    /// nil when the model has no known price.
    public static func cost(of usage: AIUsage) -> Double? {
        price(of: usage.model, vendor: usage.vendor)?.cost(of: usage)
    }
}

/// Everything the AI actions used since `since`, by vendor and model.
public struct AIUsageTotals: Sendable, Equatable, Codable {
    public struct Entry: Sendable, Equatable, Codable, Identifiable {
        public var vendor: AIVendorID
        public var model: String
        public var requests = 0
        public var inputTokens = 0
        public var cachedInputTokens = 0
        public var outputTokens = 0
        /// The estimate for the priced requests, at the prices of the day.
        public var estimatedCost: Double = 0
        /// Requests to a model without a known price, not in `estimatedCost`.
        public var unpricedRequests = 0

        public var id: String { "\(vendor.rawValue)/\(model)" }

        public init(vendor: AIVendorID, model: String) {
            self.vendor = vendor
            self.model = model
        }
    }

    public var since: Date
    /// In the order the models were first used.
    public private(set) var entries: [Entry] = []

    public init(since: Date = .now) {
        self.since = since
    }

    /// Adds one request, priced at today's prices.
    public mutating func add(_ usage: AIUsage) {
        let index = entries.firstIndex { $0.vendor == usage.vendor && $0.model == usage.model }
        var entry = index.map { entries[$0] } ?? Entry(vendor: usage.vendor, model: usage.model)
        entry.requests += 1
        entry.inputTokens += usage.inputTokens
        entry.cachedInputTokens += usage.cachedInputTokens
        entry.outputTokens += usage.outputTokens
        if let cost = AIPricing.cost(of: usage) {
            entry.estimatedCost += cost
        } else {
            entry.unpricedRequests += 1
        }
        if let index {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }

    public var requests: Int { entries.reduce(0) { $0 + $1.requests } }
    public var estimatedCost: Double { entries.reduce(0) { $0 + $1.estimatedCost } }
    public var unpricedRequests: Int { entries.reduce(0) { $0 + $1.unpricedRequests } }
}
