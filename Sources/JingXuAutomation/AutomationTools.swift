import Foundation
import JingXuCore
import MCP

public enum AutomationTools {
    public static let definitions: [Tool] = {
        let string: Value = ["type": "string", "minLength": 1]
        let patch: Value = ["type": "object", "properties": .object(Dictionary(uniqueKeysWithValues:
            ColorParameter.allCases.map { ($0.rawValue, Value.object(["type": "number"])) }
            + [("whiteBalance", ["type": "string", "enum": ["asShot", "raw", "relative"]])])), "additionalProperties": false]
        let scope: [String: Value] = ["selectionToken": string]
        let edit = scope.merging(["assetID": string, "editVersion": string]) { _, b in b }
        func tool(_ name: String, _ description: String, _ fields: [String: Value] = [:], _ required: [String]? = nil, read: Bool = false, idempotent: Bool = false) -> Tool {
            Tool(name: name, description: description,
                 inputSchema: ["type": "object", "properties": .object(fields),
                               "required": .array((required ?? fields.keys.sorted()).map { .string($0) }), "additionalProperties": false],
                 annotations: .init(readOnlyHint: read, destructiveHint: !read, idempotentHint: idempotent, openWorldHint: false))
        }
        return [
            tool("get_context", "读取镜序当前照片、明确选择范围、参数及版本。仅这些照片可被操作。", read: true),
            tool("get_preview", "读取真实 sRGB 渲染预览（最长边 2048px，无原片元数据）和直方图。original=true 表示同一解码流程的未调整效果。",
                 edit.merging(["original": ["type": "boolean"]]) { _, b in b }, Array(edit.keys), read: true),
            tool("set_adjustments", "稀疏设置当前照片参数，未提供参数保持不变。白平衡必须显式提供模式。同步镜序、一步撤销；保存成功才返回成功。先读 get_context。",
                 edit.merging(["adjustments": patch]) { _, b in b }),
            tool("undo", "撤销当前编辑会话的一步调整并保存。", edit),
            tool("redo", "重做当前编辑会话的一步调整并保存。", edit),
            tool("list_presets", "读取镜序预设及适用类型。", read: true),
            tool("save_preset", "将当前照片的实际参数保存为一个新预设。", edit.merging(["name": string]) { _, b in b }),
            tool("choose_export_directory", "在镜序弹出 macOS 文件夹选择器，用户选择后返回已授权目录标识。不会导出照片。"),
            tool("prepare_batch", "只为当前明确选择生成批量调色清单，不修改照片。adjustments 与 presetID 二选一。返回 jobID，调用 get_job 等待清单。",
                 scope.merging(["adjustments": patch, "presetID": string, "groups": ["type": "array", "minItems": 1, "uniqueItems": true,
                     "items": ["type": "string", "enum": ["tone", "whiteBalance", "color"]]]]) { _, b in b }, ["selectionToken"]),
            tool("prepare_export", "为当前明确选择准备不覆盖导出清单。directoryID 来自系统目录选择工具。返回 jobID，尚未写成片。",
                 scope.merging(["directoryID": string, "format": ["type": "string", "enum": ["jpeg", "png", "tiff"]]]) { _, b in b }),
            tool("execute_plan", "执行已展示给用户且用户已确认的固定清单。不得自行确认。相同 planID 重试返回相同 jobID。",
                 ["planID": string], idempotent: true),
            tool("get_job", "读取本连接创建的任务进度、固定清单或最终成功/跳过/失败结果。", ["jobID": string], read: true),
            tool("cancel_job", "取消本连接任务的后续工作。已完成导出保留；数据库提交结果以最终任务状态为准。", ["jobID": string], idempotent: true),
            tool("undo_batch", "为本连接已完成的批量调色准备撤销清单，展示并确认后用 execute_plan 执行。", ["jobID": string])
        ]
    }()

