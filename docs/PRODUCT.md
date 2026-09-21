# 花卷 / floweroll — 产品与交互

更新：2026-09-14

这份文档维护**当前用户可见产品行为**。底层实现与数据流见 `ARCHITECTURE.md`；品牌和视觉规范见 `DESIGN.md`。

## 产品定位

小卷不是“在手机里替用户乱点 App”的机器人，而是一个能接收任务、持续推进、调用真实设备/服务能力、验证结果并把成果带回用户的个人执行助理。

核心体验：**少打断、真执行、可恢复、结果可核验。**

当前产品有两种工作模式：

- **Task Mode**：用户把事情交给小卷执行；
- **Observation Mode**：小卷陪用户一起看、听、记和整理。

两种模式共享 App、Host 连接和历史入口，但后台 lifecycle 完全独立。

## App 导航

根 Tab 只有三个：

- **小卷 / Home**：创建任务、当前 Thread、Inbox、Observation 入口；
- **任务 / Tasks**：进行中、历史、Task Detail，同时显示完成后的 Observation 记录；
- **设置 / Settings**：连接、系统能力、权限、主题、Tools、Developer Mode。

Observation 不是第四个 Tab，而是 Home 打开的独立全屏模式。

## 首页（Home）

### 空闲态

- 小卷角色是视觉中心；
- Composer 用于直接创建 Task；
- “+”可以选择照片、拍照、扫描、文件；
- 左上可以进入 Observation；
- 输入框获得焦点、存在草稿或附件时，不把小卷整块从主舞台移走；
- 空内容时可以使用固定 canvas + gaze，避免无意义纵向滚动。

### 有当前任务

- Home 展示当前 Thread 的真实进展、用户输入、可公开 Timeline 和结果；
- 用户浏览历史时实时更新不应强行把页面拉回底部；
- 离开最新位置时显示轻量“回到最新”；
- 用户明确把某 Task“调到前台”后，Home 应稳定保持该 Thread，除非用户主动切换/新建；
- terminal Task 可以继续留在 Home 作为结果上下文，但不能因此被 Runtime 复活。

### 收件箱与完成提醒

Home 可以同时提示：

- 其他正在运行的 Task；
- needs-user Task；
- 已结束但还没真正看过结果的 Task。

completion banner、Inbox、待看/review 都是 presentation semantics，不是新的 Task lifecycle。

## 输入路由

全局 Home / Action Button 输入采用 **new-task-by-default**。

- 完整独立目标 → 新 Task；
- 明确针对当前 Task 的继续、修改、回答、取消 → 当前 Task；
- Home 当前 Thread 正在等待 clarification 时，短答案按问题形态精确绑定；较长文本只有在同时引用同一 pending 对象并表达明确流程控制（如“先查询这条提醒，再按原计划”）时才作为该 clarification 的回复，不能因长度退化成新 Task；
- 仅因为存在活动 Task，不能把下一句话吞进去；
- 混合“改当前任务 + 再做一个新目标”必须保留两部分语义。

Task/Thread Detail 中的输入默认属于该 Thread。

## Composer 与语音

Composer 支持：

- 多行文字；
- 按住说话；
- 麦克风按钮；
- 附件；
- 发送；
- Task 正在执行时的停止入口；
- 发送尚未完成时的取消发送。

Observation 正在使用周围麦克风时，Home 的普通语音输入会复用该实时 transcript，而不是再开启第二套麦克风采集。

## 附件与材料

- PhotosPicker 选择图片；
- 普通相机支持同一次会话多张手动拍摄；
- 文档扫描和普通拍照是两种产品入口；
- 文档扫描可以生成多页 PDF，再进入 OCR；
- 附件加入草稿后可以提前上传，但点击“发送”之前不创建 Task；
- 每个附件保持稳定 file identity / SHA / message ownership；
- 发送取消后按 submission identity 对账，旧 pending 不能重启后复活；
- 原始附件和生成成果都可以打开/预览，并使用真实文件名。

## 任务与 Thread

用户看到的是持续的 Thread；Runtime 内可以有多个 Task episode、Action、Attempt、Work Item。

Task Detail 展示：

- 用户输入；
- 公开执行阶段；
- needs-user；
- verified result；
- Artifact / materials；
- 取消/bring-to-home 等用户控制。

不展示私有 chain-of-thought、Builder 名、内部 dispatch digest 等工程细节。

## 任务列表

Tasks 使用系统 `List`，强调原生纵向滚动和 swipe 手感。

### 进行中

- 展示每个 Thread 的当前代表 Task；
- 左滑删除进行中的任务必须真实取消该 Task，再隐藏列表项；
- 删除/取消过程中不把普通 terminal notification 当成新的用户提醒。

