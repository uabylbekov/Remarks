import Foundation

/// A single byte budget across all notes and windows. Cache hits update recency; replacing a key never counts it twice.
@MainActor
final class RichPreviewCache {
    nonisolated static let byteLimit = 32_000_000
    private let limit: Int

    init(byteLimit: Int = RichPreviewCache.byteLimit) { limit = byteLimit }

    private var values: [RichPreviewRenderer.Key: RichPreviewRenderer.Preview] = [:]
    private var order: [RichPreviewRenderer.Key] = []
    private(set) var byteCount = 0

    func value(for key: RichPreviewRenderer.Key) -> RichPreviewRenderer.Preview? {
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    func fallback(for key: RichPreviewRenderer.Key) -> RichPreviewRenderer.Preview? {
        guard let match = order.filter({ $0.contentAndStyle == key.contentAndStyle })
            .min(by: { abs($0.width - key.width) < abs($1.width - key.width) }),
              let value = value(for: match) else { return nil }
        return value.fitting(width: CGFloat(key.width))
    }

    func insert(_ value: RichPreviewRenderer.Preview, for key: RichPreviewRenderer.Key) {
        let cost = value.memoryCost
        guard cost <= limit else { return }
        remove(key)
        while byteCount + cost > limit, let oldest = order.first { remove(oldest) }
        values[key] = value
        order.append(key)
        byteCount += cost
    }

    func removeAll() {
        values.removeAll()
        order.removeAll()
        byteCount = 0
    }

    private func touch(_ key: RichPreviewRenderer.Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func remove(_ key: RichPreviewRenderer.Key) {
        if let value = values.removeValue(forKey: key) { byteCount -= value.memoryCost }
        order.removeAll { $0 == key }
    }
}
