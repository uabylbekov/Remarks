import SwiftUI
import RemarksCore

#if canImport(UIKit)
typealias RichPreviewImage = UIImage
#else
typealias RichPreviewImage = NSImage
#endif

/// Coordinates requests from independent editors. WebKit and cache ownership are separate from scheduling.
@MainActor
final class RichPreviewRenderer {
    static let shared = RichPreviewRenderer()

    struct ContentStyle: Hashable {
        let source: String
        let kind: String
        let fontSize: CGFloat
        let dark: Bool
    }

    struct Key: Hashable {
        let source: String
        let kind: String
        let width: Int
        let fontSize: CGFloat
        let dark: Bool

        var contentAndStyle: ContentStyle {
            ContentStyle(source: source, kind: kind, fontSize: fontSize, dark: dark)
        }
    }

    struct Preview {
        let image: RichPreviewImage
        let size: CGSize
        /// Distance from the image's top edge to its text baseline; block previews use their bottom edge.
        let baseline: CGFloat
        let memoryCost: Int

        init(image: RichPreviewImage, size: CGSize, baseline: CGFloat? = nil) {
            self.image = image
            self.size = size
            self.baseline = baseline ?? size.height
            #if canImport(UIKit)
            let bitmap = image.cgImage
            #else
            let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            #endif
            memoryCost = bitmap.map { $0.bytesPerRow * $0.height } ?? Int(ceil(size.width) * ceil(size.height) * 16)
        }

        private init(image: RichPreviewImage, size: CGSize, baseline: CGFloat, memoryCost: Int) {
            self.image = image
            self.size = size
            self.baseline = baseline
            self.memoryCost = memoryCost
        }

        func fitting(width: CGFloat) -> Self {
            let scale = min(1, width / size.width)
            return Self(image: image, size: CGSize(width: min(width, size.width), height: size.height * scale),
                        baseline: baseline * scale, memoryCost: memoryCost)
        }
    }

    private struct RequestID: Hashable {
        let requester: UUID?
        let style: ContentStyle
    }

    private struct Request {
        let key: Key
        let completion: () -> Void
    }

    private struct FailureRecord {
        /// Nil means invalid source or an explicit rendering limit; transient failures expire.
        let retryAfter: Date?
    }

    private let cache = RichPreviewCache()
    private var requests: [RequestID: Request] = [:]
    private var queued: [Key] = []
    private var failures: [Key: FailureRecord] = [:]
    private var worker: Task<Void, Never>?
    private var activeKey: Key?
    private var generation = UUID()
    private let renderOperation: (Key) async throws -> Preview
    private let prepareOperation: () async -> Void
    private let resetOperation: () -> Void

    convenience init() {
        let backend = RichPreviewWebRenderer()
        self.init(render: { try await backend.render($0) },
                  prepare: { _ = try? await backend.prepare() }, reset: { backend.reset() })
    }

    /// Injection keeps queue, cancellation, failure, and multi-window contracts verifiable without timing WebKit.
    init(render: @escaping (Key) async throws -> Preview,
         prepare: @escaping () async -> Void = {}, reset: @escaping () -> Void = {}) {
        renderOperation = render
        prepareOperation = prepare
        resetOperation = reset
    }

    func preview(for item: RichMarkdown, width: CGFloat, dark: Bool, fontSize: CGFloat? = nil, requester: UUID? = nil,
                 completion: @escaping () -> Void) -> Preview? {
        guard width.isFinite, width > 20, item.content.utf16.count <= 20_000 else { return nil }
        let key = Key(source: item.content, kind: item.kind.rawValue, width: Int(min(2000, width)),
                      fontSize: fontSize ?? EditorTheme.proseFont.pointSize, dark: dark)
        let id = RequestID(requester: requester, style: key.contentAndStyle)
        if let value = cache.value(for: key) {
            requests.removeValue(forKey: id)
            pruneQueue()
            return value
        }
        let fallback = cache.fallback(for: key)
        if let failure = failures[key] {
            if failure.retryAfter.map({ $0 > .now }) ?? true { return fallback }
            failures.removeValue(forKey: key)
        }
        guard requests[id] != nil || requests.count < 128 else { return fallback }
        requests[id] = Request(key: key, completion: completion)
        // Coalesce each editor's obsolete widths, while preserving another window's exact requested width.
        pruneQueue()
        if activeKey != key, !queued.contains(key) { queued.append(key) }
        startWorkerIfNeeded()
        return fallback
    }

    private func pruneQueue() {
        let needed = Set(requests.values.map(\.key))
        queued.removeAll { !needed.contains($0) }
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, !queued.isEmpty else { return }
        let token = generation
        worker = Task { [weak self] in await self?.drain(generation: token) }
    }

    private func drain(generation token: UUID) async {
        defer {
            if generation == token {
                activeKey = nil
                worker = nil
            }
        }
        while generation == token, !Task.isCancelled, !queued.isEmpty {
            let key = queued.removeFirst()
            guard requests.values.contains(where: { $0.key == key }) else { continue }
            activeKey = key
            do {
                let value = try await renderWithRecovery(key)
                guard generation == token, !Task.isCancelled else { return }
                cache.insert(value, for: key)
                failures.removeValue(forKey: key)
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                if failures.count >= 64, let oldest = failures.keys.first { failures.removeValue(forKey: oldest) }
                let permanent = (error as? RichPreviewWebRenderer.Failure)?.isPermanent == true
                failures[key] = FailureRecord(retryAfter: permanent ? nil : .now.addingTimeInterval(1))
            }
            activeKey = nil
            // Notify exact requests only. Different widths in other windows must get their own completed snapshot.
            let completed = requests.filter { $0.value.key == key }
            for id in completed.keys { requests.removeValue(forKey: id) }
            for request in completed.values { request.completion() }
        }
    }

    private func renderWithRecovery(_ key: Key) async throws -> Preview {
        do {
            return try await renderOperation(key)
        } catch {
            try Task.checkCancellation()
            if (error as? RichPreviewWebRenderer.Failure)?.isPermanent == true { throw error }
            resetOperation()
            try await Task.sleep(for: .milliseconds(100))
            return try await renderOperation(key)
        }
    }

    func release(requester: UUID) {
        requests = requests.filter { $0.key.requester != requester }
        pruneQueue()
    }

    func prepare() async { await prepareOperation() }

    func cancel() {
        generation = UUID()
        worker?.cancel()
        worker = nil
        activeKey = nil
        queued.removeAll()
        requests.removeAll()
        failures.removeAll()
        cache.removeAll()
        resetOperation()
    }

    /// Direct backend access for isolated rendering verification. Editor requests always use the serial queue above.
    func render(_ key: Key) async throws -> Preview { try await renderOperation(key) }
}
