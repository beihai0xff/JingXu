# 镜序（JingXu）专业暗房工作台 UI 与交互重构设计规范

- **日期**：2026-11-20
- **作用模块**：`Sources/JingXuApp/`、`Tests/JingXuChecks/`、`Documentation/`
- **架构前提**：`JingXuCore` 数据库表结构（SQLite schema）、原片零破坏机制、固定清单预检流程、书签与身份核验及后台任务恢复契约保持 100% 不变。

---

## 1. 背景与重构目标

### 1.1 现状核心痛点（v0.9.3）

1. **看片色彩环境失真与系统表单感过重**：全局依赖高亮度系统背景（`windowBackgroundColor` / `controlBackgroundColor`），单图审片、双图比较与调色时周围大片浅灰白区域引发人眼「明度同时对比效应」，干扰曝光、暗部细节与白平衡判断；网格缩略图置于松散的 `1.15` 固定比例浅灰圆角卡片内，堆叠高饱和彩色圆点角标与突兀的右下角 `scope` 瞄准镜图标。
2. **垂直空间挤压与多选布局跳动（Layout Shift）**：
   - 图库网格上方最多可同时堆叠标题行、`FolderScopeBar`、筛选条件行、相似连拍提示行、`BatchSelectionBar`、「结果有更新」行、加载行与错误行（多达 6~7 层横条）；勾选照片弹出 `BatchSelectionBar` 时整片网格上下跳动。
   - 单图态卸载整棵 `NavigationSplitView` 并自绘 52pt 顶栏 + 42pt 底栏 + 72pt 胶片栏 + 状态栏，严重压缩有效看片画布。
3. **双工作区 UI 代码分叉与多选模式割裂**：
   - `ContentView.swift`（730 行）与 `SystemPhotosView.swift`（556 行）各自维护平行的侧栏、网格、单图顶底栏和状态条，切换「本地图库 / 系统照片」时工具位置和交互体验跳变。
   - 同时存在桌面 `Click / ⌘ / Shift` 选择与顶栏「选择 / 完成选择」开关两套冗余心智。
4. **对比视图、调色面板与确认弹窗体验粗糙**：
   - `ComparisonView` 顶部平铺纯文字按钮，底部直接裸露关键词输入框；
   - `ColorEditPanel` 将最核心的交互式直方图默认收起在 `DisclosureGroup` 内，参数控件采用普通系统 `Slider` 加宽边框 `TextField`，缺乏专业修图软件的精密操控手感；
   - 9 类文件/数据库写入预检弹窗散落各处，视觉层级与清单排版不一致。

### 1.2 重构目标

- **建立「原生专业暗房工作台」**：以无色偏中性暗灰体系为默认基准，消除色彩判断干扰，同时支持「图库跟随系统 + 看片/调色强制暗房」外观切换。
- **收拢单一连续壳层 `StudioShell`**：统一本地图库与系统照片的顶栏、侧栏、中央舞台与右侧面板，原位切换「网格 / 单图 / 对比 / 调色」，有效照片画布面积提升约 20%~25%。
- **打造零跳动选片与专业单键流**：引入双画幅网格切换、左上角悬停勾选环、底部悬浮胶囊操作坞（`FloatingSelectionDock`）以及符合摄影师直觉的 `G / E / C / D / I / F / X / 按住 \` 键盘流。
- **升级精密调色面板与统一安全清单弹窗**：固定常驻交互直方图，定制双极性 `DarkroomSlider`，并以统一三段式 `ManifestConfirmationSheet` 规范所有文件/图库变更预检弹窗。

### 1.3 明确非目标与不可变边界（Non-Goals & Invariants）

- **数据库零迁移**：不新增或修改 SQLite 表、列或枚举（`AssetFlag` 保持 `.none` 与 `.rejected`，不引入需迁移数据库的新旗标或颜色标签字段）。
- **核心协调器与安全门禁不变**：`ImportCoordinator`、`ArchiveCoordinator`、`DeletionCoordinator`、`ColorExportCoordinator`、`QualityReanalysisCoordinator`、`PhotoShareCoordinator`、`SystemPhotosCoordinator` 及 `ColorAutomationController` 的业务规则、备份先决条件、原子不覆盖提交与 `operationBlockReason` 互斥逻辑保持不变。
- **查询范围语义不变**：严格保持「当前 200~600 项游标窗口（`loadedAssets`）」与「完整筛选范围（`store.browsePhotoIDs(query)` 等）」的区分，绝不以界面可见数组替代完整查询范围。
- **不保留旧 UI 兼容分支**：重构落地后直接删除被替代的旧顶底栏、全局选择开关与散落内联弹窗，同步更新校验与文档。

---

## 2. 视觉设计系统（`DarkroomTheme` 与外观极性）

### 2.1 光学中性暗房色板（Zero-Hue-Cast Neutral Tokens）

所有暗房色阶保持 R/G/B 近似等值或极微弱中性平衡，避免偏蓝或偏暖底色污染白平衡判断：

| 语义 Token | 暗房色值（Hex / RGBA） | 适用范围 |
| --- | --- | --- |
| `canvasDeep` | `#141416` | 单图审片画布、双图对比画布、裁剪画布、暗房模式下的照片网格底色 |
| `panelSurface` | `#1C1C20` | 左侧导航栏、40pt 统一顶栏、64pt 胶片栏、右侧检查器与调色侧栏（实色不透明，防止透出底图色彩）、原比例网格暗匣衬底 |
| `elevatedControl` | `#26262B` | 分段选择器底槽、滑块轨道、参数数值胶囊、清单指标卡 |
| `floatingHUD` | `rgba(32, 32, 38, 0.90)` + 系统超薄材质 | `FloatingSelectionDock`、`LoupeFloatingBar`（仅浮于网格底边或看片画布边缘，不遮挡右侧调色区） |
| `subtleDivider` | `#2E2E35` | 1pt 面板边界与分组发丝分割线 |
| `textPrimary` / `textSecondary` / `textMuted` | `#F2F2F7` / `#98989F` / `#636368` | 主文案、次级元数据、禁用与辅助提示文案 |
| 语义强调色 | 系统强调蓝 / 琥珀橙 `#FF9F0A` / 珊瑚红 `#FF453A` / 状态绿 `#30D158` | 蓝：选中与激活候选；橙：待审核建议、未提交系统照片草稿、跳过警告；红：淘汰标记与破坏性操作确认；绿：自动保存就绪 |

