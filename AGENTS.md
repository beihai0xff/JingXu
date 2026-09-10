# 镜序 Agent 开发指南

本指南适用于整个仓库。镜序是面向摄影爱好者的原生 macOS 相册整理工具：安全导入、非破坏式索引、本地质量分析与照片整理。默认离线，无账户、云服务或遥测；照片编辑、人脸识别、地图和云同步不属于当前范围。

## 开始任务

1. 查看 `git status --short`，保留用户已有改动，只修改当前任务需要的文件。
2. 阅读 `Package.swift`、相关源码和对应功能文档。README 中的历史版本、测试数量、机器配置和发布状态可能过时；当前行为以源码为准，构建与发布要求以脚本和 CI 为准，不把历史验收记录当成本次证据。
3. 从界面入口追到协调器、数据库与校验，明确操作范围、文件副作用、取消和恢复路径，再动手修改。
4. 先完成一个最小端到端实现，再补齐需求；不要为了尚未完成的复杂设计拆掉可运行的链路。

## 实现原则

- 不保留向后兼容：过时实现直接删除，不新增兼容层、migration 或 fallback。删除旧路径时同步更新调用方、校验和文档。现有图库升级代码不是新增兼容机制的模板；本规则也不授权清空真实图库或删除数据保护机制。
- 选择满足当前需求的最简单实现，不做预防性抽象，不增加多余配置层，不引入“先这样以后再换”的临时架构。
- 保持模块化和关注点分离；优先检查已有依赖和系统框架，再考虑新包。需要新增能力时，先了解成熟产品的已验证模式，不自行重造现成库。
- 遵循相邻 Swift 代码的命名、格式和并发边界。界面文案使用简体中文，准确说明范围、跳过原因和失败原因。

## 技术栈与修改入口

Swift Package，工具版本声明为 Swift 6.1，最低 macOS 14。界面使用 SwiftUI / AppKit，数据库使用 GRDB / SQLite；图像处理复用 ImageIO、CoreGraphics、Vision，文件校验复用 CryptoKit。依赖版本检查 `Package.swift` 和 `Package.resolved`。

| 工作内容 | 优先阅读与修改 |
| --- | --- |
| 界面、选择、筛选、操作生命周期 | `Sources/JingXuApp/AppModel.swift`、`ContentView.swift`、`Sheets.swift` |
| 数据模型、查询、标注、事务 | `Sources/JingXuCore/Models.swift`、`CatalogStore.swift` |
| 来源授权、身份、扫描、导入 | `FileAccess.swift`、`SourceScanner.swift`、`ImportCoordinator.swift`、`SourceManagement.swift`（均位于 Core） |
| 日期归档、跨来源批量移动、撤销 | `Sources/JingXuCore/ArchiveCoordinator.swift`；两种整理操作共用机制 |
| 废纸篓清理、失效索引清理 | `Sources/JingXuCore/DeletionCoordinator.swift`、`MissingAssetCleanup.swift` |
| 图库打开、锁、备份与恢复 | `Sources/JingXuCore/CatalogUpgradeCoordinator.swift` |
| 缩略图、原图、直方图 | Core 下的 `ThumbnailProvider.swift`、`ImagePreviewLoader.swift`、`DecodedPreview.swift`、`HistogramProvider.swift` |
| 单图画布、导航和胶片栏 | Core 下的 `PreviewCanvas.swift`、`PreviewNavigation.swift`、`FittedThumbnail.swift`；App 下的 `ZoomPreview.swift`、`PreviewFilmstrip.swift` |
| 质量诊断、审核和重算 | Core 下的 `QualityAnalyzer.swift`、`QualityDiagnostics.swift`、`QualityReanalysisCoordinator.swift`；App 下的 `QualityInspector.swift` |
| 私有人工校准工具 | `Sources/JingXuCalibration/JingXuCalibration.swift`、`Sources/JingXuCore/QualityCalibration.swift` |
| 自动化回归 | `Tests/JingXuChecks/`；入口为 `JingXuChecks.swift` |
| 打包与发布 | `Scripts/`、`Packaging/`、`.github/workflows/release.yml`、`Tests/ReleasePipeline/` |

业务规则、文件操作和数据库操作放在 Core；View 负责呈现和交互，AppModel 负责应用状态与协调。`AppModel` 使用 `@MainActor`，`CatalogStore` 是 actor；耗时扫描、解码、哈希和分析不要阻塞主线程，也不要为消除并发报错随意取消隔离。优先复用现有协议和可注入服务进行测试。

## 数据与文件操作约束

