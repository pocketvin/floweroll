import Foundation
import Observation



enum FlowerollGlobalInputRoutingPolicy {
    /// Compatibility entry point for existing canonical tests/callers that have
    /// no richer Task view. New production call sites should pass the exact
    /// `FlowerollGlobalInputRoutingContext` overload below.
    static func route(
        text: String,
        currentHomeActiveTaskID: String?
    ) -> FlowerollGlobalInputRoute {
        let normalizedID = currentHomeActiveTaskID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let current = normalizedID.flatMap { id -> FlowerollGlobalInputRoutingContext.CurrentTask? in
            guard !id.isEmpty else { return nil }
            return .init(taskID: id, goal: "", pendingInteraction: nil)
        }
        return route(
            text: text,
            context: FlowerollGlobalInputRoutingContext(currentTask: current)
        )
    }

    static func route(
        text rawText: String,
        context: FlowerollGlobalInputRoutingContext
    ) -> FlowerollGlobalInputRoute {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let current = context.currentTask,
              !current.taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .newTask
        }

        // Global Home / Action Button input is new-task-by-default. A current
        // Task only captures high-confidence continuation/control or an exact
        // response to its pending interaction. Mixed input must preserve both
        // the current-task operation and the independent goal.
        if let mixed = mixedRoute(text: text, current: current) {
            return mixed
        }
        return singleRoute(text: text, current: current)
    }

    static func resolve(
        text rawText: String,
        context: FlowerollGlobalInputRoutingContext
    ) -> FlowerollGlobalInputResolution {
        var route = route(text: rawText, context: context)
        var carryover: FlowerollTaskContextCarryover?

        switch route {
        case .newTask:
            carryover = boundedNewTaskCarryover(
                text: rawText,
                route: route,
                context: context
            )

        case let .mixed(currentTaskID, currentOperation, newTaskText):
            if let mixedCarryover = boundedNewTaskCarryover(
                text: newTaskText,
                route: .newTask,
                context: context
            ) {
                route = .mixed(
                    currentTaskID: currentTaskID,
                    currentOperation: currentOperation,
                    newTaskText: mixedCarryover.materializedText
                )
            }
            carryover = nil

        case .steerCurrentTask, .answerPendingInteraction:
            carryover = nil
        }

        return FlowerollGlobalInputResolution(
            route: route,
            newTaskCarryover: carryover
        )
    }

    static func isConservativeSteeringExpression(_ rawText: String) -> Bool {
        let current = FlowerollGlobalInputRoutingContext.CurrentTask(
            taskID: "routing-probe",
            goal: "",
            pendingInteraction: nil
        )
        if case .steerCurrentTask = singleRoute(text: rawText, current: current) {
            return true
        }
        return false
    }

    // MARK: - Bounded contextual referent carryover

    private static let companyReferentMentions = [
        "这家公司", "这个公司", "该公司",
        "这家企业", "这个企业", "该企业",
        "这家单位", "这个单位",
    ]

    private static func boundedNewTaskCarryover(
        text rawText: String,
        route: FlowerollGlobalInputRoute,
        context: FlowerollGlobalInputRoutingContext
    ) -> FlowerollTaskContextCarryover? {
        guard case .newTask = route,
              let current = context.currentTask,
              current.pendingInteraction == nil,
              let source = current.referentSource,
              source.taskID == current.taskID,
              !source.taskUpdatedAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let mention = companyReferentMentions.first(where: rawText.contains)
        else {
            return nil
        }

        // An explicit company in the new utterance is authoritative. Never
        // replace it with context borrowed from the previous Task.
        guard companyCandidates(in: rawText).isEmpty else { return nil }

        let candidates = Array(Set(
            companyCandidates(in: source.brief)
                + companyCandidates(in: source.goal)
        )).sorted()
        guard candidates.count == 1, let company = candidates.first else {
            // Zero candidates means unresolved; multiple candidates mean
            // ambiguous. Both fail conservatively with no context injection.
            return nil
        }

        let materialized = rawText.replacingOccurrences(of: mention, with: company)
        guard materialized != rawText else { return nil }
        return FlowerollTaskContextCarryover(
            binding: .init(
                mention: mention,
                kind: .company,
                value: company,
                sourceTaskID: source.taskID,
                sourceTaskUpdatedAt: source.taskUpdatedAt
            ),
            materializedText: materialized
        )
    }

    private static func companyCandidates(in rawText: String) -> [String] {
        var segmented = rawText
        for separator in [
            "，", ",", "。", "；", ";", "！", "!", "？", "?", "、",
            "以及", "和", "与", "跟", "及",
        ] {
            segmented = segmented.replacingOccurrences(of: separator, with: "\n")
        }

        var candidates: [String] = []
        let organizationSuffixes = [
            "股份有限公司", "有限公司", "实验室", "研究院", "工作室",
            "集团", "证券", "银行", "科技", "公司",
        ]
        let topicCues = ["面试", "岗位", "职位", "招聘"]

        for fragment in segmented.split(separator: "\n", omittingEmptySubsequences: true) {
            let segment = String(fragment).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !segment.isEmpty else { continue }

            for suffix in organizationSuffixes {
                var searchStart = segment.startIndex
                while searchStart < segment.endIndex,
                      let range = segment.range(
                        of: suffix,
                        range: searchStart..<segment.endIndex
                      )
                {
                    let prefix = String(segment[..<range.upperBound])
                    if let candidate = cleanCompanyCandidate(prefix) {
                        candidates.append(candidate)
                    }
                    searchStart = range.upperBound
                }
            }

            for cue in topicCues {
                guard let range = segment.range(of: cue), range.lowerBound > segment.startIndex else {
                    continue
                }
                let prefix = String(segment[..<range.lowerBound])
                if let candidate = cleanCompanyCandidate(prefix) {
                    candidates.append(candidate)
                }
            }
        }

        return Array(Set(candidates)).sorted()
    }

    private static func cleanCompanyCandidate(_ rawValue: String) -> String? {
        var value = rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines.union(.punctuationCharacters)
        )
        let leadingPrefixes = [
            "顺便问一下", "顺便问下", "另外问一下", "另外问下", "请帮我", "帮我",
            "准备", "整理", "研究", "了解", "查询", "查一下", "查下", "分析", "比较",
            "对比", "关于", "应聘", "投递", "处理", "制作", "给我", "为", "查",
        ]

        var stripped = true
        while stripped {
            stripped = false
            for prefix in leadingPrefixes where value.hasPrefix(prefix) {
                value = String(value.dropFirst(prefix.count)).trimmingCharacters(
                    in: .whitespacesAndNewlines.union(.punctuationCharacters)
                )
                stripped = true
                break
            }
        }
        while value.hasSuffix("的") {
            value.removeLast()
        }

        guard value.count >= 2, value.count <= 32 else { return nil }
        let generic = Set([
            "公司", "企业", "单位", "科技", "集团", "银行", "证券", "实验室", "研究院", "工作室",
            "这家公司", "这个公司", "该公司", "这家企业", "这个企业", "该企业", "这家单位", "这个单位",
        ])
        guard !generic.contains(value),
              !companyReferentMentions.contains(where: value.contains)
        else {
            return nil
        }
        return value
    }

    // MARK: - Mixed current-task + independent-goal routing

    private static func mixedRoute(
        text rawText: String,
        current: FlowerollGlobalInputRoutingContext.CurrentTask
    ) -> FlowerollGlobalInputRoute? {
        let separators = ["，", ",", "；", ";", "。"]
        var ranges: [Range<String.Index>] = []
        for separator in separators {
            var cursor = rawText.startIndex
            while cursor < rawText.endIndex,
                  let range = rawText.range(
                    of: separator,
                    range: cursor..<rawText.endIndex
                  )
            {
                ranges.append(range)
                cursor = range.upperBound
            }
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }

        for range in ranges {
            let currentText = String(rawText[..<range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            let independentRaw = String(rawText[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard !currentText.isEmpty, !independentRaw.isEmpty,
                  isIndependentGoalClause(independentRaw)
            else { continue }

            let currentOperation: FlowerollCurrentTaskOperation
            switch singleRoute(text: currentText, current: current) {
            case .steerCurrentTask:
                currentOperation = .userTurn(text: currentText)
            case let .answerPendingInteraction(_, interaction, response):
                currentOperation = .pendingInteraction(
                    interaction: interaction,
                    response: response
                )
            case .newTask, .mixed:
                continue
            }

            let newTaskText = cleanedIndependentTaskText(independentRaw)
            guard !newTaskText.isEmpty else { continue }
            return .mixed(
                currentTaskID: current.taskID,
                currentOperation: currentOperation,
                newTaskText: newTaskText
            )
        }
        return nil
    }

    private static func cleanedIndependentTaskText(_ rawText: String) -> String {
        var value = rawText.trimmingCharacters(
            in: .whitespacesAndNewlines.union(.punctuationCharacters)
        )
        for prefix in ["顺便", "另外", "然后", "同时", "再"] where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count)).trimmingCharacters(
                in: .whitespacesAndNewlines.union(.punctuationCharacters)
            )
            break
        }
        var stripped = true
        while stripped {
            stripped = false
            for prefix in ["另开一个任务", "新开一个任务", "另开任务", "新任务", "单独"]
                where value.hasPrefix(prefix)
            {
                value = String(value.dropFirst(prefix.count)).trimmingCharacters(
                    in: .whitespacesAndNewlines.union(.punctuationCharacters)
                )
                stripped = true
                break
            }
        }
        return value
    }

    // MARK: - Single-intent routing

    private static func singleRoute(
        text rawText: String,
        current: FlowerollGlobalInputRoutingContext.CurrentTask
    ) -> FlowerollGlobalInputRoute {
        let text = normalized(rawText)
        guard !text.isEmpty else { return .newTask }

        if FlowerollDirectTaskControlPolicy.isCancelCommand(rawText) {
            return .steerCurrentTask(taskID: current.taskID)
        }

        if let pending = current.pendingInteraction,
           let response = exactOptionOrApprovalResponse(text: rawText, pending: pending)
        {
            return .answerPendingInteraction(
                taskID: current.taskID,
                interaction: pending,
                response: response
            )
        }

        if let pending = current.pendingInteraction,
           pending.kind == .clarification,
           pending.acceptsText,
           isHighConfidencePendingClarificationSteering(rawText, prompt: pending.prompt)
        {
            return .answerPendingInteraction(
                taskID: current.taskID,
                interaction: pending,
                response: .text(rawText.trimmingCharacters(in: .whitespacesAndNewlines))
            )
        }

        if isHighConfidenceCurrentTaskExpression(text) {
            return .steerCurrentTask(taskID: current.taskID)
        }

        if let pending = current.pendingInteraction,
           pending.acceptsText,
           isLikelyDirectPendingAnswer(rawText, prompt: pending.prompt)
        {
            return .answerPendingInteraction(
                taskID: current.taskID,
                interaction: pending,
                response: .text(rawText.trimmingCharacters(in: .whitespacesAndNewlines))
            )
        }

        // No current-task evidence means this global input is an independent
        // user goal. Merely having a visible/active Task never grants capture.
        return .newTask
    }

    // MARK: - Pending interaction correlation

    private static func exactOptionOrApprovalResponse(
        text rawText: String,
        pending: FlowerollPendingInteractionRoutingContext
    ) -> FlowerollPendingInteractionResponse? {
        let text = normalized(rawText)
        guard !text.isEmpty else { return nil }

        if let option = pending.options.first(where: { normalized($0.label) == text }) {
            return .option(id: option.id)
        }

        if let index = ordinalSelectionIndex(text), pending.options.indices.contains(index) {
            return .option(id: pending.options[index].id)
        }

        if pending.kind == .actionInput, pending.actionAttemptID == nil {
            if isAffirmative(text) { return .approval(true) }
            if isNegativeAnswer(text) { return .approval(false) }
        }
        return nil
    }

    private static func ordinalSelectionIndex(_ text: String) -> Int? {
        let forms: [(String, Int)] = [
            ("第一个", 0), ("第一", 0), ("1", 0),
            ("第二个", 1), ("第二", 1), ("2", 1),
            ("第三个", 2), ("第三", 2), ("3", 2),
            ("第四个", 3), ("第四", 3), ("4", 3),
        ]
        guard text.hasPrefix("选") || text.hasPrefix("就") || text.hasPrefix("第") else { return nil }
        return forms.first(where: { text.contains($0.0) })?.1
    }

    private enum PendingAnswerShape {
        case money
        case location
        case dateTime
        case yesNo
        case choice
        case openText
    }

    private static func isHighConfidencePendingClarificationSteering(
        _ rawText: String,
        prompt rawPrompt: String
    ) -> Bool {
        let text = normalized(rawText)
        let prompt = normalized(rawPrompt)
        guard !text.isEmpty, text.count <= 120, !prompt.isEmpty else { return false }
        guard !hasExplicitIndependentMarker(text), !looksLikeStandaloneChatOrQuestion(text) else { return false }

        // Home is normally a global-new-task surface. A visible clarification
        // may capture a longer free-text instruction only when the text clearly
        // talks about the same pending subject AND controls the pending workflow.
        // This keeps "帮我查杭州天气" independent while allowing phrases such
        // as "先查询这条提醒，再按原计划，删除时再问我" to stay on the Task.
        guard sharesPendingSubject(text: text, prompt: prompt) else { return false }
        let workflowMarkers = [
            "先", "再", "然后", "继续", "按原计划", "原计划", "确认", "查询", "查完",
            "删除", "保留", "改成", "改为", "不要", "别", "问我", "向我确认",
        ]
        return workflowMarkers.contains(where: text.contains)
    }

    private static func sharesPendingSubject(text: String, prompt: String) -> Bool {
        let subjectFamilies: [[String]] = [
            ["提醒", "提醒事项"],
            ["日历", "日程", "会议"],
            ["闹钟"],
            ["联系人", "通讯录"],
            ["酒店", "住宿"],
            ["文件", "文档", "附件", "pdf", "docx"],
            ["预算", "价格", "价位", "费用", "金额"],
            ["地点", "位置", "区域", "地址"],
            ["日期", "时间", "几点", "什么时候"],
            ["高铁", "火车", "车票", "航班", "机票"],
        ]
        return subjectFamilies.contains { family in
            family.contains(where: prompt.contains) && family.contains(where: text.contains)
        }
    }

    private static func isLikelyDirectPendingAnswer(_ rawText: String, prompt rawPrompt: String) -> Bool {
        let text = normalized(rawText)
        let prompt = normalized(rawPrompt)
        guard !text.isEmpty, text.count <= 28, !prompt.isEmpty else { return false }
        guard !hasExplicitIndependentMarker(text), !isIndependentGoalClause(text) else { return false }
        guard !looksLikeStandaloneChatOrQuestion(text) else { return false }

        // Control language is authority-bearing and should remain an explicit
        // current-task UserTurn rather than being disguised as a clarification
        // answer. Short values/choices, by contrast, are correlated here.
        if isBareTaskControl(text) || hasStrongCurrentReference(text) {
            return false
        }

        // The pending prompt supplies the expected answer *shape*. We do not
        // try to infer a Task target from the answer words themselves: the
        // exact interaction identity is already known. Incompatible fragments
        // remain ordinary UserTurns on the current Task instead of answering it.
        switch pendingAnswerShape(prompt) {
        case .money:
            return isMoneyLikeAnswer(text)
        case .location:
            return isLocationLikeAnswer(text)
        case .dateTime:
            return isDateTimeLikeAnswer(text)
        case .yesNo:
            return isAffirmative(text) || isNegativeAnswer(text)
        case .choice:
            return isChoiceLikeAnswer(text, prompt: prompt)
        case .openText:
            return true
        }
    }

    private static func pendingAnswerShape(_ prompt: String) -> PendingAnswerShape {
        if ["预算", "价格", "价位", "上限", "多少钱", "费用"].contains(where: prompt.contains) {
            return .money
        }
        if ["哪天", "日期", "时间", "几点", "什么时候", "入住", "出发", "开始时间"].contains(where: prompt.contains) {
            return .dateTime
        }
        if ["哪个区域", "哪个位置", "哪里", "哪儿", "地点", "位置", "住在哪"].contains(where: prompt.contains) {
            return .location
        }
        if prompt.contains("还是") || ["哪一个", "哪个", "偏向"].contains(where: prompt.contains) {
            return .choice
        }
        if prompt.hasSuffix("吗？") || prompt.hasSuffix("吗?") || prompt.hasSuffix("吗")
            || prompt.contains("是否") || prompt.contains("要不要") || prompt.contains("可不可以")
        {
            return .yesNo
        }
        return .openText
    }

    private static func isMoneyLikeAnswer(_ text: String) -> Bool {
        if text.rangeOfCharacter(from: .decimalDigits) != nil { return true }
        let chineseNumbers = CharacterSet(charactersIn: "零一二两三四五六七八九十百千万")
        return text.rangeOfCharacter(from: chineseNumbers) != nil
    }

    private static func isLocationLikeAnswer(_ text: String) -> Bool {
        let markers = ["附近", "区", "路", "街", "站", "湖", "江", "广场", "商圈", "机场", "车站", "中心"]
        return markers.contains(where: text.contains)
    }

    private static func isDateTimeLikeAnswer(_ text: String) -> Bool {
        let markers = [
            "点", "时", "号", "日", "月", "周", "星期", "今天", "明天", "后天",
            "今晚", "明晚", "上午", "下午", "早上", "晚上", "入住", "出发",
        ]
        return markers.contains(where: text.contains)
    }

    private static func isChoiceLikeAnswer(_ text: String, prompt: String) -> Bool {
        if text.hasPrefix("选") || text.hasPrefix("第") { return true }
        let characters = Array(text)
        guard characters.count >= 2 else { return false }
        for index in 0..<(characters.count - 1) {
            let pair = String(characters[index...index + 1])
            if prompt.contains(pair) { return true }
        }
        return false
    }

    private static func isAffirmative(_ text: String) -> Bool {
        ["对", "可以", "确认", "好", "好的", "行", "同意", "继续", "是", "就按你说的"].contains(text)
    }

    private static func isNegativeAnswer(_ text: String) -> Bool {
        ["不", "不是", "不行", "不同意", "取消", "不要", "别", "否"].contains(text)
    }

    // MARK: - High-confidence current-task grammar

    private static func isHighConfidenceCurrentTaskExpression(_ rawText: String) -> Bool {
        var text = normalized(rawText)
        guard !text.isEmpty, text.count <= 96 else { return false }
        guard !hasExplicitIndependentMarker(text), !isIndependentGoalClause(text) else { return false }

        text = stripLeadingDiscourse(text)

        if ["继续", "接着", "然后呢", "往下做"].contains(text) {
            return true
        }

        if (text.hasPrefix("继续") || text.hasPrefix("接着")) {
            let prefix = text.hasPrefix("继续") ? "继续" : "接着"
            let remainder = String(text.dropFirst(prefix.count))
            if remainder.isEmpty { return true }
            if hasCurrentEllipsisReference(remainder) || isAdditiveOrMutationFragment(remainder) {
                return true
            }
        }

        if text.hasPrefix("再") {
            let remainder = String(text.dropFirst())
            if isAdditiveOrMutationFragment(remainder) { return true }
        }

        if hasStrongCurrentReference(text) && hasSteeringVerb(text) {
            return true
        }

        if text.hasPrefix("这个继续") || text.hasPrefix("继续这个")
            || text.hasPrefix("算了这个") || text.hasPrefix("这个不要")
        {
            return true
        }

        if (text.hasPrefix("把") || text.hasPrefix("将")) && isAdditiveOrMutationFragment(text) {
            return true
        }

        let mutationTokens = ["改成", "改到", "改为", "换成", "调整到", "调整为", "提前到", "推迟到", "延后到"]
        if mutationTokens.contains(where: text.contains) {
            return true
        }

        if (text.hasPrefix("不是") || text.hasPrefix("不对"))
            && (text.contains("我是说") || text.contains("是"))
        {
            return true
        }

        if text.contains("还是") && text.contains("不是") {
            return true
        }

        if isBareTaskControl(text) {
            return true
        }

        return false
    }

    private static func isBareTaskControl(_ text: String) -> Bool {
        if ["算了", "停", "停止", "暂停", "停一下", "不用了", "不要了", "别做了"].contains(text) {
            return true
        }
        if text.hasPrefix("算了") && (text.contains("这个") || text.contains("刚才")) {
            return true
        }
        if ["不用继续", "不要继续", "别继续"].contains(where: text.hasPrefix) {
            return true
        }
        if ["取消这个任务", "取消刚才", "撤销刚才"].contains(where: text.hasPrefix) {
            return true
        }
        let shortControlPrefixes = ["先别", "暂时别", "别再", "不要发", "别发", "不要发送", "别发送"]
        return text.count <= 10 && shortControlPrefixes.contains(where: text.hasPrefix)
    }

    private static func hasStrongCurrentReference(_ text: String) -> Bool {
        let refs = [
            "当前任务", "这个任务", "那个任务", "刚才那个", "刚才的",
            "这一步", "当前这个", "剩下的", "最后两页", "这封邮件", "这个酒店任务",
        ]
        return refs.contains(where: text.contains)
    }

    private static func hasCurrentEllipsisReference(_ text: String) -> Bool {
        if hasStrongCurrentReference(text) { return true }
        return text.hasPrefix("这个") || text.hasPrefix("剩下") || text.hasPrefix("最后")
    }

    private static func hasSteeringVerb(_ text: String) -> Bool {
        let verbs = [
            "继续", "接着", "做", "处理", "改", "换", "调整", "加", "补", "删",
            "去掉", "取消", "停", "不要", "别", "撤销", "还是", "错",
        ]
        return verbs.contains(where: text.contains)
    }

    private static func isAdditiveOrMutationFragment(_ text: String) -> Bool {
        if text.contains("也") && ["加", "补", "做", "处理", "查"].contains(where: text.contains) {
            return true
        }
        let mutations = ["加", "补", "改", "换", "调整", "删", "去掉", "提前", "推迟", "延后"]
        return mutations.contains(where: text.contains)
    }

    // MARK: - Independent-goal grammar

    private static func hasExplicitIndependentMarker(_ text: String) -> Bool {
        let markers = [
            "单独", "新任务", "另一个", "另开一个任务", "另开任务",
            "和当前分开", "和当前任务分开", "和这个任务分开", "分开做",
        ]
        return markers.contains(where: text.contains)
    }

    private static func isIndependentGoalClause(_ rawText: String) -> Bool {
        let text = normalized(rawText)
        guard !text.isEmpty else { return false }
        if hasExplicitIndependentMarker(text) { return true }

        // Continuation words do not make a complete independent goal when the
        // remainder is itself an elliptical add/mutate expression. This keeps
        // “继续把…也…” on the current Task while “继续帮我查…” remains new.
        for cue in ["继续", "接着"] where text.hasPrefix(cue) {
            let remainder = String(text.dropFirst(cue.count))
            if hasCurrentEllipsisReference(remainder) || isAdditiveOrMutationFragment(remainder) {
                return false
            }
        }
        if text.hasPrefix("再") {
            let remainder = String(text.dropFirst())
            if isAdditiveOrMutationFragment(remainder) { return false }
        }

        let explicitRequestSignals = [
            "帮我", "请帮", "查询", "查一下", "查下", "查看一下", "提醒我",
            "给我", "发邮件", "整理一下", "整理pdf", "生成", "搜索", "播放",
            "下载", "创建", "新建", "设置", "预订", "订个", "比较", "解释一下",
            "规划", "重新查", "现在再查", "问一下", "问下", "问个", "题外",
            "什么是", "为什么", "怎么", "在哪", "哪里", "几点", "股价",
        ]
        if explicitRequestSignals.contains(where: text.contains) {
            return true
        }

        if text.hasPrefix("取消"), !hasStrongCurrentReference(text), text.count > 5 {
            return true
        }
        if text.hasPrefix("停止"), !hasStrongCurrentReference(text), text.count > 2 { return true }
        if text.hasPrefix("暂停"), !hasStrongCurrentReference(text), text.count > 2 { return true }

        return false
    }

    private static func looksLikeStandaloneChatOrQuestion(_ text: String) -> Bool {
        if text.contains("?") || text.contains("？") { return true }
        if ["你好", "谢谢", "在吗", "你是谁"].contains(text) { return true }
        let questionPrefixes = ["什么", "为什么", "怎么", "哪里", "哪儿", "谁", "能不能", "可不可以"]
        return questionPrefixes.contains(where: text.hasPrefix)
    }

    private static func stripLeadingDiscourse(_ text: String) -> String {
        var value = text
        for prefix in ["对了，", "对了,", "对了", "顺便", "另外"] where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
            break
        }
        return value
    }

    private static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
    }
}
