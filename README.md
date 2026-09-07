# 镜序（JingXu）

镜序是一款面向摄影爱好者的原生 macOS 相机相册整理软件。它可以安全导入相机卡、非破坏式索引本地图库、读取 RAW/JPEG/视频元数据，并在本机完成质量分析和相似连拍整理。

## 已实现

- 相机卡或任意文件夹安全导入：SHA-256 校验、临时文件原子提交、重复跳过、同名文件安全加后缀、永不删除来源。
- 本地文件夹安全作用域书签与增量扫描；来源离线时保留目录记录。
- 系统支持的 RAW、JPEG、HEIC、PNG、TIFF 缩略图与元数据，视频索引和预览。
- RAW+JPEG 同名配对，按日期、相机、镜头、类型、评分、旗标、关键词和质量状态查询。
- 完全离线的清晰度、阴影、高光和 Vision Feature Print 相似连拍分析。
- 评分、保留/淘汰旗标、关键词、手动相册和质量建议审核。
- 显式 XMP sidecar 导出；默认跳过已有文件，确认后才替换。
- SQLite/GRDB WAL 目录、可重建的内存/磁盘缩略图缓存。
- 10 万条模拟目录查询性能校验。

## 运行

最低系统版本为 macOS 14。

```bash
swift run JingXuApp
```

也可以在安装完整 Xcode 后直接打开 `Package.swift`，选择 `JingXuApp` scheme 运行。App Sandbox 权限文件为 `JingXu.entitlements`。

## 自动化校验

当前机器只有 Command Line Tools，缺少 Xcode 附带的 XCTest，因此仓库提供了不依赖 XCTest 的自动化校验可执行程序：

```bash
swift run JingXuChecks
```

它覆盖目录迁移、筛选、标注、相册、增量扫描、RAW/JPEG 配对、元数据、质量建议、XMP、安全导入和 10 万条查询性能。

## 打包

```bash
Scripts/package-app.sh
```

脚本会构建 Release 版本、生成可双击的 `镜序.app`、使用本机临时签名附加 Sandbox 权限，并在 `outputs/` 中创建包含应用的 ZIP。

## 数据与隐私

- 目录数据库：`~/Library/Application Support/JingXu/Catalog.sqlite`
- 缩略图缓存：`~/Library/Application Support/JingXu/Thumbnails/`
- 不使用账户、网络请求、云服务或遥测。
- 索引来源始终只读；只有用户明确选择的导入目标和 XMP 导出位置会写入文件。

## 工程结构

- `Sources/JingXuCore`：数据模型、GRDB 目录、扫描、导入、元数据、缩略图、质量分析和 XMP。
- `Sources/JingXuApp`：SwiftUI 三栏图库、导入向导、过滤、检查器和设置。
- `Tests/JingXuChecks`：可在 Command Line Tools 环境运行的单元、集成与性能校验。

发布签名、公证、Apple Photos 接管、照片编辑、人脸/内容识别、地图和云同步不在当前 MVP 范围内。
