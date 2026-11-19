import AppKit

// MARK: - App 图标缓存管理
final class AppIconCache: @unchecked Sendable {
    static let shared = AppIconCache()
    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 200 // 缓存最多200个应用图标
    }

    func get(_ key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    func set(_ key: String, image: NSImage) {
        cache.setObject(image, forKey: key as NSString)
    }
}

enum AppAssets {
    // 静态大图缓存，避免在每一帧的 body 求值中同步加载磁盘 PNG 与解码
    static let cachedAppIcon: NSImage? = {
        if let appBundleIcon = Bundle.main.url(
            forResource: "memory-guardian-icon",
            withExtension: "png"
        ) {
            return NSImage(contentsOf: appBundleIcon)
        }

        guard let packageIcon = Bundle.module.url(
            forResource: "memory-guardian-icon",
            withExtension: "png"
        ) else {
            return nil
        }

        return NSImage(contentsOf: packageIcon)
    }()

    static func appIcon() -> NSImage? {
        cachedAppIcon
    }

    static func icon(forAppPathOrName pathOrName: String) -> NSImage? {
        let cleanName = pathOrName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return nil }

        // 1. 如果是绝对路径
        if cleanName.hasPrefix("/") {
            if let range = cleanName.range(of: ".app") {
                let appPath = String(cleanName[..<range.upperBound])
                if FileManager.default.fileExists(atPath: appPath) {
                    return NSWorkspace.shared.icon(forFile: appPath)
                }
            }
            if FileManager.default.fileExists(atPath: cleanName) {
                return NSWorkspace.shared.icon(forFile: cleanName)
            }
        }

        // 2. 如果不含路径，在 Applications 里找
        let standardPath = "/Applications/\(cleanName).app"
        if FileManager.default.fileExists(atPath: standardPath) {
            return NSWorkspace.shared.icon(forFile: standardPath)
        }

        // 3. 利用 NSWorkspace 模糊查找完整路径
        if let fullPath = NSWorkspace.shared.fullPath(forApplication: cleanName) {
            return NSWorkspace.shared.icon(forFile: fullPath)
        }

        return nil
    }
}
