import Foundation

struct DotTaskMetadata: Codable, Equatable, Sendable {
    var id: String
    var attachedAt: String
    var latestTurnStatus: String
    var title: String
    var project: String
}

struct DotTaskSnapshot: Codable, Equatable, Sendable {
    var snapshotObservedAt: String?
    var tasks: [DotTaskMetadata]

    private struct Input: Decodable {
        var snapshot_observed_at: String?
        var tasks: [Task]
    }
    private struct Task: Decodable {
        var id: String
        var attachedAt: String
        var latestTurn: LatestTurn
        var title: String?
        var project: String?
    }
    private struct LatestTurn: Decodable { var status: String }

    static func decode(_ data: Data) throws -> DotTaskSnapshot {
        guard data.count <= 2 * 1024 * 1024 else { throw ImportError.tooLarge }
        let input = try JSONDecoder().decode(Input.self, from: data)
        guard input.tasks.count <= 20_000 else { throw ImportError.tooManyTasks }
        let observed = input.snapshot_observed_at
        if let observed, !validTimestamp(observed) { throw ImportError.invalidMetadata }
        var seen = Set<String>()
        let tasks = try input.tasks.map { task -> DotTaskMetadata in
            guard safeID(task.id), seen.insert(task.id).inserted,
                  validTimestamp(task.attachedAt), safeStatus(task.latestTurn.status) else {
                throw ImportError.invalidMetadata
            }
            let title = task.title ?? "ChatGPT タスク \(task.id.suffix(8))"
            guard safeText(title, maximum: 300) else { throw ImportError.invalidMetadata }
            let rawProject = task.project ?? "不明"
            guard safeText(rawProject, maximum: 500) else { throw ImportError.invalidMetadata }
            let project = rawProject.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? "不明"
            return DotTaskMetadata(id: task.id, attachedAt: task.attachedAt,
                                   latestTurnStatus: task.latestTurn.status,
                                   title: title, project: String(project.prefix(200)))
        }
        return DotTaskSnapshot(snapshotObservedAt: observed, tasks: tasks)
    }

    private static func safeID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && value.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
    }
    private static func safeStatus(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 40 && value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }
    private static func safeText(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.count <= maximum && value.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 }
    }
    private static func validTimestamp(_ value: String) -> Bool {
        guard value.count <= 40,
              value.range(of: "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(?:\\.\\d+)?(?:Z|[+-]\\d{2}:\\d{2})$", options: .regularExpression) != nil else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if formatter.date(from: value) != nil { return true }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value) != nil
    }
    enum ImportError: Error { case tooLarge, tooManyTasks, invalidMetadata }
}
