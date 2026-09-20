#!/usr/bin/env swift

import CoreGraphics
import Foundation

var owner = "Lyrimuse"
var requireOverlay = false
var args = Array(CommandLine.arguments.dropFirst())
while let arg = args.first {
    args.removeFirst()
    switch arg {
    case "--owner":
        guard let v = args.first else { print("--owner 后面要跟 App 名"); exit(2) }
        owner = v
        args.removeFirst()
    case "--require-overlay":
        requireOverlay = true
    case "-h", "--help":
        print("""
        用法: check-windows.swift [--owner <App名>] [--require-overlay]
          --owner            要查的 App，默认 Lyrimuse
          --require-overlay  找不到可见的歌词悬浮窗就以非零码退出，可用作断言

        ⚠️ --require-overlay 的前提是**正在播放**。开着「暂停/无播放时隐藏悬浮窗」
           这个设置时，停播状态下悬浮窗 onscreen=false 是正确行为，不是故障。
        """)
        exit(0)
    default:
        print("不认识的参数: \(arg)"); exit(2)
    }
}

guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]]
else {
    print("拿不到窗口列表（需要「屏幕录制」权限？）")
    exit(1)
}

struct WindowInfo {
    let id: Int
    let title: String
    let bounds: CGRect
    let onscreen: Bool
    let layer: Int
    let alpha: Double
}

let windows: [WindowInfo] = list.compactMap { w in
    let ownerName = w[kCGWindowOwnerName as String] as? String ?? ""
    guard ownerName.localizedCaseInsensitiveContains(owner) else { return nil }
    let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    return WindowInfo(
        id: w[kCGWindowNumber as String] as? Int ?? -1,
        title: w[kCGWindowName as String] as? String ?? "",
        bounds: CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0),
        onscreen: (w[kCGWindowIsOnscreen as String] as? Bool) ?? false,
        layer: w[kCGWindowLayer as String] as? Int ?? 0,
        alpha: w[kCGWindowAlpha as String] as? Double ?? -1)
}

if windows.isEmpty {
    print("没有找到属于 \(owner) 的窗口 —— 进程没起来，或者它此刻一个窗口都没开")
    exit(requireOverlay ? 1 : 0)
}

func kind(of w: WindowInfo) -> String {
    if w.layer >= 1000 { return "menubar" }
    if w.layer > 0 { return "overlay" }
    return "window "
}

for w in windows {
    let size = "\(Int(w.bounds.width))x\(Int(w.bounds.height))"
    let pos = "@(\(Int(w.bounds.minX)),\(Int(w.bounds.minY)))"
    let title = w.title.isEmpty ? "(无标题)" : w.title
    print("\(kind(of: w)) id=\(w.id) onscreen=\(w.onscreen) layer=\(w.layer) alpha=\(w.alpha) \(size)\(pos) \(title)")
}

if requireOverlay {

    let live = windows.filter {
        kind(of: $0) == "overlay" && $0.onscreen
            && $0.bounds.width > 0 && $0.bounds.height > 0 && $0.alpha > 0
    }
    if live.isEmpty {
        print("FAIL: 没有可见的歌词悬浮窗（在屏 + 非零尺寸 + alpha>0）")
        print("      如果此刻没在播放、且开着「暂停/无播放时隐藏悬浮窗」，这是预期结果。")
        exit(1)
    }
    print("OK: \(live.count) 个可见悬浮窗")
}
