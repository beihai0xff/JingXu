import Foundation

/// Deliberately accepts a small, explicit parameter vocabulary. No best-effort effect dropping.
public enum ColorXMPImporter {
    public static func parse(_ data: Data, suggestedName: String) throws -> ColorPreset {
        guard data.count <= 2 * 1024 * 1024, let text = String(data: data, encoding: .utf8),
              !text.localizedCaseInsensitiveContains("<!DOCTYPE"), !text.localizedCaseInsensitiveContains("<!ENTITY") else {
            throw ColorEditError("XMP 必须为不超过 2 MB 的 UTF-8 文件，且不能包含 DTD 或外部实体")
        }
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        let parsed = parser.parse()
        guard parsed, reader.errors.isEmpty else {
            throw ColorEditError((reader.errors.isEmpty ? ["XMP XML 无效：\(parser.parserError?.localizedDescription ?? "未知错误")"] : reader.errors.sorted()).joined(separator: "\n"))
        }
        return try makePreset(reader.fields, suggestedName: suggestedName)
    }
    private static let controls: [String: ColorParameter] = ["Exposure2012": .exposure, "Contrast2012": .contrast,
        "Highlights2012": .highlights, "Shadows2012": .shadows, "Whites2012": .whites, "Blacks2012": .blacks,
        "Saturation": .saturation, "Vibrance": .vibrance, "Temperature": .temperature, "Tint": .tint]
    private static let metadata: Set<String> = ["Name", "Group", "Description", "UUID", "Author", "Copyright", "Version",
        "ProcessVersion", "PresetType", "SupportsColor", "SupportsMonochrome", "SupportsHighDynamicRange",
        "SupportsNormalDynamicRange", "SupportsSceneReferred", "SupportsOutputReferred", "CameraModelRestriction", "HasSettings", "HasCrop"]
    private static func makePreset(_ fields: [String: String], suggestedName: String) throws -> ColorPreset {
        var errors: [String] = []
        var patch = ColorPatch()
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            if let parameter = controls[name] {
                guard let number = Double(value), number.isFinite, parameter.range(isRAW: true).contains(number) else {
                    errors.append("\(name)：数值无效或超出范围"); continue
                }
                patch.values[parameter] = number
            } else if name != "WhiteBalance", !metadata.contains(name) { errors.append("\(name)：不支持的效果参数") }
        }
        switch fields["WhiteBalance"] {
        case "As Shot":
            patch.whiteBalance = .asShot
            if fields["Temperature"] != nil || fields["Tint"] != nil { errors.append("拍摄时白平衡不能同时指定自定义色温／色调") }
        case "Custom":
            patch.whiteBalance = .raw
            if fields["Temperature"] == nil || fields["Tint"] == nil { errors.append("自定义白平衡需同时包含 Temperature 和 Tint") }
        case nil:
            if fields["Temperature"] != nil || fields["Tint"] != nil { errors.append("色温／色调缺少 WhiteBalance=Custom") }
        default: errors.append("WhiteBalance：仅支持 As Shot 或 Custom")
        }
        if let type = fields["PresetType"], type != "Normal" { errors.append("PresetType：仅支持普通参数预设") }
        if let restriction = fields["CameraModelRestriction"], !restriction.isEmpty { errors.append("CameraModelRestriction：不支持专属相机限制") }
        for (name, value) in fields where name.hasPrefix("Supports") || name == "HasSettings" || name == "HasCrop" {
            if !["True", "False", "true", "false"].contains(value) { errors.append("\(name)：布尔值无效") }
        }
        if fields["HasCrop"]?.lowercased() == "true" { errors.append("HasCrop：不支持裁剪预设") }
        let scene = fields["SupportsSceneReferred"]?.lowercased() != "false"
        let output = fields["SupportsOutputReferred"]?.lowercased() != "false"
        if !scene && !output { errors.append("预设不支持 RAW 或普通图片") }
        else if !scene { patch.target = .rendered }
        else if !output { patch.target = .raw }
        if patch.whiteBalance == .raw {
            if patch.target == .rendered { errors.append("绝对色温与普通图片限定冲突") }
        }
        if patch.values.isEmpty && patch.whiteBalance == nil { errors.append("未找到可导入的基础调色参数；普通评分／标签 XMP 不是调色预设") }
        guard errors.isEmpty else { throw ColorEditError("未导入预设：\n" + errors.joined(separator: "\n")) }
        let name = fields["Name"].flatMap { $0.isEmpty ? nil : $0 } ?? suggestedName
        return try ColorPreset(name: name, patch: patch)
    }

    private final class Reader: NSObject, XMLParserDelegate {
        static let namespace = "http://ns.adobe.com/camera-raw-settings/1.0/"
        struct Frame { let field: String?; var text = "" }
        var fields: [String: String] = [:], errors: [String] = []
        var prefixes: [String: [String]] = [:]
        var stack: [Frame] = []
        func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) { prefixes[prefix, default: []].append(namespaceURI) }
        func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) { _ = prefixes[prefix]?.popLast() }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
            guard stack.count < 32 else { errors.append("XMP 嵌套过深"); parser.abortParsing(); return }
            let field = namespaceURI == Self.namespace ? elementName : nil
            if let field, controls[field] == nil, field != "WhiteBalance", !metadata.contains(field) { errors.append("\(field)：不支持的效果参数") }
            stack.append(Frame(field: field))
            for (key, value) in attributes {
                let parts = key.split(separator: ":", maxSplits: 1)
                if parts.count == 2, prefixes[String(parts[0])]?.last == Self.namespace { record(String(parts[1]), value: value) }
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if !stack.isEmpty { stack[stack.count - 1].text += string } }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if let text = String(data: CDATABlock, encoding: .utf8), !stack.isEmpty { stack[stack.count - 1].text += text }
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            guard let frame = stack.popLast() else { return }
            if let field = frame.field { record(field, value: frame.text) }
            if !stack.isEmpty { stack[stack.count - 1].text += frame.text }
        }
        private func record(_ field: String, value: String) {
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let old = fields[field], old != value { errors.append("\(field)：属性值冲突") }
            fields[field] = value
        }
    }
}
