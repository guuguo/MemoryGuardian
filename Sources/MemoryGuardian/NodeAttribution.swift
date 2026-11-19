import Foundation
import Darwin

enum NodeAttribution {
    static func isNode(_ command: String) -> Bool {
        ["node", "nodejs"].contains(URL(fileURLWithPath: command).lastPathComponent)
    }

    static func readService(pid: Int32) -> ProcessService? {
        guard let args = readArguments(pid: pid) else { return nil }
        // 仅保留服务名和入口路径，不保存原始参数。
        if let result = service(arguments: args) { return result }
        guard let entry = args.dropFirst().first, !entry.hasPrefix("/"), !entry.hasPrefix("-") else { return nil }
        return service(arguments: args, currentDirectory: currentDirectory(pid: pid))
    }

    static func readArguments(pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var data = Data(count: size)
        let status = data.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }
        guard status == 0 else { return nil }
        // 仅解析 argc 个参数，不解析或保存其后环境变量；仅保留服务名和入口路径。
        return arguments(from: data.prefix(size))
    }

    static func arguments(from data: Data) -> [String] {
        guard data.count >= MemoryLayout<Int32>.size else { return [] }
        let count = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0 else { return [] }
        let bytes = [UInt8](data)
        var index = MemoryLayout<Int32>.size
        // 内核布局：argc、可执行路径、零填充、argv、环境变量。
        while index < bytes.count && bytes[index] != 0 { index += 1 }
        while index < bytes.count && bytes[index] == 0 { index += 1 }
        var values: [String] = []
        for _ in 0..<Int(count) {
            guard index < bytes.count else { break }
            let start = index
            while index < bytes.count && bytes[index] != 0 { index += 1 }
            values.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return values
    }

    static func service(arguments: [String], currentDirectory: String? = nil) -> ProcessService? {
        // npm 会重写 argv[0]，把原参数合成进程标题。
        if let title = arguments.first, title.hasPrefix("npm exec "),
           let package = title.dropFirst("npm exec ".count).split(separator: " ").first {
            return packageService(String(package), entryPoint: nil)
        }
        guard arguments.count > 1, !arguments[1].hasPrefix("-") else { return nil }
        let entry = arguments[1]
        let url: URL
        if entry.hasPrefix("/") { url = URL(fileURLWithPath: entry).standardizedFileURL }
        else if let currentDirectory {
            url = URL(fileURLWithPath: currentDirectory).appendingPathComponent(entry).standardizedFileURL
        } else { return nil }

        var script = url
        if script.path.contains("/node_modules/.bin/"),
           let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: script.path) {
            script = destination.hasPrefix("/") ? URL(fileURLWithPath: destination) : script.deletingLastPathComponent().appendingPathComponent(destination)
            script = script.standardizedFileURL
        }
        if let suffix = script.path.components(separatedBy: "/node_modules/").dropFirst().last {
            let parts = suffix.split(separator: "/")
            if let first = parts.first {
                let package: String
                if first == ".bin" { package = parts.dropFirst().first.map(String.init) ?? "" }
                else if first.hasPrefix("@"), parts.count > 1 { package = "\(first)/\(parts[1])" }
                else { package = String(first) }
                return packageService(package, entryPoint: script.path)
            }
        }
        guard ["js", "mjs", "cjs"].contains(script.pathExtension) else { return nil }
        var directory = script.deletingLastPathComponent()
        if ["src", "scripts", "bin", "dist", "build"].contains(directory.lastPathComponent) {
            directory.deleteLastPathComponent()
        }
        let generic = ["server", "index", "main", "cli"].contains(script.deletingPathExtension().lastPathComponent)
        let name = generic ? directory.lastPathComponent : "\(directory.lastPathComponent) / \(script.lastPathComponent)"
        return ProcessService(identity: "script:\(script.path)", name: name, entryPoint: script.path)
    }

    private static func packageService(_ token: String, entryPoint: String?) -> ProcessService? {
        var package = token
        if let version = package.lastIndex(of: "@"), version != package.startIndex { package = String(package[..<version]) }
        guard package.range(of: #"^(?:@[A-Za-z0-9_.-]+/)?[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else { return nil }
        return ProcessService(identity: "package:\(package)", name: package, entryPoint: entryPoint)
    }

    private static func currentDirectory(pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }
}
