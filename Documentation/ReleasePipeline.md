# 按标签自动打包发布

工作流：`.github/workflows/release.yml`（macOS build and tag release）。

## 触发方式

- 推送 `main`：校验版本元数据、Debug / Release 构建、完整 Release 回归、生成并验证临时签名 DMG，保留 Actions 构建产物 14 天；不创建 Release。
- 手动 Run workflow：同上，只构建，不发布。
- 推送 `v*` 标签：全部验证成功后创建预发布 Release，上传 DMG 和 SHA-256 校验文件，核对 GitHub 服务端摘要后公开。

只有新增标签会触发，不会重新处理历史标签。标签必须为 `v主版本.次版本.补丁`，与 `Packaging/Info.plist` 版本完全一致，并指向已合入 `main` 的提交。非法版本、缺少说明、失败的构建／回归／校验都会阻止发布。

## 发布步骤

1. 修改 `Packaging/Info.plist` 的版本号及递增构建号，同步 `Packaging/TestUpgrade-zh-Hans.txt`，新增 `Documentation/Release-<版本>.md`。
2. 提交并合入 `main`，等待主分支构建通过。
3. 在该提交创建并推送标签，例如下一版使用 `v0.2.5`：

   ```sh
   git switch main
   git pull --ff-only
   git tag -a v0.2.5 -m 'JingXu v0.2.5'
   git push origin v0.2.5
   ```

4. 在 Actions 查看执行结果，在 Releases 下载 DMG。

## 权限与失败恢复

使用 [GitHub 提供的 arm64 macOS runner](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)。构建任务只有仓库读取权限；发布任务通过 `GITHUB_TOKEN` 获得 `contents: write`，无需 PAT、SSH 私钥或 Apple 凭据。第三方 Action 固定到完整提交 SHA；不缓存用户数据，不接入真实图库。

同一 ref 的任务排队、不互相取消。已有 Release（含草稿）会报错停止，绝不覆盖安装包。上传或摘要验证失败时保留草稿，不自动公开；修复前先检查草稿和已上传文件。不要删除公开版本或强制移动标签来重试，优先发布新版本。

流水线只发布未公证预发布包，不声称完成 Gatekeeper 或沙盒 UI 人工验收，不调用正式签名发布脚本，也不以临时签名冒充 Developer ID 签名。正式公证发布须另行配置钥匙串、证书与凭据后扩展工作流。
