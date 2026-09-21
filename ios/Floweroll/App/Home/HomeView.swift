import AVFAudio
import AVFoundation
import AppIntents
import ContactsUI
import SwiftUI
import UserNotifications


// MARK: - Home / New Task

enum HomeSubmissionWatchdogState: Equatable {
    case submitting
    case uploadingAttachments
    case systemDidNotStart

    var message: String {
        switch self {
        case .submitting:
            return "任务正在后台提交，请稍候…"
        case .uploadingAttachments:
            return "附件正在后台上传；任务已安全保留，上传完成后会自动交给小卷。"
        case .systemDidNotStart:
            return "系统没有开始这次发送，请再试一次。"
        }
    }
}

enum HomeSubmissionWatchdogPolicy {
    static func state(intentEntered: Bool, hasAttachments: Bool) -> HomeSubmissionWatchdogState {
        guard intentEntered else { return .systemDidNotStart }
        return hasAttachments ? .uploadingAttachments : .submitting
    }
}


struct HomeView: View {
    let runtimeStore: RuntimeTaskStore

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.flowerollThemePalette) private var themePalette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("floweroll.homeSeenTerminalTaskIDs") private var seenTerminalTaskIDsJSON = "[]"
    @AppStorage("floweroll.homeComposerDraftText") private var composerText = ""
    @AppStorage("floweroll.homePendingSubmissionID") private var persistedHomeSubmissionID = ""
    @State private var attachmentDraft = TaskAttachmentDraft()
    @State private var attachmentTurnID = UUID().uuidString
    @State private var isRecording = false
    @State private var isHoldingForVoice = false
    @State private var isInputPressActive = false
    @State private var inputPressToken: UUID?
    @State private var inputPressBeganFocused = false
    @State private var inputPressMovedTooFar = false
    @State private var voiceReadyHaptic: UIImpactFeedbackGenerator?
    @State private var recordingRequestID: UUID?
    @State private var activeSpeechSessionID: UUID?
    @State private var activeSpeechBaseText = ""
    @State private var liveSpeechFinalizedText = ""
    @State private var liveSpeechVolatileText = ""
    @State private var isFinalizingSpeechForSend = false
    @State private var activeHomeIntentSubmissionID: String?
    @State private var enteredHomeIntentSubmissionID: String?
    @State private var executionCancellationTask: Task<Void, Never>?
    @State private var composerMessage: String?
    @State private var composerError: String?
    @State private var micError: String?
    @State private var focusedTaskID: String?
    @State private var homeClock = Date()
    @State private var isResultBacklogExpanded = false
    @State private var isResultInboxCollapsed = true
    @State private var inboxScrollRevision = 0
    @State private var latestScrollRevision = 0
    @State private var threadScrollRevision = 0
    @State private var scrollOwnership = HomeScrollOwnershipState()
    @State private var composerBarHeight: CGFloat = 56
    @State private var idleMascotFrame: CGRect = .zero
    @State private var idleGaze = HomeIdleGazeVector.neutral
    @State private var observationPrototypePresented = false
    @State private var observationSession = ObservationController.shared
    @State private var sharedObservationVoiceID: UUID?
    @GestureState private var idleGazeGestureActive = false
    @FocusState private var composerFocused: Bool

    private var homeThreadTasks: [HostTaskIndexItem] {
        runtimeStore.homeThreadTasks
    }

    private var focusedActiveTask: HostTaskIndexItem? {
        if runtimeStore.isAwaitingNewHomeThread { return nil }
        guard let threadID = runtimeStore.currentHomeThreadID else { return nil }
        if let focusedTaskID,
           let match = runtimeStore.activeTasks.first(where: {
               $0.taskID == focusedTaskID && $0.threadID == threadID
           }) {
            return match
        }
        return runtimeStore.activeHomeThreadTask
    }

    private var focusedRoutingTask: HostTaskIndexItem? {
        if runtimeStore.isAwaitingNewHomeThread { return nil }
        if let focusedActiveTask { return focusedActiveTask }
        guard runtimeStore.currentHomeThreadID != nil else { return nil }
        return runtimeStore.latestHomeThreadTask
    }

    private var focusedExecutingTask: HostTaskIndexItem? {
        guard let focusedActiveTask else { return nil }
        let cachedView = runtimeStore.cachedTaskView(taskID: focusedActiveTask.taskID)
        guard let truth = runtimeStore.presentationTruth(
                  taskID: focusedActiveTask.taskID,
                  view: cachedView
              ),
              HomeComposerExecutionStopPolicy.shouldOfferStop(
                  for: truth.state
              )
        else { return nil }
        return focusedActiveTask
    }

    /// Terminal Inbox membership has exactly one local truth: reversible review
    /// metadata. Completion-attention seen/consumed state is intentionally not
    /// consulted here. The current Home Thread stays pending too until its
    /// terminal result/detail actually satisfies the bounded visibility gate.
    private var pendingInboxResultTasks: [HostTaskIndexItem] {
        RuntimeTerminalReviewPolicy.pendingReviewTasks(
            terminalTasks: runtimeStore.historyTasks,
            reviewedTaskIDs: runtimeStore.terminalReviewState.reviewedTaskIDs
        )
    }

    /// Section membership and row presentation share canonical presentation
    /// truth, so a needs-user Task can never sit under one heading while its
    /// row independently renders running semantics.
    private var otherInboxNeedsUserTasks: [HostTaskIndexItem] {
        latestOtherThreadTasks(
            runtimeStore.activeTasks.filter {
                HomeInboxTaskPresentationPolicy.section(for: $0) == .needsUser
            }
        )
    }

    private var otherInboxRunningTasks: [HostTaskIndexItem] {
        latestOtherThreadTasks(
            runtimeStore.activeTasks.filter {
                HomeInboxTaskPresentationPolicy.section(for: $0) == .running
            }
        )
    }

    private func latestOtherThreadTasks(_ tasks: [HostTaskIndexItem]) -> [HostTaskIndexItem] {
        let currentThreadID = runtimeStore.currentHomeThreadID
        var latestByThread: [String: HostTaskIndexItem] = [:]
        for task in tasks where task.threadID != currentThreadID {
            if let existing = latestByThread[task.threadID], existing.updatedAt >= task.updatedAt { continue }
            latestByThread[task.threadID] = task
        }
        return latestByThread.values.sorted { lhs, rhs in
            lhs.updatedAt == rhs.updatedAt ? lhs.taskID > rhs.taskID : lhs.updatedAt > rhs.updatedAt
        }
    }

    private var inboxTaskCount: Int {
        otherInboxNeedsUserTasks.count + otherInboxRunningTasks.count + pendingInboxResultTasks.count
    }

    private var latestHomeThreadTask: HostTaskIndexItem? {
        runtimeStore.latestHomeThreadTask
    }

    private var latestHomeThreadIsTerminal: Bool {
        guard let latestHomeThreadTask else { return false }
        return RuntimeTaskStore.isTerminalStatus(latestHomeThreadTask.status)
    }

    private var seenTerminalTaskIDs: Set<String> {
        guard let data = seenTerminalTaskIDsJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Set<String>.self, from: data)
        else { return [] }
        return decoded
    }

    private var hasComposerDraftContent: Bool {
        !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachmentDraft.items.isEmpty
            || attachmentDraft.isLoading
    }

    private var usesFixedIdleCanvas: Bool {
        HomeEmptyStagePresentationPolicy.showsIdleMascot(
            composerFocused: composerFocused,
            hasTextDraft: !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            attachmentCount: attachmentDraft.items.count,
            attachmentLoading: attachmentDraft.isLoading
        ) && HomeIdleCanvasPolicy.isFixedCanvas(
            hasHomeThreadContent: !homeThreadTasks.isEmpty,
            hasHomePresentationSelection: runtimeStore.hasHomePresentationSelection,
            hasVisibleResultSurface: !isResultInboxCollapsed,
            isRecording: isRecording
        )
    }

    private var idleGazeDragGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("home-idle-canvas"))
            .updating($idleGazeGestureActive) { _, isActive, _ in
                isActive = true
            }
            .onChanged { value in
                updateIdleGaze(fingerLocation: value.location)
            }
    }

    private var canSendComposer: Bool {
        if activeHomeIntentSubmissionID != nil { return false }
        return !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !runtimeStore.isSubmitting
            && !isFinalizingSpeechForSend
            && !attachmentDraft.isLoading
            && !(recordingRequestID != nil && !isRecording)
    }

    private var canUseComposerPrimaryAction: Bool {
        if activeHomeIntentSubmissionID != nil { return false }
        if executionCancellationTask != nil { return false }
        if runtimeStore.isSubmitting || isFinalizingSpeechForSend { return false }
        if focusedExecutingTask != nil { return true }
        return canSendComposer
    }

    private var shouldUseHomeInAppIntentButton: Bool {
        activeHomeIntentSubmissionID == nil
            && executionCancellationTask == nil
            && focusedExecutingTask == nil
            && !isRecording
            && recordingRequestID == nil
            && canSendComposer
    }

    private var homeInAppIntent: HomeHouTaskIntent {
        HomeHouTaskIntent(
            text: composerText.trimmingCharacters(in: .whitespacesAndNewlines),
            submissionID: attachmentTurnID,
            attachments: attachmentDraft.items
        )
    }

    @ViewBuilder
    private var composerPrimaryActionButton: some View {
        if shouldUseHomeInAppIntentButton {
            Button(intent: homeInAppIntent) {
                composerPrimaryActionLabel
            }
            .simultaneousGesture(
                TapGesture().onEnded { beginHomeInAppIntentRequest() }
            )
        } else {
            Button {
                sendComposer()
            } label: {
                composerPrimaryActionLabel
            }
        }
    }

    private var composerPrimaryActionLabel: some View {
        Group {
            if activeHomeIntentSubmissionID != nil
                || executionCancellationTask != nil
                || runtimeStore.isSubmitting
                || isFinalizingSpeechForSend {
                ProgressView()
                    .tint(.white)
            } else if focusedExecutingTask != nil {
                Image(systemName: "stop.fill")
                    .font(.system(size: 13, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
            } else {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
            }
        }
        .frame(width: 38, height: 38)
        .foregroundStyle(
            canUseComposerPrimaryAction ? themePalette.onStrongAccent : Color.secondary
        )
        .background(
            canUseComposerPrimaryAction ? themePalette.strongAccent : Color.secondary.opacity(0.08),
            in: Circle()
        )
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            GeometryReader { proxy in
                if usesFixedIdleCanvas {
                    ScrollView(.vertical) {
                        fixedIdleCanvas(proxy: proxy)
                    }
                    .scrollIndicators(.hidden)
                    .scrollDismissesKeyboard(.interactively)
                    .refreshable {
                        await refreshHomeStatus()
                    }
                    .accessibilityIdentifier("home.idle-refresh-scroll")
                } else {
                    ScrollViewReader { scrollProxy in
                    ScrollView {
                        let pendingResults = pendingInboxResultTasks
                        let needsUserInboxTasks = otherInboxNeedsUserTasks
                        let runningInboxTasks = otherInboxRunningTasks
                        VStack(alignment: .leading, spacing: 24) {
                            Color.clear
                                .frame(height: 1)
                                .id("home-result-inbox")

                            if !pendingResults.isEmpty || !needsUserInboxTasks.isEmpty || !runningInboxTasks.isEmpty || !isResultInboxCollapsed {
                                HomeResultInboxView(
                                    needsUserTasks: needsUserInboxTasks,
                                    runningTasks: runningInboxTasks,
                                    resultTasks: pendingResults,
                                    store: runtimeStore,
                                    isExpanded: $isResultBacklogExpanded,
                                    isCollapsed: $isResultInboxCollapsed,
                                    ageLabel: { resultAgeLabel(hostDate($0.updatedAt)) },
                                    onBringToHome: { task in
                                        focusedTaskID = task.taskID
                                        isResultInboxCollapsed = true
                                        isResultBacklogExpanded = false
                                        latestScrollRevision &+= 1
                                    },
                                    onAcknowledgeAll: {
                                        runtimeStore.terminalReviewState.markReviewed(
                                            taskIDs: pendingResults.map(\.taskID)
                                        )
                                        isResultInboxCollapsed = true
                                    }
                                )
                                .padding(.top, 34)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }

                            if !homeThreadTasks.isEmpty {
                                HomeThreadStage(
                                    tasks: homeThreadTasks,
                                    store: runtimeStore,
                                    onSeenThread: markCurrentHomeThreadSeen,
                                    onTimelineChange: { threadScrollRevision &+= 1 }
                                )
                                .padding(.top, pendingResults.isEmpty && needsUserInboxTasks.isEmpty && runningInboxTasks.isEmpty ? 46 : 6)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))

                            } else if runtimeStore.hasHomePresentationSelection {
                                Spacer(minLength: 58)

                                HomeThreadRecoveryStage()
                                    .frame(maxWidth: .infinity)
                                    .transition(.opacity)

                                Spacer(minLength: 150)

                            } else if (pendingResults.isEmpty && needsUserInboxTasks.isEmpty && runningInboxTasks.isEmpty) || isResultInboxCollapsed {
                                Spacer(minLength: 58)

                                HomeIdleStage(
                                    state: isRecording ? .listening : .idle,
                                    gaze: idleGaze,
                                    onMascotFrameChange: { idleMascotFrame = $0 }
                                )
                                .frame(maxWidth: .infinity)

                                Spacer(minLength: 150)
                            } else {
                                Spacer(minLength: 120)
                            }

                            Color.clear
                                .frame(height: 1)
                                .id("home-thread-bottom")
                        }
                        .frame(
                            maxWidth: .infinity,
                            minHeight: max(1, proxy.size.height - 86),
                            alignment: .top
                        )
                        .padding(.horizontal, 20)
                        .padding(.top, 24)
                        .padding(.bottom, 24)
                    }
                    .id(runtimeStore.currentHomeThreadID ?? "home-new-thread")
                    .coordinateSpace(name: "home-idle-canvas")
                    .defaultScrollAnchor(.bottom, for: .initialOffset)
                    .defaultScrollAnchor(
                        scrollOwnership.shouldAutoFollowLiveUpdates ? .bottom : nil,
                        for: .sizeChanges
                    )
                    .accessibilityIdentifier("home.timeline-scroll")
                    .scrollDismissesKeyboard(.interactively)
                    .refreshable {
                        await refreshHomeStatus()
                    }
                    .onScrollGeometryChange(for: HomeScrollViewportState.self) { geometry in
                        HomeScrollViewportState.resolve(
                            contentHeight: Double(geometry.contentSize.height),
                            viewportHeight: Double(geometry.visibleRect.height),
                            distanceFromLatest: Double(
                                max(0, geometry.contentSize.height - geometry.visibleRect.maxY)
                            )
                        )
                    } action: { _, viewport in
                        scrollOwnership.updateViewport(viewport)
                    }
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            if composerFocused {
                                composerFocused = false
                            }
                        }
                    )
                    .onScrollPhaseChange { _, phase in
                        switch phase {
                        case .tracking, .interacting:
                            scrollOwnership.userBeganBrowsingHistory()
                        case .idle:
                            scrollOwnership.userEndedBrowsingGesture()
                        case .decelerating, .animating:
                            break
                        }
                    }
                    .onChange(of: threadScrollRevision) { _, _ in
                        guard scrollOwnership.shouldAutoFollowLiveUpdates else { return }
                        withAnimation(.easeOut(duration: 0.22)) {
                            scrollProxy.scrollTo("home-thread-bottom", anchor: .bottom)
                        }
                    }
                    .onChange(of: inboxScrollRevision) { _, _ in
                        withAnimation(.easeOut(duration: 0.22)) {
                            scrollProxy.scrollTo("home-result-inbox", anchor: .top)
                        }
                    }
                    .onChange(of: latestScrollRevision) { _, _ in
                        withAnimation(.easeOut(duration: 0.22)) {
                            scrollProxy.scrollTo("home-thread-bottom", anchor: .bottom)
                        }
                    }
                    .onChange(of: homeThreadTasks.map { "\($0.taskID):\($0.updatedAt)" }) { _, _ in
                        guard scrollOwnership.shouldAutoFollowLiveUpdates else { return }
                        withAnimation(.easeOut(duration: 0.22)) {
                            scrollProxy.scrollTo("home-thread-bottom", anchor: .bottom)
                        }
                    }
                }
                }
            }
        }
        .accessibilityIdentifier("home.root")
        .overlay(alignment: .topLeading) {
            HStack(spacing: 8) {
                if runtimeStore.hasHomePresentationSelection {
                    Button {
                        if composerError != nil {
                            // Starting over after a failed send is an explicit
                            // discard of that persisted submission, not a visual
                            // reset that lets the old outbox entry revive later.
                            discardCurrentSubmission()
                        } else {
                            composerMessage = nil
                            composerError = nil
                        }
                        runtimeStore.beginNewHomeThread()
                        focusedTaskID = nil
                        threadScrollRevision &+= 1
                    } label: {
                        Label("新任务", systemImage: "plus")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 13)
                            .frame(height: 38)
                            .background(.regularMaterial, in: Capsule())
                            .overlay {
                                Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.6)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("新任务")
                    .accessibilityHint("收起当前首页工作流并开始一件新的事情，不会删除历史或取消后台任务")
                }

                Button {
                    composerFocused = false
                    observationPrototypePresented = true
                } label: {
                    Label(
                        observationSession.homeTitle,
                        systemImage: "sparkles"
                    )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(observationSession.isCapturing ? themePalette.strongAccent : Color.primary)
                        .padding(.horizontal, 13)
                        .frame(height: 38)
                        .background(.regularMaterial, in: Capsule())
                        .overlay {
                            Capsule().stroke(
                                observationSession.isCapturing
                                    ? themePalette.accent.opacity(0.38)
                                    : Color.primary.opacity(0.08),
                                lineWidth: 0.7
                            )
                        }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.observation")
                .accessibilityLabel(observationSession.homeTitle)
                .accessibilityHint(observationSession.isCapturing ? "返回当前观察状态" : "打开花卷的观察模式")
            }
            .padding(.top, 10)
            .padding(.leading, 18)
        }
        .overlay(alignment: .topTrailing) {
            HomeResultInboxControl(
                count: inboxTaskCount,
                isCollapsed: $isResultInboxCollapsed,
                onOpen: {
                    scrollOwnership.openInbox()
                    inboxScrollRevision &+= 1
                }
            )
            .padding(.top, 10)
            .padding(.trailing, 18)
        }
        .overlay(alignment: .bottom) {
            if scrollOwnership.showsReturnToLatest, !homeThreadTasks.isEmpty {
                HomeReturnToLatestButton {
                    scrollOwnership.returnToLatest()
                    latestScrollRevision &+= 1
                }
                .padding(.bottom, max(8, composerBarHeight - 26))
                .offset(y: 20)
                .transition(.asymmetric(
                    insertion: .offset(y: 18)
                        .combined(with: .scale(scale: 0.82))
                        .combined(with: .opacity),
                    removal: .offset(y: 16)
                        .combined(with: .scale(scale: 0.82))
                        .combined(with: .opacity)
                ))
                .zIndex(3)
            }
        }
        .animation(
            .spring(response: 0.28, dampingFraction: 0.78),
            value: scrollOwnership.showsReturnToLatest
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composerBar
                .padding(.horizontal, 12)
                .padding(.top, 5)
                .padding(.bottom, 7)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    composerBarHeight = max(44, height)
                }
        }
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(isPresented: $observationPrototypePresented) {
            ObservationView(controller: observationSession, endpoint: runtimeStore.configuredEndpoint)
        }
        .onAppear {
            scrollOwnership.beginGeneration(runtimeStore.currentHomeThreadID)
            ensureFocusedTask()
            runtimeStore.preuploadAttachments(attachmentDraft.items)
            Task { @MainActor in
                await restorePendingHomeSubmissionIdentity()
            }
            if AVAudioApplication.shared.recordPermission == .granted {
                Task { @MainActor in
                    try? await AudioCaptureService.shared.prepare()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: HomeInAppIntentEvents.notification)) { notification in
            handleHomeInAppIntentEvent(notification)
        }
        .onChange(of: runtimeStore.activeTasks.map(\.taskID)) { _, _ in
            ensureFocusedTask()
        }
        .onChange(of: idleGazeGestureActive) { wasActive, isActive in
            if wasActive && !isActive {
                returnIdleGazeToNeutral()
            }
        }
        .onChange(of: usesFixedIdleCanvas) { _, isFixed in
            if !isFixed {
                returnIdleGazeToNeutral()
            }
        }
        .onChange(of: runtimeStore.historyTasks.map { "\($0.taskID):\($0.status):\($0.updatedAt)" }) { _, _ in
            homeClock = Date()
        }
        .onChange(of: runtimeStore.currentHomeThreadID) { _, newThreadID in
            scrollOwnership.beginGeneration(newThreadID)
            latestScrollRevision &+= 1
        }
        .onChange(of: (pendingInboxResultTasks + otherInboxNeedsUserTasks + otherInboxRunningTasks).map(\.taskID)) { _, newValue in
            if newValue.isEmpty {
                isResultInboxCollapsed = true
                isResultBacklogExpanded = false
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            homeClock = Date()
            runtimeStore.preuploadAttachments(attachmentDraft.items)
            Task { @MainActor in
                await restorePendingHomeSubmissionIdentity()
                await runtimeStore.refreshCurrentHomeThreadFast()
            }
        }
        .onDisappear {
            isInputPressActive = false
            inputPressToken = nil
            inputPressBeganFocused = false
            inputPressMovedTooFar = false
            isHoldingForVoice = false
            voiceReadyHaptic = nil
            if isRecording || recordingRequestID != nil {
                stopRecording(showMessage: false)
            }
        }
        .animation(.spring(response: 0.48, dampingFraction: 0.9), value: focusedTaskID)
    }

    private var composerBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !attachmentDraft.items.isEmpty || attachmentDraft.isLoading {
                TaskAttachmentBar(
                    draft: attachmentDraft,
                    states: runtimeStore.attachmentUploadStates,
                    disabled: runtimeStore.isSubmitting || isRecording || activeHomeIntentSubmissionID != nil,
                    onRemove: { item in
                        runtimeStore.cancelAttachmentPreupload(attachmentID: item.id)
                    }
                )
            }
            if isRecording, focusedActiveTask != nil {
                HStack(spacing: 8) {
                    Spacer()
                    RootTabAwareFlowerollPresentationView(
                        state: .listening,
                        compact: true
                    )
                        .frame(width: 46, height: 46)
                    Text("正在听")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }

            if let note = composerError ?? micError ?? composerMessage {
                HStack(spacing: 6) {
                    Image(systemName: composerError != nil || micError != nil ? "exclamationmark.circle" : "checkmark.circle")
                    Text(note)
                        .lineLimit(2)
                    if composerError != nil {
                        Button("丢弃这次发送") { discardCurrentSubmission() }
                            .buttonStyle(.plain)
                            .font(.caption2.weight(.semibold))
                    }
                }
                .font(.caption2)
                .foregroundStyle(composerError != nil || micError != nil ? Color.orange : Color.secondary)
                .padding(.horizontal, 10)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if hasComposerDraftContent {
                Label(attachmentDraft.isLoading ? "正在保存附件草稿…" : "草稿已保存", systemImage: "checkmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .accessibilityIdentifier("home.composer-draft-status")
            }

            HStack(alignment: .bottom, spacing: 7) {
                TaskAttachmentMenuButton(
                    draft: attachmentDraft,
                    disabled: runtimeStore.isSubmitting || isRecording || activeHomeIntentSubmissionID != nil,
                    onAttachmentReady: { attachment in
                        runtimeStore.preuploadAttachment(attachment)
                    }
                )

                ZStack(alignment: .leading) {
                    TextField(
                        isRecording
                            ? "正在听…"
                            : (recordingRequestID != nil
                                ? "正在准备语音识别…"
                                : "输入新任务，或控制当前任务 · 按住说话"),
                        text: $composerText,
                        axis: .vertical
                    )
                    .focused($composerFocused)
                    .font(.body)
                    .lineLimit(1...6)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 6)
                    .frame(minHeight: 38, alignment: .bottomLeading)
                    .opacity(isRecording ? 0.001 : 1)
                    .disabled(isRecording || activeHomeIntentSubmissionID != nil)
                    .submitLabel(.send)
                    .onSubmit {
                        // SwiftUI exposes a system AppIntent Button, but no
                        // equivalent public API for programmatically "pressing"
                        // that button from TextField.onSubmit. Keep Return from
                        // bypassing the durable in-app submission path.
                        composerFocused = false
                        composerMessage = "请点发送按钮交给小卷。"
                    }

                    if isRecording {
                        LiveSpeechTranscriptView(
                            base: activeSpeechBaseText,
                            finalized: liveSpeechFinalizedText,
                            volatile: liveSpeechVolatileText
                        )
                        .padding(.horizontal, 13)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                    }

                }
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                .contentShape(Rectangle())
                .background(
                    isRecording ? themePalette.accent.opacity(0.055) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .overlay {
                    if isRecording {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(themePalette.accent.opacity(0.22), lineWidth: 0.7)
                    }
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            updateInputPress(value)
                        }
                        .onEnded { _ in
                            endInputPress()
                        }
                )
                .animation(.easeInOut(duration: 0.18), value: isRecording)
                .accessibilityIdentifier("task-composer-input")
                .accessibilityLabel("任务输入")
                .accessibilityHint("轻点输入文字，按住开始语音")

                Button {
                    if isRecording || recordingRequestID != nil {
                        stopRecording()
                    } else {
                        startRecording()
                    }
                } label: {
                    Group {
                        if recordingRequestID != nil && !isRecording {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(isRecording ? Color.red : Color.primary)
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    .frame(width: 38, height: 38)
                    .background(
                        isRecording ? Color.red.opacity(0.12) : Color.secondary.opacity(0.08),
                        in: Circle()
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isRecording ? "停止录音" : "开始录音")

                composerPrimaryActionButton
                    .buttonStyle(.plain)
                    .disabled(!canUseComposerPrimaryAction)
                    .accessibilityIdentifier("task-composer-send")
                    .accessibilityLabel(
                        activeHomeIntentSubmissionID != nil
                            ? "正在交给小卷"
                            : (executionCancellationTask != nil
                                ? "正在停止当前任务"
                                : (focusedExecutingTask != nil
                                    ? "停止当前任务"
                                    : "发送新任务或控制当前任务"))
                    )
            }
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.primary.opacity(0.07), lineWidth: 0.6) }
            .shadow(color: .black.opacity(0.045), radius: 12, y: 5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 7)
        .padding(.horizontal, 2)
        .background(Color(uiColor: .systemBackground))
        .zIndex(20)
        .animation(.spring(response: 0.38, dampingFraction: 0.9), value: composerText.isEmpty)
        .animation(.easeInOut(duration: 0.18), value: isRecording)
    }

    @MainActor
    private func refreshHomeStatus() async {
        await runtimeStore.refreshHomeStatusReadModel()
        runtimeStore.reconcileCompletionAttention()
        homeClock = Date()
        ensureFocusedTask()
    }


    @ViewBuilder
    private func fixedIdleCanvas(proxy: GeometryProxy) -> some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .simultaneousGesture(idleGazeDragGesture)

            VStack(alignment: .leading, spacing: 24) {
                Color.clear
                    .frame(height: 1)

                Spacer(minLength: 58)

                HomeIdleStage(
                    state: .idle,
                    gaze: idleGaze,
                    onMascotFrameChange: { idleMascotFrame = $0 }
                )
                .frame(maxWidth: .infinity)

                Spacer(minLength: 150)

                Color.clear
                    .frame(height: 1)
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: max(1, proxy.size.height - 86),
            alignment: .top
        )
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 24)
        .coordinateSpace(name: "home-idle-canvas")
        .simultaneousGesture(
            TapGesture().onEnded {
                if composerFocused {
                    composerFocused = false
                }
            }
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.idle-fixed-canvas")
    }

    private func updateIdleGaze(fingerLocation: CGPoint) {
        guard idleMascotFrame.width > 0, idleMascotFrame.height > 0 else { return }
        idleGaze = HomeIdleGazePolicy.resolve(
            fingerX: Double(fingerLocation.x),
            fingerY: Double(fingerLocation.y),
            mascotCenterX: Double(idleMascotFrame.midX),
            mascotCenterY: Double(idleMascotFrame.midY)
        )
    }

    private func returnIdleGazeToNeutral() {
        guard idleGaze != .neutral else { return }
        withAnimation(reduceMotion ? .linear(duration: 0.05) : .easeOut(duration: 0.14)) {
            idleGaze = .neutral
        }
    }

    private func markCurrentHomeThreadSeen() {
        markTerminalTasksSeen(
            homeThreadTasks
                .filter { RuntimeTaskStore.isTerminalStatus($0.status) }
                .map(\.taskID)
        )
    }

    private func markTerminalTasksSeen(_ taskIDs: [String]) {
        guard !taskIDs.isEmpty else { return }
        var seen = seenTerminalTaskIDs
        let before = seen
        seen.formUnion(taskIDs)

        let knownHistoryIDs = Set(runtimeStore.historyTasks.map(\.taskID))
        seen = seen.intersection(knownHistoryIDs).union(taskIDs)
        guard seen != before,
              let data = try? JSONEncoder().encode(seen),
              let value = String(data: data, encoding: .utf8)
        else { return }
        seenTerminalTaskIDsJSON = value
    }

    private func hostDate(_ rawValue: String) -> Date? {
        RuntimeTaskStore.hostDate(rawValue)
    }

    private func resultAgeLabel(_ completedAt: Date?) -> String {
        guard let completedAt else { return "已结束" }
        let seconds = max(0, homeClock.timeIntervalSince(completedAt))
        if seconds < 60 { return "刚刚结束" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) 分钟前" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) 小时前" }
        return "\(hours / 24) 天前"
    }

    private func ensureFocusedTask() {
        let active = runtimeStore.activeTasks

        if runtimeStore.isAwaitingNewHomeThread {
            focusedTaskID = nil
            return
        }

        guard let threadID = runtimeStore.currentHomeThreadID else {
            focusedTaskID = nil
            return
        }

        let threadActive = active.filter { $0.threadID == threadID }
        if let focusedTaskID,
           threadActive.contains(where: { $0.taskID == focusedTaskID }) {
            return
        }
        focusedTaskID = runtimeStore.activeHomeThreadTask?.taskID ?? threadActive.first?.taskID
    }

    private func updateInputPress(_ value: DragGesture.Value) {
        if !isInputPressActive {
            beginInputPressIfNeeded()
        }
        guard isInputPressActive, !isHoldingForVoice else { return }

        let distance = hypot(value.translation.width, value.translation.height)
        if distance > 24 {
            inputPressMovedTooFar = true
            inputPressToken = nil
            voiceReadyHaptic = nil
        }
    }

    private func beginInputPressIfNeeded() {
        guard !isInputPressActive else { return }
        guard !isRecording, recordingRequestID == nil, !isFinalizingSpeechForSend else { return }

        isInputPressActive = true
        inputPressBeganFocused = composerFocused
        inputPressMovedTooFar = false
        let token = UUID()
        inputPressToken = token
        let haptic = UIImpactFeedbackGenerator(style: .light)
        haptic.prepare()
        voiceReadyHaptic = haptic

        // Warm the analyzer on touch-down without opening the microphone. A short
        // tap simply enters text mode; a stationary hold crosses into voice mode.
        Task { @MainActor in
            try? await AudioCaptureService.shared.prepare()
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard isInputPressActive,
                  inputPressToken == token,
                  !inputPressMovedTooFar else { return }
            guard !isRecording, recordingRequestID == nil else { return }

            // Only now is voice intent confirmed. If the keyboard was already up,
            // dismiss it before activating the recording session.
            composerFocused = false
            isHoldingForVoice = true
            startRecording(feedbackWhenReady: true)
        }
    }

    private func endInputPress() {
        guard isInputPressActive else { return }
        let beganFocused = inputPressBeganFocused
        let movedTooFar = inputPressMovedTooFar
        isInputPressActive = false
        inputPressToken = nil
        inputPressBeganFocused = false
        inputPressMovedTooFar = false

        if isHoldingForVoice {
            isHoldingForVoice = false
            if isRecording || recordingRequestID != nil {
                stopRecording()
            }
            return
        }

        voiceReadyHaptic = nil
        // A genuine short tap enters text mode only after the finger lifts, so a
        // long hold never flashes the keyboard before voice mode wins arbitration.
        if !beganFocused, !movedTooFar, recordingRequestID == nil {
            Task { @MainActor in
                composerFocused = true
            }
        }
    }

    private func startRecording(feedbackWhenReady: Bool = false) {
        composerFocused = false
        let requestID = UUID()
        let baseComposerText = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        recordingRequestID = requestID
        activeSpeechSessionID = requestID
        activeSpeechBaseText = baseComposerText
        liveSpeechFinalizedText = ""
        liveSpeechVolatileText = ""

        // A normal voice command leases observation's already-authorized mic.
        if observationSession.canShareVoiceInput {
            sharedObservationVoiceID = observationSession.beginSharedVoiceInput { update in
                guard activeSpeechSessionID == requestID else { return }
                liveSpeechFinalizedText = update.finalized
                liveSpeechVolatileText = update.volatile
                composerText = Self.mergeSpeechTranscript(base: baseComposerText, transcript: update.combined)
            }
            if sharedObservationVoiceID != nil {
                micError = nil; composerError = nil; composerMessage = nil
                isRecording = true
                if feedbackWhenReady {
                    (voiceReadyHaptic ?? UIImpactFeedbackGenerator(style: .light)).impactOccurred(intensity: 0.9)
                    voiceReadyHaptic = nil
                }
                return
            }
        }

        Task { @MainActor in
            micError = nil
            composerError = nil
            composerMessage = "正在准备本机语音识别…"

            if AVAudioApplication.shared.recordPermission == .undetermined {
                let granted = await AVAudioApplication.requestRecordPermission()
                guard granted else {
                    if recordingRequestID == requestID {
                        recordingRequestID = nil
                        micError = "没有麦克风权限，可以继续使用文字输入。"
                    }
                    return
                }
            }

            guard recordingRequestID == requestID else { return }
            guard AVAudioApplication.shared.recordPermission == .granted else {
                recordingRequestID = nil
                micError = "麦克风权限未允许，可以继续使用文字输入。"
                return
            }

            do {
                try await AudioCaptureService.shared.start(preservePlayback: observationSession.isCapturing) { update in
                    guard activeSpeechSessionID == requestID else { return }
                    liveSpeechFinalizedText = update.finalized
                    if liveSpeechVolatileText != update.volatile {
                        withAnimation(.easeOut(duration: 0.16)) {
                            liveSpeechVolatileText = update.volatile
                        }
                    }
                    composerText = Self.mergeSpeechTranscript(
                        base: baseComposerText,
                        transcript: update.combined
                    )
                }
                guard recordingRequestID == requestID else {
                    AudioCaptureService.shared.stop()
                    return
                }
                composerMessage = nil
                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                    isRecording = true
                }
                if feedbackWhenReady {
                    let haptic = voiceReadyHaptic ?? UIImpactFeedbackGenerator(style: .light)
                    haptic.impactOccurred(intensity: 0.9)
                    voiceReadyHaptic = nil
                }
            } catch {
                if recordingRequestID == requestID {
                    recordingRequestID = nil
                    micError = error.localizedDescription
                }
                if activeSpeechSessionID == requestID {
                    activeSpeechSessionID = nil
                    activeSpeechBaseText = ""
                    liveSpeechFinalizedText = ""
                    liveSpeechVolatileText = ""
                }
            }
        }
    }

    private func stopRecording(showMessage: Bool = true) {
        let hadRequest = recordingRequestID != nil || isRecording
        recordingRequestID = nil
        withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
            isRecording = false
        }
        if hadRequest, showMessage {
            micError = nil
            composerMessage = "正在收尾转写…"
        }
        let sessionID = activeSpeechSessionID
        let baseText = activeSpeechBaseText
        let finish: (String) -> Void = { finalTranscript in
            guard activeSpeechSessionID == sessionID else {
                isFinalizingSpeechForSend = false
                return
            }
            if !finalTranscript.isEmpty {
                composerText = Self.mergeSpeechTranscript(base: baseText, transcript: finalTranscript)
            }
            activeSpeechSessionID = nil
            activeSpeechBaseText = ""
            liveSpeechFinalizedText = ""
            liveSpeechVolatileText = ""

            if hadRequest, showMessage {
                composerMessage = composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "没有识别到语音，可以再试一次。"
                    : "转写已完成，可以修改后发送。"
            }

            if !observationSession.canShareVoiceInput {
                Task { @MainActor in try? await AudioCaptureService.shared.prepare() }
            }
        }
        if let sharedID = sharedObservationVoiceID {
            sharedObservationVoiceID = nil
            finish(observationSession.endSharedVoiceInput(sharedID))
        } else {
            AudioCaptureService.shared.stop(onFinalized: finish)
        }
    }

    private static func mergeSpeechTranscript(base: String, transcript: String) -> String {
        guard !base.isEmpty else { return transcript }
        guard !transcript.isEmpty else { return base }
        let needsSpace = base.last?.isASCII == true && transcript.first?.isASCII == true
        return base + (needsSpace ? " " : "") + transcript
    }

    @MainActor
    private func restorePendingHomeSubmissionIdentity() async {
        guard activeHomeIntentSubmissionID == nil else { return }
        let normalized = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            persistedHomeSubmissionID = ""
            return
        }

        var pending: PendingSubmission?
        if !persistedHomeSubmissionID.isEmpty {
            let durableSubmissionID = persistedHomeSubmissionID
            pending = await runtimeStore.pendingSubmission(submissionID: durableSubmissionID)
            if pending == nil,
               let admitted = await runtimeStore.admittedTaskForSubmissionID(durableSubmissionID) {
                // Bootstrap can win the race and consume the outbox before Home
                // receives an in-process AppIntent callback. Reconcile the exact
                // durable submission instead of leaving stale text that could be
                // sent again as a brand-new Task.
                let attachmentIDs = Set(attachmentDraft.items.map(\.id))
                composerText = ""
                attachmentDraft.clearSubmitted(attachmentIDs)
                runtimeStore.clearAttachmentUploadStates(attachmentIDs)
                focusedTaskID = admitted.taskID
                attachmentTurnID = UUID().uuidString
                persistedHomeSubmissionID = ""
                composerError = nil
                composerMessage = "已经交给小卷。"
                return
            }
            if pending == nil {
                // The exact id is still the only retry identity even if neither
                // local journal nor Host readback is currently reachable.
                attachmentTurnID = durableSubmissionID
                composerError = nil
                composerMessage = "这次发送尚未确认；再次发送会继续同一次任务。"
                return
            }
        }
        if pending == nil, persistedHomeSubmissionID.isEmpty {
            // One-time compatibility for sends created by builds before the
            // durable Home identity key existed. Selection only: never merge or
            // delete independent submissions with identical content.
            pending = await runtimeStore.pendingHomeSubmission(
                matching: normalized,
                attachments: attachmentDraft.items
            )
            if let pending { persistedHomeSubmissionID = pending.submissionID }
        }
        guard let pending else { return }
        attachmentTurnID = pending.submissionID
        composerError = nil
        composerMessage = pending.lastErrorMessage == nil
            ? "这次发送仍在恢复；再次发送会继续同一次任务。"
            : "这次发送已安全保留；再次发送会继续同一次任务。"
    }

    private func beginHomeInAppIntentRequest() {
        guard activeHomeIntentSubmissionID == nil,
              shouldUseHomeInAppIntentButton
        else { return }
        let submissionID = attachmentTurnID
        persistedHomeSubmissionID = submissionID
        activeHomeIntentSubmissionID = submissionID
        // Do not clear an already-arrived `started` event. Button(intent:) and
        // simultaneousGesture are both driven by the same tap, and their exact
        // callback ordering is not a product contract. Equality with the fresh
        // submission_id safely ignores any older send.
        composerFocused = false
        composerError = nil
        composerMessage = "正在交给小卷…"

        // Eight seconds is only a UI watchdog, never a submission-failure
        // boundary. A large attachment may legitimately remain in the
        // persist-first/background-URLSession admission path for minutes. The
        // AppIntent posts `started` as soon as perform() really begins; only a
        // missing `started` callback means the system did not launch this send.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            guard activeHomeIntentSubmissionID == submissionID else { return }
            let state = HomeSubmissionWatchdogPolicy.state(
                intentEntered: enteredHomeIntentSubmissionID == submissionID,
                hasAttachments: !attachmentDraft.items.isEmpty
            )
            switch state {
            case .submitting, .uploadingAttachments:
                composerError = nil
                composerMessage = state.message
                // Keep the exact submission_id locked until accepted/failed.
                // Re-tapping during a slow upload is neither useful nor needed.
            case .systemDidNotStart:
                activeHomeIntentSubmissionID = nil
                enteredHomeIntentSubmissionID = nil
                composerMessage = nil
                composerError = state.message
            }
        }
    }

    private func handleHomeInAppIntentEvent(_ notification: Notification) {
        guard let info = notification.userInfo,
              let submissionID = info[HomeInAppIntentEvents.submissionIDKey] as? String,
              submissionID == activeHomeIntentSubmissionID || submissionID == attachmentTurnID,
              let kind = info[HomeInAppIntentEvents.kindKey] as? String
        else { return }

        switch kind {
        case "started":
            enteredHomeIntentSubmissionID = submissionID
            composerError = nil
            composerMessage = "正在交给小卷…"

        case "accepted":
            let attachmentIDs = Set(
                (info[HomeInAppIntentEvents.attachmentIDsKey] as? [String]) ?? []
            )
            composerText = ""
            attachmentDraft.clearSubmitted(attachmentIDs)
            runtimeStore.clearAttachmentUploadStates(attachmentIDs)
            if let taskID = info[HomeInAppIntentEvents.taskIDKey] as? String {
                focusedTaskID = taskID
            }
            attachmentTurnID = UUID().uuidString
            persistedHomeSubmissionID = ""
            activeHomeIntentSubmissionID = nil
            enteredHomeIntentSubmissionID = nil
            composerError = nil
            composerMessage = (info[HomeInAppIntentEvents.joinedExistingExecutionKey] as? Bool) == true
                ? "已补充到当前任务。"
                : "已经交给小卷。"
            Task { @MainActor in
                await runtimeStore.refreshCurrentHomeThreadFast()
            }

        case "failed":
            activeHomeIntentSubmissionID = nil
            enteredHomeIntentSubmissionID = nil
            composerMessage = nil
            composerError = (info[HomeInAppIntentEvents.messageKey] as? String)
                ?? "这次发送暂时没有进入后台执行。"

        default:
            break
        }
    }

    private func sendComposer() {
        guard executionCancellationTask == nil else { return }
        if let executingTask = focusedExecutingTask {
            cancelFocusedExecutingTask(executingTask)
            return
        }

        let hasText = !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasText, !runtimeStore.isSubmitting, !isFinalizingSpeechForSend else { return }

        if isRecording {
            // Finish transcription first; the finalized draft stays visible and
            // the next tap enters the durable in-app BGCPT submission path.
            stopRecording(showMessage: false)
        }
    }

    private func cancelFocusedExecutingTask(_ task: HostTaskIndexItem) {
        guard executionCancellationTask == nil,
              focusedExecutingTask?.taskID == task.taskID
        else { return }

        let taskID = task.taskID
        composerError = nil
        composerMessage = "正在停止当前任务…"
        executionCancellationTask = Task { @MainActor in
            defer { executionCancellationTask = nil }
            do {
                let cancellation = try await runtimeStore.cancelTask(
                    taskID: taskID,
                    reason: "用户从首页停止正在执行的任务"
                )
                focusedTaskID = taskID
                composerMessage = RuntimeTaskCancellationPresentation.message(for: cancellation)
            } catch {
                composerMessage = nil
                composerError = RuntimeTaskStore.userMessage(for: error)
            }
        }
    }

    private func discardCurrentSubmission() {
        let submissionID = attachmentTurnID
        let ids = Set(attachmentDraft.items.map(\.id))
        composerText = ""
        persistedHomeSubmissionID = ""
        activeHomeIntentSubmissionID = nil
        enteredHomeIntentSubmissionID = nil
        composerError = nil
        composerMessage = nil
        attachmentDraft.discard(ids)
        runtimeStore.clearAttachmentUploadStates(ids)
        attachmentTurnID = UUID().uuidString
        Task { @MainActor in
            await runtimeStore.discardPendingSubmission(submissionID: submissionID)
        }
    }
}
