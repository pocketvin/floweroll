# 花卷 / floweroll — 设计与品牌事实

更新：2026-09-14

这份文档只维护当前产品设计事实：命名、主题、小卷角色、主要视觉落位和交互风格。旧美术实验、Rive/Rig checkpoint 和逐轮验收记录不放在这里。

## 1. 命名

App 中文名：**花卷**；英文品牌：**floweroll**；助手角色：**小卷**。

Swift 工程和类型使用 `Floweroll`；Python 包、配置、URL scheme 使用 `floweroll`。
系统权限与设置称“花卷”，助手对话、任务状态和角色称“小卷”。不保留历史品牌别名。

## 2. 产品视觉方向

整体视觉：

- iOS 原生感优先；
- 信息层级比“AI 特效”重要；
- 默认浅粉，但不是所有状态都染成粉色；
- success / warning / failure 保持自己的语义色；
- 尽量使用系统 List、Sheet、Picker、Menu、Swipe Actions、Material、ShareLink、QuickLook 等成熟交互。

不要为了“像 AI”加入：

- 假进度；
- 过度发光；
- 大量渐变光效；
- debug/internal ID；
- 持续高频动画。

## 3. Theme

当前主题系统实现位于：

`ios/Floweroll/App/Theme/FlowerollTheme.swift`

主题由 `FlowerollThemeStore` 持久化到 UserDefaults。

默认主题：`blush / 浅粉`。

当前可选：

- 浅粉；
- 玫瑰；
- 珊瑚；
- 薰衣草；
- 天空；
- 薄荷。

Theme 提供：

- `accent`；
- `strongAccent`；
- `onStrongAccent`。

App 根部统一 `.tint(theme.palette.accent)`，各产品页面通过 environment 读取 palette。

## 4. 小卷角色身份

小卷是一只白色、圆润、非常简洁的猫猫助手。

固定视觉 DNA：

- 白色主体；
- 粗而圆润的黑色外轮廓；
- 额头中央一撮小卷毛；
- 柔粉色只用于耳朵内侧、双颊、舌头等少量细节；
- 正常猫尾巴，粗、圆、有弹性；
- 身体是圆润小方团/猫猫头，不画成正常四足猫；
- 全图最多两只圆爪；
- 五官极简，主要靠眼睛、嘴、身体倾斜和尾巴表达情绪。

长期角色梗：**小卷和自己的尾巴有仇。** 可以做偶发彩蛋，但不能抢占任务、确认、错误或成果信息。

品牌基础色：

- 主体白 `#FFFFFF`
- 主线黑 `#000000`
- 柔粉 `#F7B1B8`

系统 Accent Color 不给角色本体染色。

## 5. 当前角色资产来源

当前品牌/角色资产主要在：

```text
assets/floweroll/
├─ identity/
├─ states/
├─ scenes/
├─ motion/
└─ manifest.json
```

正式 App 还使用 Asset Catalog 中的小卷 Home sprite、eyes、Dynamic Island/icon 等资源。

角色生产原则：

```text
批准母版
→ 拆层 / 状态资产
→ 动画层
→ iOS presentation
```

不要恢复“为一个新状态直接在 SwiftUI Canvas/Path 里重新画一只猫”的做法。

## 6. Home 角色当前实现

源码：

`ios/Floweroll/App/FlowerollPresentationView.swift`

`FlowerollPresentationView` 当前实现为：

- `idle` / `listening`：deterministic sprite body；
- 左右眼是独立 layer；
- 支持 blink、bounded gaze、轻微 bob 和 poke；
- listening 有独立 signal；
- `thinking / working / waiting / done`：继续使用 `FlowerollAnimatedStateView`。

因此 `.riv` 资源仍存在并不代表当前 Home idle/listening 仍由 Rive body 驱动。

动画原则：

- 同一形状优先 transform，不自由 morph；
- 呼吸、眨眼、轻晃低幅、低频；
- gaze 有界，竖向幅度比横向更小；
- poke 不允许角色变黑、变形或产生白缝；
- `Reduce Motion` 应回退到静态/弱动画；
- 动画不能抢 Composer、ScrollView 或 Tab 手势。

## 7. Home 落位

空闲 Home：

- 小卷是主要视觉中心；
- Composer 在底部；
- 输入焦点、文字草稿、附件存在时，小卷仍保持主舞台，不因为 draft 就被整块替换；
- 空内容时可以使用固定 canvas + finger gaze；
- 有真实 Timeline/Inbox 内容时恢复正常可滚动布局。

有任务 Home：

- 角色只是状态辅助，不取代任务内容；
- Timeline、成果、needs-user 和任务控制优先；
- “回到最新”是轻量独立控制，不横向遮挡内容。

## 8. Tasks / Detail / Artifact

Tasks 页面重点是信息和系统列表手感，不需要大量角色插画。

Task Detail：

- 小卷状态图可以辅助表达 thinking/working/waiting/done；
- 真实 Timeline 和结构化成果优先；
- 文件、日程、路线等 Artifact 使用自身语义图标/预览，不强行套角色插画。

Observation 历史使用眼睛/观察语义图标，与普通 Task 记录在同一 History 列表中区分。

## 9. Live Activity / Dynamic Island

灵动岛的优先级：

1. 状态真实；
2. 文字可读；
3. 单一 owner；
4. 小尺寸品牌识别；
5. 轻微动效。

不要把完整 Home 角色动画搬进 Dynamic Island。小尺寸可以使用独立简化 glyph / app icon / 状态点动画。

Dynamic Island 不是任务状态机，显示内容必须跟随 Runtime truth。

## 10. Observation Mode 视觉

Observation 是工作模式，不做成工程调试页。

Setup：

- 小卷 + “想让小卷陪你观察什么？”；
- preset 选择；
- 清楚列出此次会用到的屏幕/周围/手机声音；
- 隐私说明放在开始前。

Active：

- 顶部显示真实 phase 与 elapsed time；
- 最近 transcript / screen insight 作为时间线；
- 阶段总结、最终纪要、问答独立卡片；
- Pause/Resume/End 始终是清楚的用户控制；
- 完成后可以分享、存入历史、查看原始记录。

系统共享、麦克风或模型失败时使用产品语言说明实际状态，不把系统错误码直接抛给用户。

## 11. Settings

Settings 当前负责：

- Host connection；
- 时间安排 / 小卷闹钟；
- Theme；
- microphone / camera / notification / location / reminder / calendar / contacts / alarm 权限；
- 当前 ready Tools；
- Developer Mode；
- IP 动效实验室；
- 当前 App 版本。

权限只在用户主动点击时请求；执行任务时不能突然为了方便把系统权限弹出来。

## 12. Developer Mode

Developer Mode 可以暴露：

- Planner Prompt / Context；
- Capability / Action / Attempt；
- latency/token；
- verification / failure evidence。

这些信息不进入正常用户界面，也不能改变 Runtime 行为。

## 13. 旧设计资料

旧命名讨论、完整视觉基线、Rive/Rig checkpoint、历史落位表已经冻结在：

私有工作归档（不随源码发布）

需要追溯旧资产决策时再读，不作为现行产品事实。
