import SwiftUI
import WebKit

/// A provider's storage page in a built-in browser: you sign in as usual (on
/// the provider's own page), Apex reads the "X of Y used" line. Each service
/// has its own browser data (WKWebsiteDataStore by identifier), so sign-ins
/// stay separate and are kept for the next refresh. Nothing is sent anywhere.
struct WebStorageSheet: View {
    let title: String
    let page: String
    let storeID: UUID
    var onSave: (CloudQuota) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var found: CloudQuota?
    @State private var address = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "lock.fill").foregroundStyle(.green)
                Text(address.isEmpty ? page : address).font(.callout).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            WebPage(url: page, storeID: storeID, address: $address) { text in
                if let q = CloudCatalog.parseUsage(text) { found = q }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 10) {
                if let q = found, let total = q.total {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Found: \(Fmt.diskBytes(q.used)) of \(Fmt.diskBytes(total)) used")
                } else {
                    ProgressView().controlSize(.small)
                    Text("Sign in to \(title) here. Apex reads the storage line once the page shows it.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Use This") { if let found { onSave(found); dismiss() } }
                    .keyboardShortcut(.defaultAction).disabled(found?.total == nil)
            }
            .font(.callout)
        }
        .padding(14)
        .frame(width: 900, height: 680)
    }
}

/// WKWebView that reports its page text every 2 seconds.
private struct WebPage: NSViewRepresentable {
    let url: String
    let storeID: UUID
    @Binding var address: String
    var onText: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = WKWebsiteDataStore(forIdentifier: storeID)
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.navigationDelegate = context.coordinator
        if let u = URL(string: url) { v.load(URLRequest(url: u)) }
        context.coordinator.start(v)
        return v
    }

    func updateNSView(_ v: WKWebView, context: Context) {}

    static func dismantleNSView(_ v: WKWebView, coordinator: Coordinator) { coordinator.timer?.invalidate() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: WebPage
        var timer: Timer?
        init(_ p: WebPage) { parent = p }

        func start(_ v: WKWebView) {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak v, weak self] _ in
                v?.evaluateJavaScript("document.body ? document.body.innerText : ''") { r, _ in
                    if let t = r as? String { self?.parent.onText(t) }
                }
            }
        }

        func webView(_ v: WKWebView, didFinish navigation: WKNavigation!) {
            parent.address = v.url?.host ?? ""
        }
    }
}

/// Re-reads a storage page in the background with the saved sign-in.
@MainActor
final class WebQuotaReader: NSObject, WKNavigationDelegate {
    private var view: WKWebView?
    private var done: ((CloudQuota?) -> Void)?

    static func read(page: String, storeID: UUID) async -> CloudQuota? {
        let r = WebQuotaReader()
        return await withCheckedContinuation { c in r.load(page, storeID) { c.resume(returning: $0) } }
    }

    private func load(_ page: String, _ storeID: UUID, _ done: @escaping (CloudQuota?) -> Void) {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = WKWebsiteDataStore(forIdentifier: storeID)
        let v = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900), configuration: cfg)
        view = v
        self.done = done
        guard let u = URL(string: page) else { finish(nil); return }
        v.load(URLRequest(url: u))
        // Pages fill in their numbers after loading: look a few times, then give up.
        Task {
            for _ in 0..<10 {
                try? await Task.sleep(for: .seconds(2))
                guard self.done != nil else { return }
                let text = (try? await v.evaluateJavaScript("document.body ? document.body.innerText : ''")) as? String ?? ""
                if let q = CloudCatalog.parseUsage(text) { finish(q); return }
            }
            finish(nil)
        }
    }

    private func finish(_ q: CloudQuota?) {
        done?(q); done = nil
        view = nil
    }
}
