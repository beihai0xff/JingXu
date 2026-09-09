# 程序内更新：前置兼容性门槛未通过

## 结论

本机隔离实测：保留现有 **ad-hoc 临时签名、App Sandbox、Hardened Runtime** 时，Sparkle 2.9.6 动态框架无法加载。基线应用正常退出，Sparkle 对照应用在进入业务代码之前被 dyld 中止。因此按照实施方案停止后续自动安装集成。

这不是下载失败、缺少更新包 Ed25519 签名或普通的文件查找错误。加载器找到了应用内的 Sparkle.framework，但拒绝其代码签名；免费更新包签名不能替代 macOS 的动态库信任判断。

## 可复现测试

- 环境：Apple Silicon，macOS 26.6.2（25G83），Swift 6.3.3，Command Line Tools；编译目标 macOS 14。
- 依赖：官方 Sparkle 2.9.6 分发包。
- SHA-256：`52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192`，已与官方 Release API 对照。
- 两个最小应用均使用仓库原有 `JingXu.entitlements`、`codesign --sign - --options runtime`，独立 Bundle ID，不访问镜序图库。
- 对照应用额外嵌入 Sparkle、设置 framework rpath，并将框架重新作 ad-hoc + runtime 签名。应用及嵌入框架的静态签名检查通过。
- 不含 Sparkle：退出码 0，输出 `BASELINE_LOADED`。
- 含 Sparkle：退出码 134（SIGABRT），未到达 `SPARKLE_LOADED`。

关键错误：

```text
Library not loaded: @rpath/Sparkle.framework/Versions/B/Sparkle
code signature ... not valid for use in process:
mapping process and mapped file (non-platform) have different Team IDs
```

复现命令（只生成临时测试应用，不替换安装）：

```sh
bash Scripts/check-update-compatibility.sh /path/to/Sparkle-2.9.6.tar.xz
```

脚本先验证固定分发包校验值，再输出证据目录。退出码 78 表示 Sparkle 加载失败并阻止集成；基线失败则退出 1，不能视为 Sparkle 不兼容证据。即使将来返回 0，也仅表示加载阶段通过，不能作为完整自动更新验收。

本次详细输出位于本机 `/tmp/jingxu-update-compatibility.4CZWAJ/`；临时目录可被系统清理。永久保留的是复现代码和本报告，不把第三方二进制或崩溃日志提交进仓库。

## 已停止的后续工作

没有增加应用更新入口、Sparkle 生产依赖或联网权限，没有生成签名密钥、配置 GitHub Secrets、修改发布流程、发布新版本或替换本地应用；未关闭沙盒、库验证、Hardened Runtime 或 Gatekeeper。

XPC、两个版本之间的下载/校验/替换/重启、各类故障与图库一致性验收均未执行，因为第一道框架加载门槛已失败。未执行 XCUITest；不能据此宣称所有 macOS 版本均不兼容，也不能宣称自动更新已实现。

继续实施需要另行确定能够满足 macOS 库验证的代码签名条件，再重新运行加载门槛及完整两版本升级测试。Ed25519 更新包签名仍然是必要的独立保护，不应移除。关于临时签名与 Library Validation 的限制，参见 [Sparkle 官方集成说明](https://sparkle-project.org/documentation/)，以及 [沙盒指南](https://sparkle-project.org/documentation/sandboxing/)。