### 2.2 外观偏好策略（`AppAppearanceMode`）

在 `browsingDefaults` 中持久化键 `"AppAppearanceMode"`（并在 `SettingsView` 的「外观」分组提供切换）：

1. **`.darkroom`（专业暗房深色 · 默认值）**：主窗口全局施加 `.preferredColorScheme(.dark)` 并使用上述 `DarkroomTheme` 色板。
2. **`.systemWithDarkroomStage`（图库跟随系统 · 看片与调色强制暗房）**：
   - 当舞台处于 `.grid` 且右侧未打开调色面板时，侧栏、顶栏与网格背景跟随 macOS 系统浅色/深色外观（浅色态下网格卡片使用低对比中性浅灰 `#F2F2F5` 衬底与 `#E2E2E8` 细描边）；
   - 一旦进入 `.loupe`、`.compare` 或 `.develop`，中央舞台、胶片栏与右侧 `ColorDevelopSidebar` 局部锁定 `.environment(\.colorScheme, .dark)` 与 `DarkroomTheme` 中性暗灰背景，确保看片与修图光学基准恒定。

### 2.3 排版与数字对齐

- 所有数量统计、进度计数（`142/406`）、图像像素尺寸（`4272 × 2848`）、曝光值（`+0.70 EV`）、色温（`5450 K`）及百分比均强制启用 `.monospacedDigit()`，消除拖拽滑块或滚动加载时的文字宽度抖动。

---

## 3. 顶层统一工作台架构（`StudioShell`）

### 3.1 统一工作区与舞台状态模型

本地图库（`AppModel`）与系统照片（`SystemPhotosModel`）共用唯一顶层容器 `StudioShell`，不再在 `ContentView` 顶层用 `if model.showsSystemPhotos` 或 `if let item = model.previewAsset` 整树替换 `NavigationSplitView`。

定义派生舞台枚举 `StudioStageMode`：

- **`.grid`（网格）**：本地 `previewAsset == nil`（或系统照片 `photos.preview == nil`）。
- **`.loupe`（单图）**：本地 `previewAsset != nil && comparisonReference == nil && colorEditor == nil`（或系统照片 `photos.preview != nil && photos.editor == nil`）。
- **`.compare`（对比）**：本地 `previewAsset != nil && comparisonReference != nil`（系统照片当前不设双图对比，该模式项在系统照片工作区禁用并附说明提示「系统照片暂不支持双图对比」）。
- **`.develop`（调色）**：本地 `previewAsset != nil && colorEditor != nil`（或系统照片 `photos.preview != nil && photos.editor != nil`）。

**模式切换规则（全部经过现有 `transitionPreview` 保存门禁）**：
- 从 `.grid` 切换到 `.loupe` 或 `.develop`：目标照片优先取 `selectedAsset`（若多选且无明确焦点则取当前窗口内首个已选照片；若无任何选择且当前窗口有照片，则取首张可预览照片；若当前范围无照片则禁用切换按钮）。切换到 `.develop` 时在打开预览后紧接调用 `beginColorEditing()`（系统照片调用 `beginEditing()`）。
- 从任意态切换到 `.compare`：当 `photoSelection.selectedIDs.count == 2` 时调用 `compareSelected()`；若在单图/调色态下当前照片所属 `similarGroupID != nil`，支持一键进入该相似组对比；其余情况「对比」项置灰并显示 `.help("选择 2 张照片以进入双图对比")`。
- 从 `.develop` 切换到 `.loupe`：调用 `finishColorEditing()`（等待未保存调色刷盘，失败则留在 `.develop` 并报错），保留当前 `previewAsset` 单图预览。
- 从 `.loupe` / `.compare` / `.develop` 切换到 `.grid`：调用 `closePreview()`（系统照片调用 `leavePreviewLevel()` 直至返回网格），保留有效多选并定位当前锚点照片所在完整分页。

