import Foundation

/// Claude API list prices (USD per million tokens), from https://platform.claude.com/docs/en/about-claude/pricing
/// as of `Pricing.asOf`. Used to show what usage would cost at pay-as-you-go API rates; a Claude subscription
/// is not billed this way. Bump `version` when prices change so cached usage is re-priced.
enum Pricing {
    static let version = 1
    static let asOf = "25 Nov 2026"
    static let source = URL(string: "https://platform.claude.com/docs/en/about-claude/pricing")!

    struct Rates {
        let input: Double          // base input
        let output: Double
        let cacheReadMultiplier: Double   // × input (0.1 on most models; lower on newer ones)
        var fastInput: Double? = nil      // fast mode base prices, where offered
        var fastOutput: Double? = nil
        /// Claude Haiku 5.5 charges more when the whole prompt (input + cache reads + writes) is over 100K tokens.
        var longPrompt: (threshold: Int, input: Double, output: Double)? = nil
        /// `inference_geo: "us"` costs 1.1× on Claude 4.6 and later.
        var supportsGeoMultiplier = true

        func cacheWrite5m(_ base: Double) -> Double { base * 1.25 }
        func cacheWrite1h(_ base: Double) -> Double { base * 2 }
    }

    /// Longest matching prefix wins, so dated IDs (e.g. claude-opus-4-5-20251101) resolve too.
    private static let table: [(prefix: String, name: String, rates: Rates)] = [
        ("claude-fable-5-2", "Fable 5.2", Rates(input: 8, output: 40, cacheReadMultiplier: 0.025, fastInput: 16, fastOutput: 80)),
        ("claude-mythos-5-2", "Mythos 5.2", Rates(input: 8, output: 40, cacheReadMultiplier: 0.025, fastInput: 16, fastOutput: 80)),
        ("claude-fable-5-1", "Fable 5.1", Rates(input: 10, output: 50, cacheReadMultiplier: 0.025)),
        ("claude-mythos-5-1", "Mythos 5.1", Rates(input: 10, output: 50, cacheReadMultiplier: 0.025)),
        ("claude-fable-5", "Fable 5", Rates(input: 10, output: 50, cacheReadMultiplier: 0.1)),
        ("claude-mythos-5", "Mythos 5", Rates(input: 10, output: 50, cacheReadMultiplier: 0.1)),
        ("claude-opus-5-5", "Opus 5.5", Rates(input: 4, output: 20, cacheReadMultiplier: 0.05, fastInput: 8, fastOutput: 40)),
        ("claude-opus-5", "Opus 5", Rates(input: 5, output: 25, cacheReadMultiplier: 0.1, fastInput: 10, fastOutput: 50)),
        ("claude-opus-4-8", "Opus 4.8", Rates(input: 5, output: 25, cacheReadMultiplier: 0.1, fastInput: 10, fastOutput: 50)),
        ("claude-opus-4-7", "Opus 4.7", Rates(input: 5, output: 25, cacheReadMultiplier: 0.1)),
        ("claude-opus-4-6", "Opus 4.6", Rates(input: 5, output: 25, cacheReadMultiplier: 0.1)),
        ("claude-opus-4-5", "Opus 4.5", Rates(input: 5, output: 25, cacheReadMultiplier: 0.1, supportsGeoMultiplier: false)),
        ("claude-opus-4-1", "Opus 4.1", Rates(input: 15, output: 75, cacheReadMultiplier: 0.1, supportsGeoMultiplier: false)),
        ("claude-opus-4", "Opus 4", Rates(input: 15, output: 75, cacheReadMultiplier: 0.1, supportsGeoMultiplier: false)),
        ("claude-sonnet-5-5", "Sonnet 5.5", Rates(input: 2, output: 10, cacheReadMultiplier: 0.05)),
        ("claude-sonnet-5", "Sonnet 5", Rates(input: 2, output: 10, cacheReadMultiplier: 0.1)),
        ("claude-sonnet-4-6", "Sonnet 4.6", Rates(input: 3, output: 15, cacheReadMultiplier: 0.1)),
        ("claude-sonnet-4-5", "Sonnet 4.5", Rates(input: 3, output: 15, cacheReadMultiplier: 0.1, supportsGeoMultiplier: false)),
        ("claude-sonnet-4", "Sonnet 4", Rates(input: 3, output: 15, cacheReadMultiplier: 0.1, supportsGeoMultiplier: false)),
        ("claude-haiku-5-5", "Haiku 5.5", Rates(input: 0.10, output: 0.50, cacheReadMultiplier: 0.1,
                                                longPrompt: (100_000, 0.50, 2.50))),
        ("claude-haiku-4-5", "Haiku 4.5", Rates(input: 1, output: 5, cacheReadMultiplier: 0.1, supportsGeoMultiplier: false)),
    ].sorted { $0.prefix.count > $1.prefix.count }

    static let webSearchPerRequest = 10.0 / 1000

    /// Short display name for a model id ("claude-opus-5-5" → "Opus 5.5"); unknown ids are shown as-is.
    static func displayName(_ model: String) -> String {
        table.first { model.hasPrefix($0.prefix) }?.name ?? model
    }

    struct Usage {
        var input = 0, cacheWrite5m = 0, cacheWrite1h = 0, cacheRead = 0, output = 0, webSearches = 0
        var fast = false
        var usOnly = false
    }

    /// Cost of one reply split by what it paid for (USD).
    struct Cost {
        var input = 0.0, cacheWrite = 0.0, cacheRead = 0.0, output = 0.0, webSearch = 0.0
        var total: Double { input + cacheWrite + cacheRead + output + webSearch }
    }

    /// USD cost of one reply at API list prices; nil when the model isn't in the table.
    static func cost(model: String, _ u: Usage) -> Cost? {
        guard let r = table.first(where: { model.hasPrefix($0.prefix) })?.rates else { return nil }
        var inRate = r.input, outRate = r.output
        if u.fast, let fi = r.fastInput, let fo = r.fastOutput { inRate = fi; outRate = fo }
        if let lp = r.longPrompt, u.input + u.cacheRead + u.cacheWrite5m + u.cacheWrite1h > lp.threshold {
            inRate = lp.input; outRate = lp.output
        }
        let geo = (u.usOnly && r.supportsGeoMultiplier) ? 1.1 : 1.0
        var c = Cost()
        c.input = Double(u.input) * inRate / 1_000_000 * geo
        c.cacheWrite = (Double(u.cacheWrite5m) * r.cacheWrite5m(inRate) + Double(u.cacheWrite1h) * r.cacheWrite1h(inRate)) / 1_000_000 * geo
        c.cacheRead = Double(u.cacheRead) * inRate * r.cacheReadMultiplier / 1_000_000 * geo
        c.output = Double(u.output) * outRate / 1_000_000 * geo
        c.webSearch = Double(u.webSearches) * webSearchPerRequest
        return c
    }

    static func usd(_ v: Double) -> String {
        switch v {
        case 0: return "$0"
        case ..<0.01: return "<$0.01"
        case ..<100: return String(format: "$%.2f", v)
        case ..<10_000: return String(format: "$%.0f", v)
        default:
            let f = NumberFormatter(); f.numberStyle = .currency; f.currencyCode = "USD"; f.maximumFractionDigits = 0
            return f.string(from: NSNumber(value: v)) ?? String(format: "$%.0f", v)
        }
    }
}