    public static func validate(name: String, arguments: [String: Value]) throws {
        guard let tool = definitions.first(where: { $0.name == name }), let schema = tool.inputSchema.objectValue,
              let fields = schema["properties"]?.objectValue else { throw ColorEditError("未知工具") }
        guard Set(arguments.keys).isSubset(of: Set(fields.keys)) else { throw ColorEditError("包含不支持的参数") }
        for required in schema["required"]?.arrayValue ?? [] {
            guard let key = required.stringValue, arguments[key] != nil else { throw ColorEditError("缺少必填参数") }
        }
        for (key, value) in arguments {
            guard let type = fields[key]?.objectValue?["type"]?.stringValue else { continue }
            let valid: Bool
            switch type {
            case "string": valid = value.stringValue?.isEmpty == false
            case "boolean": valid = value.boolValue != nil
            case "object": valid = value.objectValue != nil
            case "array": valid = value.arrayValue != nil
            default: valid = false
            }
            guard valid else { throw ColorEditError("参数 \(key) 类型无效") }
        }
    }

    public static func reply(_ object: [String: Value], image: Data? = nil) -> CallTool.Result {
        let value = Value.object(object)
        guard let data = try? JSONEncoder().encode(value) else {
            return .init(content: [.text(text: "无法编码操作结果，请重新读取实际状态", annotations: nil, _meta: nil)], isError: true)
        }
        let json = String(decoding: data, as: UTF8.self)
        var content: [Tool.Content] = [.text(text: json, annotations: nil, _meta: nil)]
        if let image { content.append(.image(data: image.base64EncodedString(), mimeType: "image/png", annotations: nil, _meta: nil)) }
        return .init(content: content, structuredContent: Optional.some(value), isError: false)
    }

    public static func failure(_ error: Error) -> CallTool.Result {
        let error = error as NSError
        var details: [String: Value] = ["message": .string(error.localizedDescription),
                                       "domain": .string(error.domain), "code": .int(error.code)]
        if let cause = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            details["cause"] = ["domain": .string(cause.domain), "code": .int(cause.code)]
        }
        return .init(content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
                     structuredContent: .object(["error": .object(details)]), isError: true)
    }

    public static func adjustments(_ value: ColorAdjustments) -> Value {
        var result = Dictionary(uniqueKeysWithValues: ColorParameter.allCases.map { ($0.rawValue, Value.double(value[$0])) })
        result["whiteBalance"] = .string(value.whiteBalance.rawValue)
        return .object(result)
    }

    public static func patch(_ object: [String: Value]) throws -> ColorPatch {
        guard !object.isEmpty else { throw ColorEditError("调整参数不能为空") }
        var patch = ColorPatch()
        for (key, value) in object {
            if key == "whiteBalance" {
                guard let raw = value.stringValue, let mode = ColorWhiteBalance(rawValue: raw) else { throw ColorEditError("白平衡模式无效") }
                patch.whiteBalance = mode
            } else {
                guard let parameter = ColorParameter(rawValue: key), let number = value.doubleValue ?? value.intValue.map(Double.init), number.isFinite else { throw ColorEditError("未知参数或非法数值：\(key)") }
                patch.values[parameter] = number
            }
        }
        if patch.values[.temperature] != nil || patch.values[.tint] != nil {
            guard let mode = patch.whiteBalance, mode != .asShot else { throw ColorEditError("色温或色调需要显式指定 raw 或 relative 白平衡") }
        }
        if let mode = patch.whiteBalance, mode != .asShot {
            guard patch.values[.temperature] != nil, patch.values[.tint] != nil else { throw ColorEditError("自定义白平衡需要完整的色温和色调") }
        }
        return patch
    }
}

extension Dictionary where Key == String, Value == MCP.Value {
    func requiredString(_ key: String) throws -> String {
        guard let result = self[key]?.stringValue, !result.isEmpty else { throw ColorEditError("缺少 \(key)") }
        return result
    }
}