### 3.2 40pt 统一窗口工具栏（`StudioToolbar`）

取代原系统分散 Toolbar 及单图态自绘 52pt 顶栏：

1. **左区（导航与范围上下文）**：
   - 侧栏显示/隐藏按钮（图标 `sidebar.left`）。
   - **`.grid` 态**：显示当前视图主标题（如「全部项目」「杭州旅行」）、副信息胶囊（`406 项 · 最老在前`）；当选中文件夹范围（`selectedFolderPath != nil`）时，同行内联渲染路径缩写提示与「包含子目录」紧凑胶囊开关（彻底移除独立占高的 `FolderScopeBar`）。
   - **`.loupe` / `.compare` / `.develop` 态**：显示「返回网格」快捷按钮 + 上一张 `‹` / 当前文件名（单行中段省略，悬停显示完整相对路径）/ 下一张 `›`；系统照片存在未提交本机草稿（`photos.previewSession.hasDraft`）时，紧接显示琥珀色胶囊 `本机草稿 · 未写入系统照片`。
2. **中区（四态舞台切换器）**：
   - 紧凑分段控件 `[ 网格 G | 单图 ␣ | 对比 C | 调色 D ]`，高亮当前 `StudioStageMode`，当 `operationBlockReason(.browse) != nil` 或裁剪草稿进行中时禁用切换。
3. **右区（动态任务胶囊与上下文动作）**：
   - **顶栏后台任务胶囊 `TaskStatusPill`**：
     - 常态空闲且无待处理通知时收起为仅显示最近操作历史的极简图标按钮（或隐藏文字）；
     - 当 `isWorking`、`archivePending`、`resumableQualityJob != nil`、`lastScanReport?.isPartial == true`、`lastImportReport != nil` 或系统照片存在 `Busy / resumable job / unresolved write` 时，展开为带进度环或琥珀色状态点的紧凑胶囊（例如 `分析 142/406`、`待恢复归档`）；
     - 点击胶囊弹出 `TaskCenterPopover`：集中展示当前任务详细进度、「暂停 / 继续 / 取消」按钮、未完成归档恢复入口、扫描/导入报告查看入口及最近 20 条操作记录。**彻底移除原窗口底部常驻占高的 `statusBar` 横栏**。
   - **按舞台自适应右侧工具组**：
     - `.grid`（本地）：`BrowseSearchField`（190~250pt）+ 筛选按钮（`hasUserFilters` 时带高亮蓝点）+ 视图选项按钮（尺寸、画幅模式、文件名、排序）+ 添加菜单（`+`：添加文件夹 / 从相机卡导入）+ 整理菜单 + 检查器开关（`I`）。
     - `.grid`（系统照片）：刷新按钮 + 视图选项按钮 + 检查器开关（`I`）。
     - `.loupe` / `.compare`：导出按钮（本地）+ 分享按钮 + 编辑按钮（`D`）+ 检查器开关（`I`）。
     - `.develop`（本地）：导出按钮 + 分享按钮 + 「完成编辑」按钮（返回 `.loupe`）。
     - `.develop`（系统照片）：分享按钮 + 「完成」（仅保留本机草稿并返回单图）+ 主强调按钮「保存到系统照片」（提交 PhotoKit 写入）。

### 3.3 左侧栏与右侧面板联动规则

- **左侧栏 `StudioSidebar`（宽 `200...280pt`）**：
  - 顶部固定 `WorkspaceSwitcher`（「本地图库 / 系统照片」分段切换）；
  - 本地图库分区：「智能视图（全部项目、最近添加、待检查建议、已标记淘汰）」「媒体类型（照片、RAW 照片、视频）」「文件夹（紧凑 26pt 行高目录树 + 底部『+ 添加文件夹…』）」「相册（列表 +『+ 新建相册…』）」；
  - 系统照片分区：「图库（所有照片）」「相册（用户相册及照片计数 +『+ 新建相册…』）」；
  - 侧栏底栏固定单行状态铭牌（本地：`本机图库 · 原片保留`；系统照片：连接状态标识）。
