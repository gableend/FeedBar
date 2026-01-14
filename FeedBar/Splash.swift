import Foundation
import SwiftUI
import CryptoKit
import Combine

// MARK: - ADVANCED CONTENT PROVIDER
struct SplashContentProvider {
    // ... (Keep existing Content Provider code exactly as is) ...
    // To save scrolling, I will assume the struct SplashContentProvider
    // remains identical to the previous version.
    
    enum MessageType: CaseIterable {
        case futureSignal
        case systemTruth
        case reframedDefinition
        case modeShift
        case temporalPerspective
    }

    static let weights: [(MessageType, Int)] = [
        (.futureSignal, 58),
        (.systemTruth, 18),
        (.reframedDefinition, 10),
        (.modeShift, 10),
        (.temporalPerspective, 4)
    ]

    private static let defaultsKey = "feedsbar.splash.seenHashes.v2"
    private static let maxSeen = 3000
    private static let maxAttempts = 40

    static func randomThought() -> String {
        var seen = loadSeen()
        if seen.count > maxSeen {
            seen = Array(seen.suffix(maxSeen / 2))
            saveSeen(seen)
        }
        for _ in 0..<maxAttempts {
            let type = weightedPick()
            let candidate = generate(type: type).trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValid(candidate) else { continue }
            let h = stableHash(candidate)
            if !seen.contains(h) {
                seen.append(h)
                saveSeen(seen)
                return candidate
            }
        }
        return "Zoom out. Patterns emerge."
    }

    // ... (Keep generation logic intact) ...
    private static func generate(type: MessageType) -> String {
        switch type {
        case .futureSignal: return render(template: futureSignalTemplates.randomElement()!, slots: futureSignalSlots)
        case .systemTruth: return render(template: systemTruthTemplates.randomElement()!, slots: systemTruthSlots)
        case .reframedDefinition: return render(template: definitionTemplates.randomElement()!, slots: definitionSlots)
        case .modeShift: return render(template: modeShiftTemplates.randomElement()!, slots: modeShiftSlots)
        case .temporalPerspective: return render(template: temporalTemplates.randomElement()!, slots: temporalSlots)
        }
    }
    
    // ... (Templates and Slots remain the same) ...
    private static let futureSignalTemplates: [String] = ["The signal is {state}.", "Most {events} happen before {place}.", "{speed} beats {virtue}.", "What you notice {time} shapes what matters {later}.", "The future arrives {arrival}."]
    private static let systemTruthTemplates: [String] = ["News is a {indicator}.", "Attention is the {resource}.", "Every feed is an {stance}.", "Algorithms {do} the future. They {do2} it.", "{systems} move faster than {institutions}."]
    private static let definitionTemplates: [String] = ["Signal: {signalDef}.", "Noise: {noiseDef}.", "Insight: {insightDef}.", "Context: {contextDef}.", "Trend: {trendDef}."]
    private static let modeShiftTemplates: [String] = ["{imperative}. {result}.", "{imperative}.", "{imperative}. {result}. {tagline}."]
    private static let temporalTemplates: [String] = ["Today’s headlines explain {when}.", "Signals appear before {thing}.", "Trends are obvious in {view}.", "Most change happens {where}.", "{fast} moves faster than {slow}."]

