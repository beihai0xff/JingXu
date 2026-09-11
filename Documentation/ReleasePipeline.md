# 签名与 Homebrew 发布

工作流：[release.yml](../.github/workflows/release.yml)。GitHub Actions 是唯一 Release 发布入口，本地脚本仅校验提交并推送标签。

## 统一构建入口

本地与 CI 均调用 `Scripts/build.sh`，支持从任意工作目录执行：

```sh
zsh Scripts/build.sh check    # 元数据、发布脚本测试、Debug / Release 构建、完整回归
zsh Scripts/build.sh adhoc    # 完成同样检查，再生成临时签名测试 DMG
zsh Scripts/build.sh release  # 完成同样检查，再签名、公证并生成正式 DMG
```

省略参数等同于 `check`。三种模式使用相同的 arm64 编译参数和 `Package.resolved`，构建全部 target，直接执行已构建的 Release 版 `JingXuChecks`。两种打包模式共用应用组装、SwiftPM 资源复制、DMG 与 SHA-256 生成，仅签名、公证和安装说明不同。打包入口不推送标签或创建 Release；已有版本产物须先归档或使用新版本。

CI 的构建和签名作业固定使用 `macos-26` 与 Xcode 26.6（`DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer`），与本机生成和验证锁文件的工具链一致。本地开发也使用 Xcode 26.6；`Package.swift` 的 6.1 声明是清单语言版本。Swift 6.1 与 6.3 对依赖 traits 的解析结果不同，不能混用锁文件，也不能在 CI 中临时开启自动解析绕过固定依赖检查。应用最低运行系统仍为 macOS 14。

发布通道由工作流中的 `RELEASE_MODE` 显式指定，当前为 `adhoc`。它直接调用 `build.sh adhoc`，不读取证书或公证凭据。`release` 通道由 `Scripts/ci-package-app.sh` 准备、清理临时签名凭据，再调用 `build.sh release`。构建和打包逻辑只维护在 `build.sh`；正式签名失败不切换通道。

## 触发与执行顺序

| 触发 | 执行内容 |
| --- | --- |
| 推送 `main` | 元数据检查、发布脚本测试、Debug / Release 构建、完整 JingXuChecks；不读取签名凭据，不打包发布 |
| 手动 Run workflow | 同上，仅验证；即使选中标签也不发布 |
| 推送 `v*` 标签 | 构建回归 → 按显式通道打包签名 → 发布 Release → 更新 Homebrew Cask |

标签必须为 `v主版本.次版本.补丁`，与 `Packaging/Info.plist` 一致，指向已合入 `main` 的提交。签名任务按触发事件的完整 commit SHA 检出源码，发布前再次核对远端标签，防止发布期间标签被移动。

两种通道共用版本校验、草稿资产摘要校验和 Cask 更新。

- `adhoc`：完整构建回归后执行 ad-hoc 签名和验证，生成 `JingXu-<版本>-test.<构建号>-macOS-arm64.dmg`，以 GitHub 预发布版公开；应用、安装说明、Release 和 Cask 均注明未经 Apple 公证，不宣称已通过 Gatekeeper。
- `release`：需要下述 Developer ID 与公证凭据，生成不带 `test` 的 DMG，以正式 Release 公开。切换通道需修改工作流并审核合入，不能将已经发布的同一版本重签换包。

`release` 通道依次执行：

1. 将 Developer ID Application 证书和私钥导入临时钥匙串，并验证公证凭据。
2. 调用 `Scripts/build.sh release`：元数据与脚本测试、Debug / Release 构建及完整回归，然后进行 Hardened Runtime 与时间戳签名、核对 Team ID、应用公证 Accepted、附加并验证票据及 Gatekeeper 评估。
3. 创建 DMG，签名、公证 Accepted、附加并验证票据，生成 SHA-256。
4. 上传已验证产物，创建 GitHub Release 草稿，核对 DMG 和校验文件的服务端摘要，再公开为正式 Release。
5. 从已公开 Release 读取 DMG 摘要，生成新 Cask，以 GitHub Contents API 的文件 SHA 作并发保护更新 `main`。

标签发布的构建和回归由 `sign` 作业中的统一脚本执行，跳过普通 `build` 作业，避免在两个 runner 上重复编译。该通道要求的凭据、构建、回归、签名、公证、票据或摘要检查任一失败，均停止后续发布。普通提交不生成安装包。`adhoc` 是明确选择的预发布通道，不是签名失败的降级路径。

## Developer ID 通道的一次性配置

当前 `adhoc` 通道不要求下列凭据。

在仓库 **Settings → Environments** 创建 `release` 环境，将允许部署的标签限制为 `v*`。签名作业使用该环境的配置。配置方式参考 [GitHub 官方证书导入指南](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)。

在 `release` 环境中添加以下 **Secrets**：

| 名称 | 内容 |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | 包含 Developer ID Application 证书和配套私钥的加密 `.p12` 文件，Base64 编码 |
| `DEVELOPER_ID_P12_PASSWORD` | 导出该 `.p12` 时设置的非空密码 |
| `APPLE_APP_SPECIFIC_PASSWORD` | Apple 开发者账户的 App 专用密码，用于 `notarytool` 公证 |