- **进入/离开调色的侧栏记忆联动**：
  - 维护 `@State private var userPreferredSidebarVisibility: NavigationSplitViewVisibility = .all`；
  - 当舞台进入 `.develop` 时，保存进入前的侧栏展开状态并自动收起左侧栏（`.detailOnly`），释放最大中央看片宽度；用户仍可在调色期间手动点击左上方侧栏按钮展开；
  - 当舞台从 `.develop` 返回 `.loupe` 或 `.grid` 时，自动恢复 `userPreferredSidebarVisibility`。
- **右侧面板 `StudioInspector`（固定宽 `296pt`）**：
  - `.develop` 态强制显示 `ColorDevelopSidebar`；
  - `.grid` / `.loupe` / `.compare` 态按 `showsInspector`（快捷键 `I`）按需展开 `PhotoInfoInspector`。

---

## 4. 图库网格、双画幅卡片与零跳动选片流

### 4.1 网格顶部单行上下文条（`GridContextStrip`）

仅在以下任一条件成立时于网格顶部显示紧凑单行提示条（否则高度为 `0`）：
- `hasUserFilters`：渲染可点击移除的筛选胶囊（搜索词、最低星级、旗标）及「清除全部」按钮；
- `appliedQuery.similarGroupID != nil`：渲染「正在查看相似连拍组」与「返回原范围」按钮；
- `resultsChanged`：渲染「图库结果有更新，当前浏览位置已保留」与「刷新结果」按钮；
- `browseError != nil`（或系统照片 `browseError / conflict / unresolved`）：渲染琥珀色错误摘要与「重试 / 查看记录」按钮。

### 4.2 双画幅模式与 `PhotoGridCell` 视觉规范

1. **双画幅枚举 `GridAspectMode`**（持久化于 `browsingDefaults` 键 `"BrowseGridAspectMode"`，在视图选项 Popover 中切换）：
   - **`.aspectFit`（原比例框 · 默认）**：`1:1` 槽位内设 `#1C1C20`（浅色系统模式下为 `#F2F2F5`）微圆角（`6pt`）衬底框，图片以 `.scaledToFit()` 居中完整呈现，保留 `3:2`、`2:3`、`16:9` 真实构图边界；网格间距 `10pt`。
   - **`.squareFill`（正方形铺满）**：`1:1` 槽位以 `GeometryReader` + `.scaledToFill()` + `.clipped()` 居中裁切铺满，网格间距收紧至 `6pt`，不改变底层 `ThumbnailProvider` 缓存键与解码逻辑。
2. **悬停勾选与标准桌面多选（移除全局「选择模式」开关）**：
   - 删除 `AppModel.isBatchSelecting`、`changeCheckboxMode` 与 `SystemPhotosModel.isSelecting` 的界面开关按钮。
   - **勾选热区**：当鼠标悬停在照片单元上（`@State private var isHovered`）或该照片处于已选中集合时，左上角浮现 `20×20pt` 圆形勾选按钮（热区 `28×28pt`）。点击该勾选按钮调用 `photoSelection.click(item.id, photoIDs: loadedAssets.photoIDs, checkboxMode: true)`，直接增减单张照片而不清空已有批选。
   - **主体点击**：点击照片单元其余区域继续通过 `GridClickHandler` 捕获真实 `NSEvent` 修饰键与点击次数（单击单选、`⌘+单击` 增减、`Shift+单击` 当前窗口连选、双击打开单图）。
3. **双层描边焦点与淘汰视觉降级**：
   - 移除原右下角 `scope` 图标；
   - **多选描边**：已选中项显示 `2pt` 系统强调蓝外框；
   - **键盘焦点描边**：当前焦点项（`selectedAssetID == item.id`）在内部叠加 `1pt` 高对比白色细框，使「多选集合」与「方向键焦点」同时清晰可辨；
   - **微胶囊角标**：右上角按需展示紧凑半透明深色微标（`RAW` 文本微标、已调色图标、视频图标、相似连拍图标、琥珀色待审核三角）；
   - **淘汰片降暗**：`item.flag == .rejected` 时，缩略图画面施加 `.opacity(0.42)` 与 `.saturation(0.45)`，右上角显示珊瑚红 `✕` 微标；
   - **失败兜底**：缩略图生成失败时，无论 `showsFileNames` 开关状态如何，单元内始终展示中文错误说明、文件名、「重试」及「重新授权…」入口。

### 4.3 底部悬浮胶囊动作坞（`FloatingSelectionDock`）

- 当选中照片数量 `>= 1` 时，以 `ZStack(alignment: .bottom)` 悬浮在网格舞台底部中央（距底边 `16pt`），带柔和轻弹簧过渡；网格 `ScrollView` 底部恒定保留 `80pt` 内边距，**勾选或取消选择时网格内容 0 像素跳动**。
- **胶囊内容（本地图库）**：
  - 左侧：等宽选中计数 `已选 N 张`（当存在已载入窗口外的选中项时附加次级提示 `（窗口外 M 张）`）+ `全选范围`（触发 `selectAllMatchingPhotos()`）+ `取消`（清空选择）；
  - 分割线右侧：评分菜单（`0–5 星`）、淘汰按钮、**双图比较按钮（`selectedIDs.count == 2` 时高亮显示）**、加入相册菜单、导出按钮、更多菜单（取消淘汰标记、修改关键词、移出当前相册、移动到文件夹、分享照片、批量应用预设、加入系统照片、导出新 XMP、撤销批量调色）。
