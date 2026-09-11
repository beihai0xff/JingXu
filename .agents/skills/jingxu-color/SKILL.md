---
name: jingxu-color
description: 通过镜序的本机 MCP 读取所选照片预览、进行非破坏式基础调色、套用预设并导出成片。适用于用户明确要求用镜序调色或操控镜序当前照片的任务。
---

# 镜序调色

镜序必须在同一台 Mac 上运行并已启用 AI 助手连接。使用 `jingxu` MCP 工具；未连接时引导用户打开镜序设置、启用连接，将复制的配置加入本机 Codex MCP 配置并重连。连接密钥只放在本机配置，不能放入对话、源码或日志。

## 看图与调整

- 先调用 `get_context`，确认当前照片及 `selected` 范围。单张操作带上本次返回的 `selectionToken`、`assetID`、`editVersion`，不要猜标识。
- 调用 `get_preview` 获取真实渲染图。`original=true` 是同一解码链路的未调整图；默认是当前效果。查看图像后，根据用户的风格与保留要求调整。批量中其他照片的 `editVersion` 在 `selected` 中。
- `set_adjustments` 接收稀疏参数对象，一次调用只提交需要改变的参数，未提供字段保持原值。设置值是绝对参数值，不是增量。每次提交是一整步撤销，保存失败会保留草稿。
- 范围以 `get_context` 为准。RAW 自定义白平衡使用 `whiteBalance=raw`、色温 K 和色调；普通图片使用 `whiteBalance=relative`。自定义白平衡要同时给出 temperature 和 tint；`asShot` 恢复拍摄时模式。
- 修改后重新读取上下文与预览，目视检查效果。`undo` / `redo` 只作用于当前编辑会话，不跨会话恢复历史。遇到选择、修订或文件变化，重读并重新判断；不要拿新版本盲重试旧意图。
- 不通过数据库、XMP 文件写入或界面点击绕过工具的校验。曲线、HSL、局部蒙版、LUT、生成式修图不在这些工具的能力内。

## 批量、导出与交付

- `prepare_batch` 接收 `selectionToken` 和 `adjustments` 或 `presetID`（二选一），可指定 `groups`。只处理返回的明确选择；不会扩展为整个图库。先在代表照片上看预览，检查 RAW／普通图片的白平衡适用性。
- 导出前调用 `choose_export_directory`，让用户在镜序的系统选择器中授权目录。用返回的 `directoryID` 和 `selectionToken` 调用 `prepare_export`，格式为 jpeg、png 或 tiff。
- 准备工具返回 `jobID`；通过 `get_job` 读取状态。取得 `planID` 后，向用户展示照片数量与范围、参数或预设、跳过项；导出还要展示目录、格式及重名情况。
- 批量／导出必须在用户确认这份具体清单后才调用 `execute_plan(planID)`。确认在 Codex 对话中完成，不自动填写“已确认”，也不要求用户再到镜序重复确认。工具描述本身不构成用户确认。
- `execute_plan` 返回任务，读取最终状态再报告成功。响应不确定时先查原 `jobID`；同一 `planID` 重试返回同一任务。应用重启或重新连接后旧标识失效，不自动重新生成并执行。
- `cancel_job` 停止后续工作，已完成导出保留。`undo_batch(jobID)` 生成受修订保护的撤销清单，同样展示并确认后执行。
- 交付实际成片位置和工具返回的真实效果预览。分别报告成功、跳过和失败；只改参数或只生成清单不等于已经导出。
