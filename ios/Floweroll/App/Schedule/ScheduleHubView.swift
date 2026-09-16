import CryptoKit
import Foundation
import Observation
import SwiftUI



@MainActor
struct ScheduleHubView: View {
    @State private var model: ScheduleHubModel
    @State private var showsPast = false

    init(model: ScheduleHubModel = ScheduleHubModel()) {
        _model = State(initialValue: model)
    }

    var body: some View {
        List {
            if model.items.isEmpty && model.isRefreshing {
                HStack {
                    Spacer()
                    ProgressView("正在整理安排…")
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } else if model.items.isEmpty {
                ContentUnavailableView(
                    ScheduleHubPresentation.emptyTitle,
                    systemImage: "calendar.badge.clock",
                    description: Text("小卷确认过的日历、提醒和闹钟会自动出现在这里。")
                )
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("schedule-hub.empty")
            } else {
                Section {
                    ScheduleHubSummaryCard(summary: model.summary)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear)
                }

                ForEach(model.sections.filter { $0.kind != .past }) { section in
                    Section(section.kind.title) {
                        ForEach(section.items) { item in
                            NavigationLink {
                                ScheduleHubItemDetailView(item: item, model: model)
                            } label: {
                                ScheduleHubRow(item: item)
                            }
                            .accessibilityIdentifier("schedule-hub.row.\(item.stableIdentity)")
                        }
                    }
                }

                if let past = model.sections.first(where: { $0.kind == .past }) {
                    Section {
                        DisclosureGroup(isExpanded: $showsPast) {
                            ForEach(past.items) { item in
                                NavigationLink {
                                    ScheduleHubItemDetailView(item: item, model: model)
                                } label: {
                                    ScheduleHubRow(item: item, subdued: true)
                                }
                            }
                        } label: {
                            Text("过去与失效 · \(past.items.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if model.hasAnySourceFailure {
                Section("刷新状态") {
                    ForEach(ScheduleSourceKind.allCases.filter { model.sourceErrors[$0] != nil }, id: \.self) { kind in
                        Label {
                            Text(model.sourceErrors[kind] ?? "暂时无法刷新")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "exclamationmark.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(ScheduleHubPresentation.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.refresh() }
        .task { await model.refresh() }
    }
}


private struct ScheduleHubSummaryCard: View {
    let summary: ScheduleHubSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("今天 · \(summary.todayCount) 项")
                .font(.headline)
            if let next = summary.nextItem {
                HStack(spacing: 6) {
                    Text("下一项")
                        .foregroundStyle(.secondary)
                    Text(next.startAt?.formatted(.dateTime.hour().minute()) ?? "待定")
                        .fontWeight(.semibold)
                    Text(next.title)
                        .lineLimit(1)
                }
                .font(.subheadline)
            } else {
                Text("近期没有待开始的定时安排")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityIdentifier("schedule-hub.summary")
    }
}


private struct ScheduleHubRow: View {
    let item: ScheduleItem
    var subdued = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(ScheduleHubPresentation.timeText(item, now: Date(), calendar: .autoupdatingCurrent))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(subdued ? .tertiary : .secondary)
                .frame(width: 72, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.body.weight(item.status.isPrimaryUpcoming ? .medium : .regular))
                    .foregroundStyle(subdued ? .secondary : .primary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Image(systemName: item.sourceKind.systemImage)
                    Text(item.sourceKind.displayName)
                    if let recurrence = item.recurrenceDescription {
                        Text("·")
                        Text(recurrence)
                            .lineLimit(1)
                    }
                    if item.status != .upcoming {
                        Text("·")
                        Text(item.status.displayName)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 3)
    }
}


private struct ScheduleHubItemDetailView: View {
    let item: ScheduleItem
    let model: ScheduleHubModel

    @Environment(\.dismiss) private var dismiss
    @State private var showsRemovalConfirmation = false
    @State private var isRemoving = false
    @State private var removalMessage: String?
    @State private var removalIsAmbiguous = false

    var body: some View {
        Form {
            Section {
                Text(item.title)
                    .font(.title3.weight(.semibold))
                LabeledContent("来源", value: item.sourceKind.displayName)
                LabeledContent("状态", value: item.status.displayName)
                LabeledContent("时间", value: timeDescription)
                if let end = item.endAt {
                    LabeledContent("结束", value: end.formatted(date: .abbreviated, time: .shortened))
                }
                if let recurrence = item.recurrenceDescription {
                    LabeledContent("重复", value: recurrence)
                }
                if let context = item.sourceContext, !context.isEmpty {
                    LabeledContent("来源信息", value: context)
                }
            }

            if !item.sourceExists || item.status == .removed {
                Section {
                    Label("这个来源对象当前已不存在，不会继续作为正常待办安排显示。", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }

            if let removal = item.removal {
                Section {
                    Button(removal.actionTitle, role: .destructive) {
                        showsRemovalConfirmation = true
                    }
                    .disabled(!removal.eligible || isRemoving || removalIsAmbiguous)

                    if !removal.eligible, let reason = removal.ineligibleReason {
                        Text(reason)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if isRemoving {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在从系统中移除并核对结果…")
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    if let removalMessage {
                        Text(removalMessage)
                            .font(.footnote)
                            .foregroundStyle(removalIsAmbiguous ? .orange : .secondary)
                    }
                } header: {
                    Text("管理")
                } footer: {
                    Text("移除会直接修改系统\(item.sourceKind == .calendar ? "日历" : "提醒事项")。执行前会再次核对原生 ID、版本和所属列表；结果不明确时不会自动重试。")
                }
            }

            Section("来源详情") {
                Text(detailGuidance)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("安排详情")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("schedule-hub.detail")
        .confirmationDialog(
            "确认移除“\(item.title)”？",
            isPresented: $showsRemovalConfirmation,
            titleVisibility: .visible
        ) {
            if let removal = item.removal {
                Button(removal.actionTitle, role: .destructive) {
                    performRemoval(removal)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            if let removal = item.removal {
                Text(removal.confirmationMessage)
            }
        }
    }

    private func performRemoval(_ removal: ScheduleRemovalDescriptor) {
        guard !isRemoving else { return }
        isRemoving = true
        removalMessage = nil

        Task { @MainActor in
            defer { isRemoving = false }
            do {
                let coordinator = try ScheduleHubRemovalCoordinator.makeDefault(for: removal.sourceKind)
                switch try await coordinator.remove(removal) {
                case .removed:
                    model.recordVerifiedRemoval(item)
                    await model.refresh()
                    dismiss()
                case let .failed(message):
                    removalIsAmbiguous = false
                    removalMessage = message
                    await model.refresh()
                case let .needsReconciliation(message):
                    removalIsAmbiguous = true
                    removalMessage = message
                    await model.refresh()
                }
            } catch {
                removalIsAmbiguous = true
                removalMessage = "移除结果暂时无法确认；小卷不会自动再次删除。"
                await model.refresh()
            }
        }
    }

    private var timeDescription: String {
        guard let start = item.startAt else { return "未定时间" }
        if item.isAllDay { return start.formatted(date: .abbreviated, time: .omitted) + " · 全天" }
        return start.formatted(date: .abbreviated, time: .shortened)
    }

    private var detailGuidance: String {
        if !item.sourceExists || item.status == .removed {
            return "这是小卷保留的已移除记录，用于让你在「过去与失效」中继续看到刚刚删除的安排；系统来源对象本身已经不存在。"
        }
        switch item.navigationTarget {
        case .alarm:
            return "这是小卷闹钟管理真相的只读投影；需要修改时请使用设置中的「小卷闹钟」。"
        case .calendar:
            return "这是当前日历 fresh readback；支持对安全、精确匹配的单次日程直接移除。"
        case .reminder:
            return "这是当前提醒事项 fresh readback；支持对安全、精确匹配的非重复提醒直接移除。"
        case .readOnly:
            return "这是来源确认后的只读安排投影。"
        }
    }
}