- **胶囊内容（系统照片）**：
  - 左侧：`已选 N 张` + `全选范围` + `取消`；
  - 右侧：加入相册菜单、分析所选照片、更多菜单（移出当前相册、从系统图库删除）。

---

## 5. 单图审片、双图对比与精密调色侧栏

### 5.1 单图审片舞台（`LoupeStage`）与胶片栏（`PreviewFilmstrip`）

- **纯净暗房画布**：`PhotoScrollView` / `PreviewCanvasView` 背景色统一设为 `#141416`（取代 `.windowBackgroundColor`），完整保留现有 100% 屏幕物理像素映射、仅绘可见区域、任务取消与过期结果代际隔离（`loadGeneration`）。
- **底部悬浮审片控制条 `LoupeFloatingBar`**：
  - 叠放于画布底部中央（距底 `12pt`），替代原先上下共 94pt 的双灰底横栏：
  - 左段：`适应`、`100%`、`−`、`+`（若当前为 RAW 内嵌预览，显示 `嵌入预览` 提示徽章）；
  - 中段（仅 `.loupe` 非调色态显示）：5 颗星级点按图标 + 淘汰/取消淘汰切换按钮；
  - 右段：`.develop` 态下显示按住对比原图快捷提示（`按住 \ 对比原图`）+ 胶片栏折叠开关（`F`）；`.loupe` 态下仅保留胶片栏折叠开关（不在纯浏览态额外常驻双份原片解码缓冲）。
- **紧凑胶片栏 `PreviewFilmstrip`（高 `64pt`）**：
  - 保持在单图身份（`.id(item.id)`）外部，切换照片不重建横向滚动视图；
  - 背景色 `#1C1C20`，上边界 `1pt` `#2E2E35` 分割线；单格 `68×46pt`，淘汰项降暗显示，已调色项左上角微标，底部紧凑星级，当前照片高亮 `2pt` 强调色边框并自动居中滚动。

### 5.2 双图同步对比舞台（`ComparisonStage`）

- **左右双暗房画布**：以 `2pt` `#0B0B0D` 中缝平分舞台，底层继续复用 `ComparisonCanvas` 与归一化中心同步平移/物理像素 100% 联动及下一候选预取（`prefetchComparisonNext`）。
- **面板视觉区分**：
  - 左窗格（参考图）：左上角半透明胶囊 `参考图 · 文件名` + 星级只读展示；
  - 右窗格（当前候选）：内嵌 `2pt` 系统强调蓝激活边框，左上角高亮胶囊 `当前候选（操作作用于此）· 文件名` + 实时星级。
- **底部统一对比控制条**：
  - 居中排布：`同步缩放` 联动开关 | `适应` | `100%` | `上一候选 ‹` / `下一候选 ›` | `设为参考图` | `★1–5 评分` | `淘汰并下一张` | `取消淘汰` | `编辑当前照片 (D)`；
  - 下方紧贴共享的 `PreviewFilmstrip`；
  - 移除原底部裸露的 `TextField("关键词")`，统一通过右侧 `PhotoInfoInspector`（`I` 键）编辑当前候选照片的关键词与查看 EXIF。

### 5.3 精密调色与构图侧栏（`ColorDevelopSidebar` & `DarkroomSlider`）

面板宽 `296pt`，背景 `#1C1C20`，服务于本地 `ColorEditSession` 与系统照片 `ColorEditSession`：

1. **面板状态栏与快捷历史**：
   - 左：标题「显影调色」+ 紧凑图标按钮 `撤销` / `重做`；
   - 右：实时状态徽章（保存错误红字 / 正在保存微菊花 / 本地 `已保存` / 系统照片 `草稿已保存`）+ 原图对比按住按钮（保留 `OriginalComparisonButtonStyle` 的失焦与移出自动释放保护）。
2. **顶部常驻交互式成片直方图**：
   - 将 `ColorHistogram` 从原折叠组中提出，固定置于三页签切换器上方（高 `96pt`，底色 `#121215`），直接支持黑场/阴影/曝光/高光/白场五区横向拖拽与悬停读数提示；下方三页签切换为 **`[ 调整 | 裁剪 | 预设 ]`**。