在同一环境中添加以下 **Variables**：

| 名称 | 内容 |
| --- | --- |
| `DEVELOPER_ID_APPLICATION` | 完整证书名称，例如 `Developer ID Application: Example Name (TEAMID)` |
| `DEVELOPER_TEAM_ID` | 对应的 Team ID |
| `APPLE_ID` | 有权为该团队提交公证的 Apple 账户邮箱 |

在本机钥匙串「我的证书」中选择 Developer ID Application 签名身份，连同私钥导出为有密码保护的 `.p12`。不是只有公钥的 `.cer`，也不是 Apple Development 或 Developer ID Installer 证书。将文件保存在仓库外，可用下面的命令将编码结果放入剪贴板，再粘贴到 GitHub Secret：

```sh
base64 -i /path/outside-repo/DeveloperID.p12 | pbcopy
```

不要把证书、私钥、专用密码或 Base64 内容写入仓库、Release 或日志。临时钥匙串密码每次随机生成，不需要额外配置 Secret。`Scripts/ci-package-app.sh` 使用独立钥匙串，不修改默认钥匙串或搜索列表；成功、失败或终止时清理，GitHub 托管 runner 在作业结束后销毁。该脚本仅用于 GitHub Actions。

发布及更新 Cask 使用内置 `GITHUB_TOKEN`，相应作业已声明 `contents: write`；不需要另加 PAT。若分支保护阻止更新 Cask，保留保护规则，通过 PR 更新生成的 Cask。

## 发布新版本

1. 更新 `Packaging/Info.plist` 的版本号和递增构建号，新增对应 `Documentation/Release-<版本>.md`，同步需要变动的安装说明。已有版本资产不得覆盖；切换签名通道也必须使用新版本。
2. 按 [发布检查清单](../Packaging/ReleaseChecklist.md) 验证本次提交，记录实际证据和未验收项。预发布版不得将尚未执行的覆盖升级、目录授权或 Gatekeeper 安装标为通过。
3. 提交并合入 `main`，等待构建通过。确认所选通道的要求满足后，在干净且与 `origin/main` 一致的检出上执行：

   ```sh
   export RELEASE_ACCEPTANCE_COMMIT="已完成本次发布检查的完整提交 SHA"
   zsh Scripts/publish-release.sh
   ```

   脚本校验版本和说明，创建并推送版本标签；不在本机打包或创建 Release，不需要本机安装 `gh`。该变量确认检查对象，不会代替人工验收或将未通过项标为通过。也可以自行推送符合条件的新标签，要求相同。

4. 查看 Actions 的 `sign`、`publish`、`update-cask` 作业（标签发布跳过 `build`）。成功后在 Releases 核对下载文件，并检查 `Casks/jingxu.rb` 的版本、摘要与签名说明。
5. 使用独立安装环境验证 Homebrew 更新及首次启动。脚本通过不代表真实界面、图库授权或覆盖升级已经验收。

## 本机签名验证

本机具备有效签名身份并用 `xcrun notarytool store-credentials` 配置钥匙串后，可设置以下三个变量运行 `zsh Scripts/build.sh release`：

- `DEVELOPER_ID_APPLICATION`
- `DEVELOPER_TEAM_ID`
- `NOTARY_KEYCHAIN_PROFILE`

该命令仅生成安装包，不推送标签或发布。CI 额外设置 `NOTARY_KEYCHAIN_PATH`，让签名与公证都使用隔离钥匙串。本机默认使用正常钥匙串搜索列表。

## 失败与重试

- 已有 Release（含草稿）不覆盖，已公开版本不重签换包。不要强制移动标签。
- 公证或签名失败时不会上传 Release 产物。先查看作业错误；修复凭据后可以重跑同一未发布版本。若要修复源码，使用新的提交和版本。
- 上传或服务端摘要核对失败时保留草稿，不自动公开；先核对该草稿与对应 Actions 产物，不能删除并覆盖一个已公开版本。
- Release 成功而 Cask 更新失败时，Release 保留，Cask 保持旧值；修复权限后重跑更新作业，或通过 PR 提交生成结果。
- Cask 只接受已公开的数字版本标签，允许正式版和明确带 `test.<构建号>` 产物的预发布版；拒绝草稿、通道与文件名不一致、倒退版本、同版本摘要变化、缺失摘要和错误下载地址。同版本同摘要重复执行不写入。
- Cask 由 `Packaging/jingxu.rb.template` 生成。安装规则的修改应落到模板；当前已发布版本的 `Casks/jingxu.rb` 保留对应产物事实，新模板只在下一次成功发布后生效。

## 本地校验

```sh
python3 -m unittest discover -s Tests/ReleasePipeline -v
bash -n Scripts/ci-package-app.sh
zsh -n Scripts/build.sh Scripts/publish-release.sh
ruby -c Casks/jingxu.rb
actionlint .github/workflows/release.yml
```

测试使用临时目录、模拟钥匙串命令和本地 Git 仓库，不导入真实私钥、不请求 Apple 公证，也不向 GitHub 发布。真实签名、公证与 Homebrew 升级仍需在配置凭据后的新版本上验证。