    private static let futureSignalSlots: [String: [String]] = ["state": ["already here", "easy to miss", "forming quietly", "weak but growing", "rare but real"], "events": ["decisions", "shifts", "failures", "breakthroughs", "reversals"], "place": ["the headline", "the dashboard", "the meeting", "the memo", "the story"], "speed": ["Speed", "Clarity", "Focus", "Momentum", "Execution"], "virtue": ["certainty", "consensus", "perfection", "comfort", "permission"], "time": ["today", "this week", "right now", "in plain sight", "by accident"], "later": ["tomorrow", "next quarter", "soon", "at scale", "when it counts"], "arrival": ["quietly", "in fragments", "without permission", "before consensus", "on the edges"]]
    private static let systemTruthSlots: [String: [String]] = ["indicator": ["lagging indicator", "mirror", "afterimage", "receipt", "trace"], "resource": ["scarce resource", "currency", "bottleneck", "battlefield", "cost center"], "stance": ["opinion", "filter", "bias", "lens", "edit"], "do": ["don’t predict", "rarely predict", "can’t predict", "won’t predict", "don’t explain"], "do2": ["reinforce", "shape", "compress", "amplify", "refine"], "systems": ["Information", "Markets", "Narratives", "Code", "Incentives"], "institutions": ["institutions", "teams", "processes", "policies", "assumptions"]]
    private static let definitionSlots: [String: [String]] = ["signalDef": ["information that changes a decision", "what remains after you remove the noise", "a small fact with large consequences"], "noiseDef": ["data without consequence", "volume that feels important", "information that can’t guide action"], "insightDef": ["compression, not volume", "a pattern you can act on", "clarity under uncertainty"], "contextDef": ["the missing half of information", "why the same fact means different things", "the frame that makes data useful"], "trendDef": ["a pattern noticed too late", "signal that went mainstream", "momentum you can measure"]]
    private static let modeShiftSlots: [String: [String]] = ["imperative": ["Zoom out", "Slow the scroll", "Notice what repeats", "Read between updates", "Ignore the spectacle", "Watch what doesn’t move", "Pay attention to timing", "Look for what’s missing", "Treat headlines as symptoms", "Separate signal from reaction", "Read for patterns, not drama", "Hold the frame steady"], "result": ["Patterns emerge", "The noise fades", "The shape becomes clear", "The story shifts", "The signal stands out", "The picture sharpens", "Context locks in"], "tagline": ["Signal over noise", "Context matters", "Less volume. More meaning", "Read deliberately"]]
    private static let temporalSlots: [String: [String]] = ["when": ["yesterday", "last week", "what already happened", "the decision already made", "the moment that passed"], "thing": ["the narrative", "the explanation", "the headline", "the justification", "the announcement"], "view": ["retrospect", "the rear-view mirror", "charts", "post-mortems"], "where": ["between updates", "off-schedule", "outside the spotlight", "before anyone notices", "in plain sight"], "fast": ["Information", "Markets", "Narratives", "Technology"], "slow": ["institutions", "process", "policy", "coordination"]]

    private static func render(template: String, slots: [String: [String]]) -> String {
        var out = template
        let tokenRegex = #"\{([a-zA-Z0-9_]+)\}"#
        while let range = out.range(of: tokenRegex, options: .regularExpression) {
            let token = String(out[range])
            let key = token.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
            if let choices = slots[key], let pick = choices.randomElement() { out.replaceSubrange(range, with: pick) }
            else { out.replaceSubrange(range, with: "") }
        }
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func weightedPick() -> MessageType {
        let total = weights.reduce(0) { $0 + $1.1 }
        let r = Int.random(in: 1...max(total, 1))
        var running = 0
        for (t, w) in weights { running += w; if r <= running { return t } }
        return .futureSignal
    }
    private static func isValid(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 90 else { return false }
        let banned = ["—", "WORD OF THE DAY", "Scanning", "Calibrating", "Indexing", "Loading..."]
        if banned.contains(where: { s.localizedCaseInsensitiveContains($0) }) { return false }
        if s.contains("  ") || s.hasSuffix("..") || s.hasPrefix(".") { return false }
        return true
    }
    private static func stableHash(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    private static func loadSeen() -> [String] { UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [] }
    private static func saveSeen(_ seen: [String]) { UserDefaults.standard.set(seen, forKey: defaultsKey) }
}

// MARK: - SPLASH VIEW (ANIMATED & SIZED)
struct LoadingSplashView: View {
    // Add size parameter
    let size: Int
    
    @State private var thought: String = ""
    @State private var opacity = 0.4
    
    // Timer to rotate content every 3 seconds
    let timer = Timer.publish(every: 3.0, on: .main, in: .common).autoconnect()
    
    var body: some View {
        ZStack {
            FeedsTheme.background.ignoresSafeArea()
            
            HStack(spacing: spacing) {
                // Pulsing Orb
                Circle()
                    .fill(FeedsTheme.ai)
                    .frame(width: orbSize, height: orbSize)
                    .opacity(opacity)
                    .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: opacity)
                
                // Rotating Text
                Text(thought)
                    .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                    .foregroundColor(FeedsTheme.secondaryText)
                    .lineLimit(1)
                    .animation(.easeInOut(duration: 0.5), value: thought)
            }
        }
        .onAppear {
            thought = SplashContentProvider.randomThought()
            opacity = 1.0
        }
        .onReceive(timer) { _ in
            withAnimation(.easeInOut(duration: 0.5)) {
                thought = SplashContentProvider.randomThought()
            }
        }
    }
    
    // Dynamic Sizing logic based on Ticker Size (1=Compact, 2=Standard, 4=Large)
    private var orbSize: CGFloat { size == 1 ? 8 : (size == 4 ? 18 : 12) }
    private var fontSize: CGFloat { size == 1 ? 12 : (size == 4 ? 24 : 15) }
    private var spacing: CGFloat { size == 1 ? 12 : (size == 4 ? 24 : 20) }
}