3. **自绘双极性精密滑块 `DarkroomSlider`**：
   - 取代原系统 `Slider` + 宽圆角边框 `TextField` + 独立重置按钮的三件套布局：
   - **顶行**：左侧参数名（双击参数名触发 `session.reset(parameter)` 重置该项），右侧为紧凑等宽数值胶囊（常态无厚重外框；参数非默认值时高亮显示；点击数值胶囊原地激活精确数字输入 `TextField`，绑定 `@FocusState` 并在回车或焦点离开时调用 `session.endGesture()`）。
   - **底行（4pt 轨道 + 12pt 圆点）**：
     - 对双极性参数（曝光 `-5...+5`、对比度/高光/阴影/白色/黑色/饱和度/自然饱和度 `-100...+100`、相对白平衡 `-100...+100`）：轨道正中绘制 `1pt` 零位刻度线，填充条从零位向当前圆点双向延伸；
     - 对 RAW 绝对色温（`2000...50000 K`）与色调：轨道叠加低饱和冷蓝→暖琥珀、绿→洋红微渐变语义层；
     - 手势严格使用 `DragGesture(minimumDistance: 0)`：首次变化调用 `session.beginGesture()`，更新调用 `session.change(parameter, value:)`，松手或取消调用 `session.endGesture()`；双击滑块轨道/圆点同样重置单项。确保「一次拖动一步撤销」与「300ms 防抖自动保存」行为与现有 `ColorSessionChecks` 完全一致。
   - **参数分组扁平化**：移除多层琐碎折叠组，按摄影调色顺序单页清晰呈现三组卡片：**「明暗影调（曝光、对比度、高光、阴影、白色、黑色 + 组重置）」**、**「白平衡（RAW 绝对 / 普通相对提示 +『拍摄时』按钮 + 色温、色调）」**、**「色彩（自然饱和度、饱和度 + 组重置）」**；底部固定「复制调整」与「恢复原图 / 重置镜序调整」。
4. **裁剪页签与预设页签精修**：
   - **裁剪页签（`CompositionPanel`）**：采用 2×3 紧凑比例胶囊网格（`原图比例 / 自由 / 1:1 / 3:2 / 4:3 / 16:9`）+ 横竖分段按钮 + 「重新推荐」+ 等宽成片像素尺寸读数 + 底部「重置裁剪」「取消」「应用裁剪」；`CompositionCanvas` 画布底色统一为 `#141416`。
   - **预设页签（`EditorPresetBrowser`）**：双列暗房卡片网格展示内置 4 款预设与用户预设实时缩略图；选中预览期间在应用按钮上方显示醒目琥珀色提示条「预览中（未保存，导出与分享已锁定）」，提供「取消预览」与主按钮「应用预设」，底部保留「管理预设与导入 XMP…」。

---

## 6. 信息检查器与统一安全预检弹窗

### 6.1 右侧信息与诊断检查器（`PhotoInfoInspector`）

- 在 `.grid` / `.loupe` / `.compare` 态下通过 `I` 键或顶栏按钮开关（宽 `296pt`）：
- 多选且在网格态时：清晰提示「已选择 N 张照片 · 使用下方悬浮操作坞批量评分、整理或导出」；
- 单张目标时：分为 **`[ 信息 | 质量 ]`** 两页签：
  - **信息页签**：文件名（支持复制）、紧凑星级与淘汰分段开关、拍摄参数网格卡（拍摄日期、相机、镜头、像素尺寸、媒体类型）、关键词输入与保存框、底部「在访达中显示」与「导出新 XMP」快捷入口（系统照片显示 Live Photo 说明与「放弃本机草稿并重载…」）；
  - **质量页签**：顶部展示 `HistogramView`（亮度 / RGB 切换原片直方图），下方展示重构排版的 `QualityInspector` 暗房诊断卡（质量状态、局部尺度指标折叠项、接受/忽略审核按钮、单张重新分析入口、解码预览明暗统计卡、相似连拍组「查看这一组」按钮）。

### 6.2 统一三段式安全清单确认容器（`ManifestConfirmationSheet`）

新增通用视图容器 `ManifestConfirmationSheet`，将全部涉及文件写入、移动、废纸篓删除、索引清理与系统照片提交的弹窗收敛为统一视觉语言：

1. **段一 · 范围与安全保障头部**：
   - 顶部语义胶囊明确写出本次冻结范围（例如：`范围：已确认的 18 张所选照片`、`范围：当前完整筛选范围（含窗口外未加载项）` 或 `范围：整个图库`）；
   - 主标题 + 单段中文安全说明（明确指出是否创建图库备份、是否移动原文件、同名冲突跳过规则）。
2. **段二 · 统计指标卡与固定清单明细**：
   - 横向 2~3 个紧凑指标卡（如：`可执行 N 项`、`跳过 M 项`、`总大小 X MB`）；
   - 下方暗色等宽字体滚动清单区（可执行路径与琥珀色跳过/警告原因清晰分区展示，支持文本选择复制核对；对于导出与相机卡导入，保留参数配置控件与目录选择器在指标卡上方）。
