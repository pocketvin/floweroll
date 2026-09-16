import Foundation
import CryptoKit
import ImageIO
import CoreTransferable
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import PDFKit
import QuickLook



struct TaskMaterialManifest: Codable, Sendable {
    struct InputProvenance: Codable, Sendable {
        let bindingKey: String
        let sourceKind: String
        let sourceID: String
        let taskID: String
        let fileIDs: [String]
        let files: [TaskMaterialFile]

        enum CodingKeys: String, CodingKey {
            case files
            case bindingKey = "binding_key"
            case sourceKind = "source_kind"
            case sourceID = "source_id"
            case taskID = "task_id"
            case fileIDs = "file_ids"
        }
    }

    struct Plan: Codable, Sendable {
        struct Item: Codable, Sendable, Identifiable {
            let id: String
            let title: String
            let completionRule: String?

            enum CodingKeys: String, CodingKey {
                case id, title
                case completionRule = "completion_rule"
            }
        }
        let title: String
        let items: [Item]
    }
    let inputs: [TaskMaterialFile]
    let initialInputIDs: [String]?
    let outputs: [TaskMaterialFile]
    let progressiveOutputs: [TaskMaterialFile]?
    let inputProvenance: [InputProvenance]?
    let plan: Plan?
    let workSummary: HostWorkSummary?
    enum CodingKeys: String, CodingKey {
        case inputs, outputs, plan
        case initialInputIDs = "initial_input_ids"
        case progressiveOutputs = "progressive_outputs"
        case inputProvenance = "input_provenance"
        case workSummary = "work_summary"
    }
}

extension TaskMaterialManifest {
    /// Presentation-only delivery projection. Progressive files never become
    /// verified work evidence here; a later verified output simply enriches
    /// the same durable file identity.
    var presentedOutputs: [TaskMaterialFile] {
        var result: [TaskMaterialFile] = []
        var indexByID: [String: Int] = [:]
        for file in progressiveOutputs ?? [] {
            guard indexByID[file.id] == nil else { continue }
            indexByID[file.id] = result.count
            result.append(file)
        }
        for file in outputs {
            if let index = indexByID[file.id] {
                result[index] = file
            } else {
                indexByID[file.id] = result.count
                result.append(file)
            }
        }
        return result
    }

    var hasProgressiveDelivery: Bool {
        !(progressiveOutputs ?? []).isEmpty
    }

    func inputFilesBoundTo(sourceKind: String, sourceID: String) -> [TaskMaterialFile] {
        guard !sourceID.isEmpty,
              let provenance = inputProvenance?.first(where: {
                  $0.sourceKind == sourceKind && $0.sourceID == sourceID
              })
        else { return [] }

        var byID: [String: TaskMaterialFile] = [:]
        for file in inputs { byID[file.id] = file }
        for file in provenance.files where byID[file.id] == nil { byID[file.id] = file }
        return provenance.fileIDs.compactMap { byID[$0] }
    }

    func initialMessageFiles(submissionID: String?) -> [TaskMaterialFile] {
        if let submissionID, !submissionID.isEmpty {
            let exact = inputFilesBoundTo(sourceKind: "submission", sourceID: submissionID)
            if !exact.isEmpty { return exact }
        }
        let ids = initialInputIDs ?? []
        guard !ids.isEmpty else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: inputs.map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }

    func userTurnMessageFiles(attachmentIDs: [String], eventID: String?) -> [TaskMaterialFile] {
        if !attachmentIDs.isEmpty {
            let byID = Dictionary(uniqueKeysWithValues: inputs.map { ($0.id, $0) })
            let direct = attachmentIDs.compactMap { byID[$0] }
            if direct.count == attachmentIDs.count { return direct }
        }
        guard let eventID, !eventID.isEmpty else { return [] }
        return inputFilesBoundTo(sourceKind: "user_turn", sourceID: eventID)
    }
}

enum TaskMaterialProgressiveRefreshPolicy {
    /// A short presentation-only window. It is deliberately finite and does
    /// not depend on the outer Task presentation cursor changing.
    static let delayMilliseconds: [UInt64] = [0, 350, 700, 1_200, 2_000, 3_000, 4_000]

    static func shouldContinue(after manifest: TaskMaterialManifest?) -> Bool {
        guard let manifest else { return true }
        let progressiveOutputs = manifest.progressiveOutputs ?? []

        guard let work = manifest.workSummary else {
            // Missing read-model semantics are not proof that enrichment is
            // impossible. Stay conservative, but only inside the finite window.
            return progressiveOutputs.isEmpty
        }
        guard let plan = manifest.plan else {
            if !progressiveOutputs.isEmpty { return false }
            return work.state == "unplanned" || work.items.contains(where: { $0.state == "running" })
        }

        let progressiveCandidateIDs = Set(plan.items.compactMap { item -> String? in
            // Host work-item projection defaults a missing completion_rule to
            // document. Known native/non-document work cannot stage this PDF.
            let rule = item.completionRule?.lowercased() ?? "document"
            return rule == "document" ? item.id : nil
        })
        let runningMaterialIDs = Set(work.items.compactMap { item -> String? in
            item.state == "running" && progressiveCandidateIDs.contains(item.id) ? item.id : nil
        })
        guard !runningMaterialIDs.isEmpty else { return false }

        let stagedItemIDs = Set(progressiveOutputs.compactMap { file in
            file.metadata["item_id"]?.stringValue
        })
        return !runningMaterialIDs.isSubset(of: stagedItemIDs)
    }
}
