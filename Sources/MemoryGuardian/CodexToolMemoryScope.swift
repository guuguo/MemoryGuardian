import Foundation

/// 以应用列表的同一快照和计量口径分解工具子集，应用外的已知残留另列。
struct CodexToolMemoryScope {
    let application: AppMemoryUsage?
    let included: [CodexToolAssessment]
    let detached: [CodexToolAssessment]
    private let appProcesses: [Int32: ProcessDetail]

    static func key(for app: AppMemoryUsage) -> String { app.groupKey ?? app.applicationURL?.path ?? app.command }
    static func supports(_ app: AppMemoryUsage) -> Bool {
        ["ChatGPT.app", "Codex.app"].contains(app.applicationURL?.lastPathComponent ?? "")
    }

    init(application: AppMemoryUsage?, applicationKey: String, assessments: [CodexToolAssessment]) {
        self.application = application
        let byPID = Dictionary(uniqueKeysWithValues: (application?.processes ?? []).map { ($0.pid, $0) })
        appProcesses = byPID
        included = assessments.filter { tool in
            guard let row = byPID[tool.process.pid] else { return false }
            return row.startTimeTicks == tool.process.startTimeTicks
        }
        detached = assessments.filter { $0.applicationKey == applicationKey && byPID[$0.process.pid] == nil }
    }

    var tools: [CodexToolAssessment] { included + detached }
    var usesFootprint: Bool { application?.usesFootprint ?? false }
    var detachedUsesFootprint: Bool { detached.allSatisfy { $0.process.footprintBytes != nil } }
    var toolBytes: UInt64 { included.reduce(0) { $0 + bytes(for: $1) } }
    var otherBytes: UInt64? { application.map { $0.memoryBytes - toolBytes } }
    var detachedBytes: UInt64 { detached.reduce(0) { $0 + bytes(for: $1) } }

    func isIncluded(_ tool: CodexToolAssessment) -> Bool {
        guard let row = appProcesses[tool.process.pid] else { return false }
        return row.startTimeTicks == tool.process.startTimeTicks
    }

    func bytes(for tool: CodexToolAssessment) -> UInt64 {
        if isIncluded(tool), let row = appProcesses[tool.process.pid] {
            return usesFootprint ? row.footprintBytes ?? 0 : row.memoryBytes
        }
        return detachedUsesFootprint ? tool.process.footprintBytes ?? 0 : tool.process.memoryBytes
    }
}