3. **段三 · 粘性操作底栏**：
   - 左侧次要信息或「在访达中查看」（结果页），右侧标准 `取消（Esc）` + 主确认按钮（删除入废纸篓、移除失效索引、删除系统照片等破坏性动作统一使用 `.destructive` 珊瑚红样式；清单可执行数为 `0` 或后台忙碌时严格禁用确认按钮）。

覆盖并替换原有散落弹窗：`ImportSheet`、`ImportPlanView`、`ImportResultView`、`ColorExportOptionsSheet`、`ColorExportResultSheet`、`ColorConfirmationSheet`、`MissingAssetCleanupSheet`、`QualityReanalysisSheet`、原 `ContentView` 内联的 `xmpPlan / archivePlan / sourceMergePlan / deletionPlan` Sheet，以及 `SystemPhotoMutationSheet`、`SystemPhotosUploadSheet`、`SystemPhotoWriteSheet`。

---

## 7. 专业键盘矩阵与模块文件规划

### 7.1 全局键盘矩阵与焦点隔离契约

`LibraryKeyboardHandler` 升级为监听 `[.keyDown, .keyUp]`，保持以下前置过滤门禁：**仅当主窗口为 Key Window、无活动 Sheet / Modal Window、当前 `firstResponder` 不是 `NSTextView` / `NSTextField` / `NSSlider`、输入法 `hasMarkedText() != true`、且未按下 `Control / Option` 时才拦截单键**：

