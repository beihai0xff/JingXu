# 镜序 0.2.6

## 批量选择与同磁盘移动

- 网格开启「批量选择」，勾选照片或全选当前照片，再点击「移动到目录…」。范围为当前网格，最多 2,000 项，不含视频。
- 支持同一磁盘的来源内、其他来源及来源外目录；重名整组追加序号，不覆盖、不跨卷复制。
- RAW/JPEG 配对须全部选中，明确关联 XMP 同行；确认页展示文件、大小及跳过原因。
- 在线备份、文件身份及内容校验、持久日志、失败回退、继续与撤销。保留照片 ID、评分、标签、相册关系和分析结果。

## Homebrew Cask

发布成功后自动同步 Cask 版本及 SHA-256。首次添加源：

```sh
brew tap beihai0xff/jingxu https://github.com/beihai0xff/JingXu.git
brew install --cask beihai0xff/jingxu/jingxu
```

已由 Homebrew 管理的安装，在安全结束图库任务并退出镜序后执行 `brew update`，再执行 `brew upgrade --cask beihai0xff/jingxu/jingxu`。手动安装的同版本应用可用 `brew install --cask --adopt beihai0xff/jingxu/jingxu` 接管；不同版本或文件不一致时停止，不使用强制覆盖。

这是终端触发更新，不是应用内静默安装。Sparkle 在当前临时签名与库验证组合下未通过加载门槛，没有加入应用或降低系统安全保护。

## 升级与边界

macOS 14+、Apple Silicon；构建 15。仍为临时签名、未经过 Apple 公证的预发布包，不关闭 Gatekeeper。先完成或安全取消后台任务、解决恢复提示、退出旧版并备份，再从 DMG 拖动替换。图库位置和 Bundle ID 不变，无数据库结构迁移，不自动移动真实照片。

移动导致旧路径失效；其他软件不会自动更新。未解决的跨来源移动任务不能交给旧版恢复；恢复数据库备份不能代替文件撤销。重复或父子来源冲突、离线及权限失效保守跳过。

Debug／Release 构建、22 项 JingXuChecks 和 10 项发布脚本测试通过。未执行 XCUITest；打包应用的实际沙盒授权、跨卷异常、Homebrew 跨版本安装与鼠标交互仍待人工验收。
