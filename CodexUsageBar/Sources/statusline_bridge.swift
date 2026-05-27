import Foundation

struct BridgeWindow: Encodable {
    let used_percentage: Double
    let resets_at: Double?
}

struct BridgePayload: Encodable {
    let source: String
    let updated_at: Double
    let version: String?
    let model: String?
    let rate_limits: [String: BridgeWindow?]
}

func numberValue(_ value: Any?) -> Double? {
    switch value {
    case let number as NSNumber:
        return number.doubleValue
    case let string as String:
        return Double(string)
    default:
        return nil
    }
}

func resetValue(_ value: Any?) -> Double? {
    if let number = numberValue(value) {
        return number > 1_000_000_000_000 ? floor(number / 1000) : number
    }
    if let string = value as? String,
       let date = ISO8601DateFormatter().date(from: string) {
        return date.timeIntervalSince1970
    }
    return nil
}

func normalizeWindow(_ value: Any?) -> BridgeWindow? {
    guard let raw = value as? [String: Any],
          let used = numberValue(raw["used_percentage"] ?? raw["usedPercent"]) else {
        return nil
    }
    return BridgeWindow(
        used_percentage: used,
        resets_at: resetValue(raw["resets_at"] ?? raw["resetsAt"])
    )
}

func modelName(_ value: Any?) -> String? {
    if let string = value as? String {
        return string
    }
    guard let raw = value as? [String: Any] else {
        return nil
    }
    return raw["display_name"] as? String ?? raw["name"] as? String ?? raw["id"] as? String
}

func formatPercent(_ value: Double?) -> String {
    guard let value else { return "--" }
    if value.rounded() == value {
        return "\(Int(value))%"
    }
    return String(format: "%.1f%%", value)
}

do {
    let inputData = FileHandle.standardInput.readDataToEndOfFile()
    let input = inputData.isEmpty
        ? [:]
        : ((try JSONSerialization.jsonObject(with: inputData) as? [String: Any]) ?? [:])
    let rateLimits = (input["rate_limits"] as? [String: Any])
        ?? (input["rateLimits"] as? [String: Any])
        ?? [:]
    let fiveHour = normalizeWindow(rateLimits["five_hour"] ?? rateLimits["5_hour"])
    let sevenDay = normalizeWindow(rateLimits["seven_day"] ?? rateLimits["7_day"])

    let payload = BridgePayload(
        source: "claude-code-statusline",
        updated_at: Date().timeIntervalSince1970,
        version: input["version"] as? String,
        model: modelName(input["model"]),
        rate_limits: [
            "five_hour": fiveHour,
            "seven_day": sevenDay
        ]
    )

    let cacheDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/usage-bar")
    let cacheURL = cacheDir.appendingPathComponent("latest.json")
    try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(payload)
    let tmpURL = cacheDir.appendingPathComponent("latest.json.\(ProcessInfo.processInfo.processIdentifier).tmp")
    try data.write(to: tmpURL)
    _ = try FileManager.default.replaceItemAt(cacheURL, withItemAt: tmpURL)

    let five = fiveHour?.used_percentage
    let seven = sevenDay?.used_percentage
    if five == nil && seven == nil {
        print("Claude usage waiting")
    } else {
        print("Claude 5h \(formatPercent(five)) - 7d \(formatPercent(seven))")
    }
} catch {
    print("Claude usage bridge error")
}
