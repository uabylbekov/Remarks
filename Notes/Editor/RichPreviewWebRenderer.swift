import SwiftUI
import WebKit

/// Owns the WebKit process and navigation lifecycle. Scheduling and cache policy belong to RichPreviewRenderer.
@MainActor
final class RichPreviewWebRenderer: NSObject, WKNavigationDelegate {
    enum Failure: Error {
        case invalidSource
        case invalidSize
        case unavailable

        var isPermanent: Bool {
            switch self {
            case .invalidSource, .invalidSize: true
            case .unavailable: false
            }
        }
    }

    private var webView: WKWebView?
    private var ready = false
    private var waiters: [UUID: CheckedContinuation<WKWebView, Error>] = [:]
    private var timeout: Task<Void, Never>?

    func prepare() async throws -> WKWebView {
        try Task.checkCancellation()
        if ready, let webView { return webView }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = continuation
                if webView == nil { startLoading() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
    }

    func reset() {
        timeout?.cancel()
        timeout = nil
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
        ready = false
        finishWaiters(with: .failure(Failure.unavailable))
    }

    private func startLoading() {
        guard let url = Bundle.main.url(forResource: "renderer", withExtension: "html")
                ?? Bundle.main.url(forResource: "renderer", withExtension: "html", subdirectory: "RenderingResources")
        else {
            finishWaiters(with: .failure(Failure.unavailable))
            return
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 2048), configuration: configuration)
        #if canImport(UIKit)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        #else
        view.setValue(false, forKey: "drawsBackground")
        #endif
        webView = view
        view.navigationDelegate = self
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        timeout = Task { [weak self, weak view] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, let view, self.webView === view, !self.ready else { return }
            self.reset()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { [weak self, weak webView] in
            guard let self, let webView else { return }
            let available = (try? await webView.evaluateJavaScript("typeof window.renderPreview === 'function' && typeof window.katex?.render === 'function' && typeof window.mermaid?.render === 'function'")) as? Bool == true
            guard self.webView === webView else { return }
            if available {
                self.ready = true
                self.timeout?.cancel()
                self.timeout = nil
                self.finishWaiters(with: .success(webView))
            } else {
                self.reset()
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if self.webView === webView { reset() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if self.webView === webView { reset() }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if self.webView === webView { reset() }
    }

    private func finishWaiters(with result: Result<WKWebView, Error>) {
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending { waiter.resume(with: result) }
    }

    func render(_ key: RichPreviewRenderer.Key) async throws -> RichPreviewRenderer.Preview {
        let view = try await prepare()
        do {
            view.frame = CGRect(x: 0, y: 0, width: key.width, height: 2048)
            let result = try await view.callAsyncJavaScript(
                """
                let timeoutID;
                try {
                    return await Promise.race([
                        window.renderPreview(source, kind, width, fontSize, dark),
                        new Promise((_, reject) => { timeoutID = setTimeout(() => reject(Error("Preview timed out")), 5000); })
                    ]);
                } catch (error) {
                    return {error: error.message === "Preview timed out" ? "timeout" : "source"};
                } finally {
                    clearTimeout(timeoutID);
                }
                """,
                arguments: ["source": key.source, "kind": key.kind, "width": key.width,
                            "fontSize": key.fontSize, "dark": key.dark],
                in: nil, contentWorld: .page)
            try Task.checkCancellation()
            guard let metrics = result as? [String: Any] else { throw Failure.unavailable }
            if let error = metrics["error"] as? String {
                throw error == "source" ? Failure.invalidSource : Failure.unavailable
            }
            guard let width = metrics["width"] as? Double, let height = metrics["height"] as? Double,
                  width.isFinite, height.isFinite, width > 0, height > 0,
                  width <= Double(key.width), height <= 4000, width * height <= 2_000_000 else { throw Failure.invalidSize }
            view.frame.size = CGSize(width: CGFloat(key.width), height: ceil(height))
            let snapshot = WKSnapshotConfiguration()
            snapshot.rect = CGRect(x: 0, y: 0, width: ceil(width), height: ceil(height))
            snapshot.snapshotWidth = NSNumber(value: ceil(width))
            let image = try await view.takeSnapshot(configuration: snapshot)
            try Task.checkCancellation()
            let baseline = (metrics["baseline"] as? Double) ?? height
            guard baseline.isFinite, baseline >= 0, baseline <= height else { throw Failure.invalidSize }
            let preview = RichPreviewRenderer.Preview(image: image, size: CGSize(width: width, height: height), baseline: baseline)
            guard preview.memoryCost <= RichPreviewCache.byteLimit else { throw Failure.invalidSize }
            return preview
        } catch {
            if (error as? Failure)?.isPermanent != true { reset() }
            throw error
        }
    }
}
