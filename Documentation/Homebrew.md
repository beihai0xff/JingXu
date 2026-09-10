# Homebrew Cask 安装与更新

复用公开 JingXu 仓库作为 tap；仅支持 Apple Silicon、macOS 14+。

```sh
brew tap beihai0xff/jingxu https://github.com/beihai0xff/JingXu.git
brew install --cask beihai0xff/jingxu/jingxu
```

已手动安装同一版本时，先退出镜序，再使用：

```sh
brew install --cask --adopt beihai0xff/jingxu/jingxu
```

`--adopt` 只接管与发布包完全相同的应用。如果失败，不要使用 `--force`；先保留原应用备份并核对版本和签名，再人工处理。不要删除图库目录。

后续更新前，在应用内完成或安全取消导入、扫描、分析、归档和删除任务，解决恢复提示，然后正常退出应用。0.3.0 不迁移 0.2.x 或更早图库，旧格式会被拒绝打开并保留原库。需要继续使用旧图库时应保留匹配的旧版应用，不宜直接执行升级。请先阅读 [0.3.0 发布说明](Release-0.3.0.md)。

```sh
brew update
brew outdated --cask beihai0xff/jingxu/jingxu
brew upgrade --cask beihai0xff/jingxu/jingxu
open /Applications/镜序.app
```

这是终端触发的包管理更新，不是应用内更新，不会每天自动安装，也不保证阻止用户在应用运行中执行升级。Cask 只安装应用，不配置 zap、强制退出、图库删除或系统保护绕过脚本。图库继续存放在原沙盒 Application Support 中，新版在写入前检查图库格式，不执行历史迁移；建议更新前自行备份图库。Homebrew 更新本身不会转换或备份图库，也不能代替归档恢复流程。

当前发布通道为 ad-hoc 签名、未经 Apple 公证的预发布版，成功发布后同步此 tap。以所装版本的 Release 和 Cask 说明为准。Homebrew SHA-256 校验不能替代签名与公证。保持默认 quarantine/Gatekeeper，不使用 `--no-quarantine`、移除隔离属性或关闭安全保护。系统拒绝启动时停止，不能保证免费分发在每台机器上都无提示运行。

## 发布维护

tag 流水线按工作流中的显式 `RELEASE_MODE` 完成构建、测试及签名。当前 `adhoc` 通道公开带 `test.<构建号>` 安装包的预发布版；`release` 通道要求 Developer ID 签名及 Apple 公证。上传及服务端摘要验证成功、Release 公开后，独立 `update-cask` 作业更新 main 的 Cask。详见 [发布流水线说明](ReleasePipeline.md)。Release 与 Cask 写入使用当前仓库的 `GITHUB_TOKEN` contents:write；只接受 `v数字.数字.数字` 的已公开版本，拒绝草稿或通道与安装包名称不一致的版本。

新 Cask 从 `Packaging/jingxu.rb.template` 生成，根据发布通道写入实际安装包名和签名说明；已发布版本不会被重签或换包。脚本拒绝旧版本回退、同版本摘要变化、错误资源地址和缺失摘要。更新以 Contents API 的文件 SHA 作并发保护，不强推、不覆盖版本资产。分支保护禁止机器人直接提交时，作业明确失败：Release 保留，Cask 仍为旧版本，维护者需通过 PR 更新 Cask；不要为此自动取消分支保护。

合入前验证：运行 `python3 -m unittest discover -s Tests/ReleasePipeline -v`、Ruby 语法检查及 actionlint。真实接管与跨版本升级需要独立安装验证；不可只以脚本测试通过宣称应用升级已验收。
