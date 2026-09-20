import Foundation
import SwiftUI

@MainActor
final class NotchTransientCenter: ObservableObject {
    static let shared = NotchTransientCenter()

    struct Banner: Equatable {

        var icon: String
        var text: String

        var progress: Double?
    }

    @Published private(set) var banner: Banner?

    private var dismissTask: Task<Void, Never>?

    private init() {}

    func show(_ banner: Banner, for duration: TimeInterval = 1.4) {
        self.banner = banner
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }
}

struct NotchTransientRow: View {
    let banner: NotchTransientCenter.Banner
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: banner.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)

                .frame(width: 16)
            Text(banner.text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint.opacity(0.9))
                .lineLimit(1)
            if let progress = banner.progress {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(tint.opacity(0.18))
                        Capsule().fill(tint.opacity(0.85))
                            .frame(width: proxy.size.width * min(1, max(0, progress)))
                    }
                }
                .frame(height: 3)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
    }
}
