import AppKit
import LyrimuseCore
import SwiftUI

@MainActor
final class ImageMemoryCache {
    static let shared = ImageMemoryCache()

    enum Variant: String {
        case thumbnail
        case original

        var maxPixel: CGFloat? { self == .thumbnail ? 256 : nil }
    }

    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()

        c.countLimit = 400
        c.totalCostLimit = 48 << 20
        return c
    }()

    private var failedAt: [URL: Date] = [:]
    private static let failureTTL: TimeInterval = 10 * 60
    private static let failureCap = 512

    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    private static func key(_ url: URL, _ variant: Variant) -> NSString {
        (variant.rawValue + "|" + url.absoluteString) as NSString
    }

    func image(for url: URL, variant: Variant = .thumbnail) -> NSImage? {
        cache.object(forKey: Self.key(url, variant))
    }

    func store(_ image: NSImage, for url: URL, variant: Variant = .thumbnail) {

        let cost = max(1, image.pixelWidth * image.pixelHeight * 4)
        cache.setObject(image, forKey: Self.key(url, variant), cost: cost)
        failedAt[url] = nil
    }

    func load(_ url: URL, variant: Variant = .thumbnail) async -> NSImage? {
        if let hit = image(for: url, variant: variant) { return hit }
        if let failed = failedAt[url], Date().timeIntervalSince(failed) < Self.failureTTL {
            return nil
        }
        let flightKey = Self.key(url, variant) as String
        if let running = inFlight[flightKey] { return await running.value }
        let task = Task<NSImage?, Never> {
            await CachedImage<EmptyView>.loadForPrewarm(url, maxPixel: variant.maxPixel)
        }
        inFlight[flightKey] = task
        let result = await task.value
        inFlight[flightKey] = nil
        if let result {
            store(result, for: url, variant: variant)
        } else {
            if failedAt.count >= Self.failureCap { failedAt.removeAll() }
            failedAt[url] = Date()
        }
        return result
    }

    func prewarm(_ urls: [URL]) {
        let missing = Array(Set(urls.filter { image(for: $0) == nil }))
        guard !missing.isEmpty else { return }
        Task { [weak self] in
            await withTaskGroup(of: (URL, NSImage?).self) { group in
                var index = 0
                func addNext() {
                    guard index < missing.count else { return }
                    let url = missing[index]
                    index += 1
                    group.addTask { [weak self] in
                        (url, await self?.load(url))
                    }
                }
                for _ in 0..<min(4, missing.count) { addNext() }
                for await (_, _) in group {

                    addNext()
                }
            }
        }
    }
}

struct CachedImage<Placeholder: View>: View {
    private let url: URL?
    private let variant: ImageMemoryCache.Variant
    private let placeholder: () -> Placeholder
    @State private var image: NSImage?

    init(url: URL?, variant: ImageMemoryCache.Variant = .thumbnail,
         @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.variant = variant
        self.placeholder = placeholder
        _image = State(initialValue: url.flatMap { ImageMemoryCache.shared.image(for: $0, variant: variant) })
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                placeholder()
            }
        }

        .task(id: url) {
            guard let url else {
                image = nil
                return
            }

            if image != nil, let hit = ImageMemoryCache.shared.image(for: url, variant: variant) {
                if image !== hit { image = hit }
                return
            }
            guard let loaded = await ImageMemoryCache.shared.load(url, variant: variant) else { return }

            guard !Task.isCancelled else { return }
            image = loaded
        }
    }

    static func loadForPrewarm(_ url: URL, maxPixel: CGFloat?) async -> NSImage? {
        await load(url, maxPixel: maxPixel)
    }

    private static func load(_ url: URL, maxPixel: CGFloat?) async -> NSImage? {

        let start = Date()
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            let status = (resp as? HTTPURLResponse)?.statusCode
            NetworkAuditLog.record(service: "image", operation: "image", host: url.host ?? "unknown",
                                   statusCode: status, durationMs: Date().timeIntervalSince(start) * 1000, error: nil)
            if let maxPixel,
               let src = CGImageSourceCreateWithData(data as CFData, nil),
               let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                   kCGImageSourceCreateThumbnailFromImageAlways: true,
                   kCGImageSourceCreateThumbnailWithTransform: true,
                   kCGImageSourceThumbnailMaxPixelSize: maxPixel,
               ] as CFDictionary) {
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
            return NSImage(data: data)
        } catch {
            NetworkAuditLog.record(service: "image", operation: "image", host: url.host ?? "unknown",
                                   statusCode: nil, durationMs: Date().timeIntervalSince(start) * 1000, error: error)
            return nil
        }
    }
}

extension NSImage {

    var pixelWidth: Int { representations.first.map(\.pixelsWide) ?? Int(size.width.rounded()) }
    var pixelHeight: Int { representations.first.map(\.pixelsHigh) ?? Int(size.height.rounded()) }
}
