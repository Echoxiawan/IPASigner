import AppKit
import Foundation

/// 用 `--snapshot <路径>` 启动时，会在窗口渲染完成后把自己窗口的内容存成 PNG 再退出。
/// 走 NSView.cacheDisplay，不依赖「屏幕录制」权限，方便自检 / 出文档截图。
enum Snapshot {
    static var pendingPath: String?
    static var pendingIPA: String?

    static func parseArguments() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            pendingPath = args[i + 1]
        }
        if let i = args.firstIndex(of: "--ipa"), i + 1 < args.count {
            pendingIPA = args[i + 1]
        }
    }

    @MainActor
    static func captureFrontWindow(to path: String) -> Bool {
        guard let window = NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.windows.first,
              let view = window.contentView,
              view.bounds.width > 1, view.bounds.height > 1 else {
            return false
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            return false
        }
    }
}
