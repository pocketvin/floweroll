import ActivityKit
import Foundation

enum FlowerollActivityPhase: String, Codable, Hashable {
    case listening
    case processing
    case needsUser
    case completed
    case failed
    case cancelled
}

enum FlowerollActivityPresentation {
    static let currentVersion = 10
}

struct FlowerollActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: FlowerollActivityPhase
        var message: String
        var taskID: String?
        var taskTitle: String?
        var completedCount: Int?
        var totalCount: Int?
        var updatedAt: String?
        var presentationVersion: Int? = FlowerollActivityPresentation.currentVersion
        var presentationPulse: Int?

        var taskURL: URL? {
            guard let taskID, UUID(uuidString: taskID) != nil else { return nil }
            return URL(string: "floweroll://task/" + taskID)
        }

        var homeURL: URL? {
            URL(string: "floweroll://home")
        }

        var fraction: Double? {
            guard let completedCount, let totalCount, totalCount > 0,
                  completedCount >= 0, completedCount <= totalCount else { return nil }
            return Double(completedCount) / Double(totalCount)
        }

        var progressLabel: String? {
            guard fraction != nil, let completedCount, let totalCount else { return nil }
            return "已完成 \(completedCount)/\(totalCount) 项"
        }

        var effectivePresentationPulse: Int {
            presentationPulse ?? 0
        }

        mutating func advancePresentationPulse() {
            presentationPulse = (effectivePresentationPulse + 1) % 6
        }
    }

    let sessionID: String
}
