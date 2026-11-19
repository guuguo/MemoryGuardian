import Foundation

enum ProcessRunner {
    static func run(executable: String, arguments: [String], timeout: TimeInterval = 10) throws -> (status: Int32, stdout: Data, stderr: Data) {
        let task = Process()
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("memory-guardian-stdout-\(UUID().uuidString)")
        let errorURL = FileManager.default.temporaryDirectory.appendingPathComponent("memory-guardian-stderr-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.standardOutput = outputHandle
        task.standardError = errorHandle

        try task.run()

        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if task.isRunning {
            task.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if task.isRunning { task.interrupt() }
            try? outputHandle.close()
            try? errorHandle.close()
            throw ProcessRunnerError.timeout(executable)
        }

        try? outputHandle.close()
        try? errorHandle.close()
        let stdout = (try? Data(contentsOf: outputURL)) ?? Data()
        let stderr = (try? Data(contentsOf: errorURL)) ?? Data()
        try? FileManager.default.removeItem(at: outputURL)
        try? FileManager.default.removeItem(at: errorURL)

        return (
            task.terminationStatus,
            stdout,
            stderr
        )
    }
}

enum ProcessRunnerError: LocalizedError {
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .timeout(let executable): "命令超时：\(executable)"
        }
    }
}