### 历史

统一显示：

- 普通 Runtime Task 历史；
- Observation 历史。

普通 Task 可以标记“待看”或从本地历史列表隐藏；Observation 可以重新进入 Observation 历史详情或删除记录。

顶部“进行中 / 历史” segmented control 与实际滚动位置同步，点击后应真实滚动到对应 section。

## 结果与 Artifact

结果优先结构化展示：

- 结论；
- 文件；
- 日程/提醒/闹钟等 native result；
- 路线/地点；
- needs-user；
- foreground handoff。

同一个 terminal result 不在 Timeline 和结构化卡片重复复述。

语义必须对应真实状态：

- 已验证 → 可以说“已完成”；
- may-have-started / ambiguous → 明确说“正在核对/无法确认”；
- 需要用户继续前台操作 → 明确说“待你完成”，不冒充小卷已经完成。

## 取消

Home、needs-user、Task Detail 的 whole-Task cancel 最终使用同一个 durable cancellation contract。

- 已确定停止 → `已取消`；
- 外部副作用可能已开始 → 保持 cancellation pending / reconciliation；
- 不能把“cancel request 已提交”写成“外部操作一定停止”。

## 实时活动与灵动岛

用于用户离开 App 后的轻量状态展示。

原则：

- 一个 Task 一个有效长期展示 owner；
- 展示真实语义，不制造假百分比；
- terminal 后及时更新/释放；
- compact UI 简洁，品牌图标和轻动效不能压过任务文本；
- 重新打开 App 后从 Host durable state 恢复，Dynamic Island 从不拥有 Task truth。

## 原生系统能力

Calendar、Reminders、Alarm、Contacts、Location、Notifications 等尽量使用 Apple 原生体验。

- 权限只在合适的用户动作下请求；
- background executor 不能突然弹系统权限；
- create/update/remove 绑定真实 native identity 与 readback；
- Settings 中有权限汇总、时间安排、小卷闹钟和 ready Tools；
- Files export / Photos save 是用户明确触发的前台操作，成功含义不能扩大成“云端已同步”。

## 观察模式

Observation 是当前真实实现的第二种工作模式，不是 roadmap。

### 开始

Home 点击“观察”进入全屏 Observation setup。

用户可以选择：

- 会议；
- 屏幕；
- 影音；
- 综合；
- 自定。

对应来源是：

- 屏幕画面；
- 周围麦克风；
- 手机/屏幕声音。

开始前明确提示：

- 只在用户启动后采集；
- 可以随时暂停/结束；
- 转写和必要关键画面会进入已连接 Host/AI 用于整理；
- 不保存完整录音或完整视频；
- 用户应先取得被记录者同意。

### 观察中

用户可以看到：

- 当前 phase；
- elapsed time；
- 各 source 输入状态；
- 实时转写；
- 最近屏幕画面理解；
- 阶段性总结；
- gap/中断提示。

可以暂停、继续或结束。返回 Home 不等于结束 Observation。

屏幕观察不会分析花卷自己的 Observation 前台；用户切到其他 App 后才处理外部画面。

周围麦克风与手机声音是两个来源。UI/总结会抑制明显的扬声器→麦克风 acoustic echo，避免同一句话重复出现。

### 整理与问答

Host 会对观察记录做：

- screen understanding；
- checkpoint summary；
- final summary；
- decisions；
- todos；
- open questions。

用户可以直接问“刚才讲了什么/这个决定是什么”等问题，回答只能基于已采集 evidence；没有依据时应明确说没有记录，而不是猜。

### 结束与历史

结束后：

- native capture 先停止；
- 未同步 event 继续对账；
- Host 完成最终整理；
- 用户可以查看原始记录；
- 分享纪要；
- 存入 Tasks 历史；
- 在 Tasks History 重新打开时间线和纪要；
- 删除本机 + Host 记录。

如果 Host 暂时不可达，原始记录保留本机，恢复连接后继续整理。

如果 App 被杀，Observation **不会自动恢复采集**；旧 session 变成 interrupted，需要用户明确继续。

## 视觉

当前视觉事实见 `DESIGN.md`。

主要原则：

- 默认浅粉，可在 Settings 换 Theme；
- 内容优先，角色动画轻量；
- 小卷 idle/listening 当前是 sprite + 独立 eyes，不是 Rive body；
- 能用 Apple 原生组件就不自己造一套手势/列表；
- 不显示假进度、内部工程词或不真实的成功状态。

## 开发者模式

Settings 可以开启 Developer Mode，显示 Agent 调试入口。

开发者层可以查看 Planner Prompt/Context、Capability、Action/Attempt、延迟和 verification evidence，但它是只读观察层，不改变正常 Runtime truth。
