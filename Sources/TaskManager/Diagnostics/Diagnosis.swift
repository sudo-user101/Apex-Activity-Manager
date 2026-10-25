import Foundation

// A reusable shape for "what's wrong and what to do about it", shared by every
// doctor (drives first; memory, GPU, energy and network can use the same model).
// Doctors are pure: measurements in, findings out. They never act on their own;
// a finding only *offers* safe actions, and the user runs them.

/// Where a piece of evidence came from, so measured facts are never confused
/// with guesses (or, later, with AI-written explanations).
enum EvidenceSource: String, Codable, Sendable {
    case device      // reported by the hardware itself (e.g. the SSD's health log)
    case measured    // measured by Apex while it was running
    case macOS       // reported by macOS (e.g. First Aid)
    case inferred    // worked out by a rule from the above
}

struct Evidence: Hashable, Sendable {
    var label: String
    var value: String
    var source: EvidenceSource
}

enum FindingSeverity: Int, Comparable, Sendable {
    case ok, info, notice, warning, critical
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    var title: String {
        switch self {
        case .ok: return "Fine"
        case .info: return "Good to know"
        case .notice: return "Worth checking"
        case .warning: return "Warning"
        case .critical: return "Act now"
        }
    }
}

/// How sure the rule is: a confirmed fact, or one possible explanation.
enum FindingConfidence: String, Sendable {
    case confirmed, likely, possible
    var title: String {
        switch self {
        case .confirmed: return "Confirmed"
        case .likely: return "Likely"
        case .possible: return "Possible cause"
        }
    }
}

struct DiagnosticStep: Hashable, Sendable {
    var title: String
    var expected: String = ""     // what should happen if this fixes it
    var risk: String = ""         // prerequisites or risks; empty = none
}

/// Things the user can do from a finding. Each maps to a real action in the UI;
/// none of them changes data without the user confirming in that app.
enum SafeAction: Hashable, Sendable {
    case checkForErrors           // read-only First Aid (diskutil verifyVolume)
    case openDiskUtility
    case openTimeMachine
    case openStorageSettings
    case freeUpSpace              // Apex's Storage hub (review before anything is deleted)
    // Network
    case restartWiFi              // Wi-Fi off and on again (no admin)
    case openNetworkSettings
    case openWiFiSettings
    case openLoginPage            // the network's sign-in page (captive portal)
    case testSpeed                // run the Network Doctor's checks again

    var title: String {
        switch self {
        case .checkForErrors: return "Check for Errors"
        case .openDiskUtility: return "Open Disk Utility"
        case .openTimeMachine: return "Time Machine Settings"
        case .openStorageSettings: return "Storage Settings"
        case .freeUpSpace: return "Free Up Space…"
        case .restartWiFi: return "Turn Wi-Fi Off and On"
        case .openNetworkSettings: return "Network Settings"
        case .openWiFiSettings: return "Wi-Fi Settings"
        case .openLoginPage: return "Open the Sign-In Page"
        case .testSpeed: return "Check Again"
        }
    }
}

struct Finding: Identifiable, Hashable, Sendable {
    var id: String                // stable per rule, e.g. "smart.spare"
    var title: String             // what was detected
    var why: String               // why it matters
    var severity: FindingSeverity
    var confidence: FindingConfidence
    var evidence: [Evidence] = []
    var causes: [String] = []     // possible root causes, most likely first
    var steps: [DiagnosticStep] = []
    var actions: [SafeAction] = []
    var followUp: String = ""     // how to tell whether it's resolved
    var escalate: String = ""     // when to get help or replace the hardware
}

/// What a doctor returns.
struct DiagnosisReport: Sendable {
    var subject: String
    var findings: [Finding]       // sorted, most severe first
    var missing: [String] = []    // data that would make the diagnosis better
    var worst: FindingSeverity { findings.map(\.severity).max() ?? .ok }
    var problems: [Finding] { findings.filter { $0.severity >= .notice } }

    init(subject: String, findings: [Finding], missing: [String] = []) {
        self.subject = subject
        self.findings = findings.sorted { $0.severity > $1.severity }
        self.missing = missing
    }
}