- 索引和分析不修改原照片。导入永不删除来源，保留校验和不覆盖提交；XMP 导出默认跳过已有文件，替换需明确确认。
- 扫描、导入、分析、来源管理及文件整理接入现有操作互斥。检查实际入口与未完成日志状态，不能只靠禁用按钮防止重入。
- 文件写入类功能先生成固定清单，展示范围和目标，用户确认后执行；执行时重新核对来源授权、路径边界和文件身份。离线、权限错误、身份不明不能当作“文件不存在”处理。
- 删除只走系统废纸篓，失败不能退化为永久删除。来源移除、相册删除、失效索引清理与原文件删除是不同操作，保持语义明确。
- 归档和批量移动使用现有同卷、不覆盖、配套文件分组、备份、日志及恢复机制。保持照片 ID、评分、标签、相册关系和分析；不要用复制后删除绕过跨卷限制。
- 涉及备份的操作必须在备份成功后执行；事务失败回滚，无法确认文件操作结果时保留日志并停止猜测。数据库备份不能代替文件移动的撤销。
- 区分“当前可见选择”和“完整筛选范围”：网格及单图导航最多 2,000 项，批量移动基于当前选择；清理、归档或重算按各自计划查询范围，不能随手拿界面数组代替完整查询。
- 图库打开失败必须保留恢复入口，不能创建替代空库掩盖失败。缓存可重建，用户标注和恢复日志不可当缓存删除。

## 图像与质量分析约束

- 缩略图、直方图和质量诊断优先复用已有解码与像素转换路径，保持 EXIF 方向、sRGB 和透明像素处理一致。
- 原图加载支持取消，快速切图时隔离过期结果；退出单图释放图像。胶片栏按需加载缩略图，不批量解码原图；100% 按屏幕物理像素映射，画布只绘制可见区域。
- 质量诊断、明暗统计、相似连拍分别表达；无法可靠判断不等于质量正常。解码预览统计不能宣称为 RAW 传感器数据。
- 新模糊报警在完成人工校准和独立验证前保持关闭。算法重算不得覆盖人工审核、评分、旗标、关键词或相册关系；不要在普通启动或扫描时自动重算旧图库。
- 修改阈值或校准流程前阅读 `Documentation/QualityAnalysisV2.md`。不得虚构人工标签、拿算法输出作真值，或反复根据验证集调参后声称独立验证通过。

## 开发与验证

本地与 CI 共用构建入口，在仓库根目录运行：

```bash
zsh Scripts/build.sh check
```

`JingXuChecks` 是可执行 target，当前不是 XCTest test target；不要用 `swift test` 代替项目回归。新增检查放进相应检查文件，并注册或接入 `JingXuChecks.swift` 的执行链，保证真实运行。

该入口显示实际工具链，验证版本元数据和发布脚本，按 `Package.resolved` 固定依赖，以 arm64 构建全部 Debug / Release target，并执行 Release 版 `JingXuChecks`。编译参数和校验顺序只维护在此脚本中，不在 CI 或打包脚本内另写一套。

修改发布元数据、Cask 或流水线时运行：

```bash
python3 -m unittest discover -s Tests/ReleasePipeline -v
```

- 测试使用独立临时目录、临时数据库和注入服务，禁止拿真实图库试删除、移动、恢复或重算。覆盖变更相关的成功路径和实际失败风险：取消、权限或备份失败、文件替换、事务失败、中断恢复；完整范围操作还需检查超过 2,000 项的情况。
- UI 验收素材可用 `swift run JingXuChecks --ui-fixtures` 生成。`swift run JingXuApp` 会打开应用并访问默认图库，不是隔离测试命令；启动前确认测试账户或图库环境已隔离，选择临时照片目录本身并不会隔离数据库。
- 涉及键盘焦点、快速切图、缩放、Sandbox 授权或废纸篓行为，需在相应实际界面／打包应用验证。CLI 校验通过不等于 UI 或真实 RAW 已验收。
- 纯文档修改核对路径、命令与 `git diff --check` 即可，无需为文档改动构建应用。交付说明实际执行的检查和未验证项，不复制历史通过记录。

## 隐私、打包与交付

默认图库位置由 `JingXuPaths` 解析；沙盒应用实际位置受容器影响，不硬编码开发者机器路径。私有照片、路径清单、指纹、人工标签和校准报告必须留在所有 Git 仓库之外，不能提交或附到公开日志中。不要提交数据库、凭据、证书私钥或生成的安装包。

打包按 `Documentation/ReleasePipeline.md` 和 `Packaging/ReleaseChecklist.md` 执行：测试包使用 `zsh Scripts/build.sh adhoc`，正式签名包使用 `zsh Scripts/build.sh release`。两者先执行完整构建回归，共用应用组装与 DMG 生成；CI 的 `Scripts/ci-package-app.sh` 仅准备和清理签名凭据。版本读取 `Packaging/Info.plist`，不要从 README 复制旧版本。正式签名或公证失败应停止，不能降级或关闭系统保护。

推送 `v*` 标签会触发发布，并在成功后更新 Cask。只有任务包含发布时才执行发布动作；开发修复不隐含替换已安装应用、操作真实图库或推送发布标签。已有版本产物不得覆盖。

行为变化同步更新对应说明：移动看 `Documentation/BatchMove.md`，归档看 `Documentation/DateArchive.md`，质量分析看 `Documentation/QualityAnalysisV2.md`，发布和安装看 `Documentation/ReleasePipeline.md`、`Documentation/Homebrew.md`。交付时简述改动、验证结果和剩余限制，区分代码完成、打包完成、安装验证和已发布。