| 按键 | 网格态 (`.grid`) | 单图态 (`.loupe`) | 对比态 (`.compare`) | 调色态 (`.develop`) |
| --- | --- | --- | --- | --- |
| `0`–`5` | 设置所选照片星级 | 设置当前照片星级 | 设置右侧候选星级 | 设置当前照片星级（非裁剪时） |
| `Shift` + `0`–`5` | 单选时评分并下一张 | 评分并下一张 | 候选评分并下一候选 | 禁用（避免误切图） |
| `Delete` / `⌫` / `X` | 淘汰（单选前进，多选仅标记） | 淘汰并下一张 | 淘汰候选并下一候选 | 禁用（防误淘汰） |
| `U` | 取消淘汰标记 | 取消淘汰标记 | 取消候选淘汰标记 | 禁用 |
| `G` | 无操作 | 返回网格 | 返回网格 | 完成编辑并返回网格 |
| `Space` / `E` | 打开焦点照片进入单图 | `Space` 返回网格；`E` 保持单图 | `E` 退出对比回到当前候选单图 | `E` 完成编辑回到单图 |
| `C` | 选中 2 张时进入双图对比 | 若属相似组则打开组对比 | 退出对比回到单图 | 禁用 |
| `D` | 打开焦点照片并进入调色 | 进入调色 | 将当前候选转入单图调色 | 完成编辑回到单图 |
| `I` | 切换右侧信息检查器 | 切换右侧信息检查器 | 切换右侧信息检查器 | 无操作（右栏为调色面板） |
| `F` | 无操作 | 切换底部胶片栏显示 | 切换底部胶片栏显示 | 切换底部胶片栏显示 |
| 按住 `\`（抬起恢复） | 无操作 | 无操作（按 `D` 进入调色后对比） | 无操作 | 按住调用 `beginComparison()`，松开调用 `endComparison()` |
| `Esc` | 清空当前照片选择 | 返回网格 | 返回网格 | 若裁剪中则取消裁剪；否则完成编辑回单图 |
| 方向键 / `Shift+方向键` | 移动焦点 / 窗口内扩展连选 | 左右切换照片 | 左右切换右侧候选 | 非裁剪时左右切图并保持调色；裁剪中仅左右切图 |
| `⌘A` / `⌘Z` / `⇧⌘Z` | 全选完整范围 / 撤销与重做标注 | 撤销与重做标注 | 撤销与重做标注 | 撤销与重做当前调色会话历史 |

**按住 `\` 安全恢复保障**：除 `.keyUp` 释放外，在窗口失去 Key 状态、应用失活、切换照片或离开 `.develop` 时均强制触发 `session.endComparison()`，确保绝不卡死在原图对比状态。长按 `Delete` / `X` 过滤 `event.isARepeat`，防止连续误标淘汰。

### 7.2 `Sources/JingXuApp/` 模块化文件边界

拆解现有超长文件并删除过时视图代码，每个文件保持单一清晰职责：

- **新增 / 重组文件**：
  - `DarkroomTheme.swift`：`AppAppearanceMode`、中性暗房色阶 Token、舞台强制暗色 ViewModifier。
  - `StudioShell.swift`：统一三栏壳层、舞台模式 `StudioStageMode` 路由、侧栏自动收放状态管理。
  - `StudioToolbar.swift`：40pt 统一顶栏、四态舞台切换器、`TaskStatusPill` 与 `TaskCenterPopover`。
  - `StudioSidebar.swift`：统一本地与系统照片左侧导航栏（整合原 `FolderSidebar.swift` 的树行渲染，移除 `FolderScopeBar`）。
  - `PhotoGridStage.swift`：双画幅 `GridAspectMode`、`GridContextStrip`、`PhotoGridCell`（悬停勾选、双层描边、淘汰降暗）。
  - `FloatingSelectionDock.swift`：本地与系统照片共用的底部零位移悬浮胶囊操作坞（替代并删除原 `BatchSelectionBar.swift`）。
  - `LoupeStage.swift`：纯净暗灰单图舞台、`LoupeFloatingBar`（升级整合原 `ZoomPreview.swift`）。
  - `DarkroomSlider.swift`：双极性精密滑块控件与原地数值编辑胶囊。
  - `ManifestConfirmationSheet.swift`：统一三段式安全清单确认弹窗组件与各业务预检 Sheet 适配。
- **精简更新文件**：
  - `ContentView.swift`：收敛为挂载 `StudioShell` 与全局 Sheet / Alert / Keyboard 修饰器的轻量入口（控制在 ~180 行内）。
  - `SystemPhotosView.swift`：移除独立 `NavigationSplitView` 与重复顶底栏，改为向 `StudioShell` 提供系统照片网格、单图与弹窗内容。
  - `ComparisonView.swift`：升级为 `ComparisonStage` 双暗房对比视图，移除底部裸关键词输入框。
  - `PhotoEditingSidebar.swift` & `ColorEditPanel.swift`：升级为常驻顶部直方图 + `DarkroomSlider` 扁平分组的 `ColorDevelopSidebar`。
  - `PreviewFilmstrip.swift`、`QualityInspector.swift`、`HistogramView.swift`、`CompositionView.swift`、`Sheets.swift`、`ColorWorkflowSheets.swift`、`LibraryKeyboardHandler.swift`、`AppModel.swift`、`SystemPhotosModel.swift`：对齐新交互状态与暗房主题，清理已废弃的 `isBatchSelecting` / `isSelecting` 开关引用。

---

## 8. 错误处理与回归验证计划

### 8.1 错误处理与边界状态保障

- **快速切图与未保存草稿保护**：所有通过顶栏四态切换器、胶片栏或快捷键（`G / D / C / E`）发起的跨模式转换，均复用 `AppModel.transitionPreview` / `switchPreview` 与 `SystemPhotosModel` 的草稿刷盘门禁；保存失败时阻断跳转并原位展示重试/放弃选项。
- **操作互斥可视化**：未应用的预设预览、构图裁剪草稿、原片系统分享会话或后台文件任务运行期间，顶栏舞台切换器、悬浮动作坞及快捷键严格遵循 `operationBlockReason` 禁用对应入口并在 `.help` 气泡与 `TaskStatusPill` 中给出明确中文原因。
- **空状态与离线状态**：空目录（「此目录没有直接文件 → 一键开启包含子目录」）、筛选无结果（「一键清除筛选」）、来源离线或书签过期（「重新授权…」）、系统照片未授权（「连接系统照片 / 打开系统设置」）均采用暗房风格统一空状态卡片清晰引导。

### 8.2 验证闭环

1. **统一自动化构建与回归门禁**：
   - 运行 `zsh Scripts/build.sh check`，确保 arm64 Debug / Release 全 target 编译零错误，发布脚本检查与 Release 版 `JingXuChecks` 全量通过。
   - 在 `Tests/JingXuChecks/` 中补充针对新增视图状态纯逻辑的检查（包括 `StudioStageMode` 派生与切换门禁、`GridAspectMode` / `AppAppearanceMode` 偏好持久化默认值、悬停勾选与标准多选组合状态、单键分发门禁逻辑），覆盖超过 2,000 项完整范围选择与游标窗口边界。
2. **隔离环境原生 UI 验收**：
   - 使用 `swift run JingXuChecks --ui-fixtures` 生成合成测试素材，在独立 `JINGXU_UI_TEST_ROOT` + `IsolatedPhotoLibraryClient` 环境下启动隔离应用（绝不触碰真实图库与系统真实照片库）：
   - 逐项验证：双外观模式切换、本地与系统照片壳层切换、原比例/正方形双画幅切换、悬停勾选与 `FloatingSelectionDock` 零跳动表现、`G / Space / C / D / I / F / X / U / 按住 \` 全套键盘流、`DarkroomSlider` 拖拽与数字输入的单步撤销及自动保存、裁剪与预设预览门禁、统一 `ManifestConfirmationSheet` 各预检清单显示与确认闭环。
3. **文档同步更新**：
   - 实现完成后同步更新 `README.md`、`Documentation/InterfaceRefactor.md`、`Documentation/BrowsingAndCulling.md`、`Documentation/ColorEditing.md` 与 `Documentation/SystemPhotos.md` 中的界面布局与快捷键说明，并执行 `git diff --check`。
