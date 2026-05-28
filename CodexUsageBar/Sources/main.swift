import Cocoa
import Foundation

struct RateLimitWindow {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: TimeInterval?

    var remainingPercent: Double {
        max(0, 100 - usedPercent)
    }
}

struct CreditsSnapshot {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: String?
}

struct CodexUsageSnapshot {
    let planType: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
    let credits: CreditsSnapshot?
    let fetchedAt: Date
}

struct ClaudeUsageSnapshot {
    let model: String?
    let fiveHour: RateLimitWindow?
    let sevenDay: RateLimitWindow?
    let updatedAt: Date
    let isStale: Bool
}

struct ClaudeAuthStatus {
    let loggedIn: Bool
    let authMethod: String?
    let subscriptionType: String?
}

struct ClaudeSetupStatus {
    let bridgeInstalled: Bool
    let claudeCodeAvailable: Bool
    let claudeCodePath: String?
}

enum UsageError: Error, LocalizedError {
    case codexMissing
    case appServerExited(String)
    case jsonRpcError(String)
    case timeout
    case invalidResponse
    case claudeCacheInvalid

    var errorDescription: String? {
        switch self {
        case .codexMissing:
            return "找不到 Codex CLI"
        case .appServerExited(let message):
            return "Codex app-server 已結束：\(message)"
        case .jsonRpcError(let message):
            return message
        case .timeout:
            return "讀取用量逾時"
        case .invalidResponse:
            return "Codex 回傳格式無法解析"
        case .claudeCacheInvalid:
            return "Claude 快取格式無法解析"
        }
    }
}

final class CodexUsageClient {
    private let codexPath = "/Applications/Codex.app/Contents/Resources/codex"

    private final class RPCState: @unchecked Sendable {
        let lock = NSLock()
        var didResume = false
        var outputBuffer = Data()
        var errorBuffer = Data()
    }

    func fetchUsage(timeout: TimeInterval = 18) async throws -> CodexUsageSnapshot {
        guard FileManager.default.isExecutableFile(atPath: codexPath) else {
            throw UsageError.codexMissing
        }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: codexPath)
            process.arguments = ["app-server", "--listen", "stdio://"]

            let stdin = Pipe()
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr

            let state = RPCState()

            @Sendable func finish(_ result: Result<CodexUsageSnapshot, Error>) {
                state.lock.lock()
                defer { state.lock.unlock() }
                guard !state.didResume else { return }
                state.didResume = true
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                try? stdin.fileHandleForWriting.close()
                if process.isRunning {
                    process.terminate()
                }
                continuation.resume(with: result)
            }

            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                state.lock.lock()
                state.errorBuffer.append(data)
                state.lock.unlock()
            }

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }

                state.lock.lock()
                state.outputBuffer.append(data)
                let lines = String(data: state.outputBuffer, encoding: .utf8)?.split(separator: "\n", omittingEmptySubsequences: false) ?? []
                let hasCompleteLine = state.outputBuffer.last == 10
                let completeLines = hasCompleteLine ? lines : lines.dropLast()
                if hasCompleteLine {
                    state.outputBuffer.removeAll()
                } else if let last = lines.last {
                    state.outputBuffer = Data(String(last).utf8)
                }
                state.lock.unlock()

                for line in completeLines {
                    guard let lineData = String(line).data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                        continue
                    }
                    guard (json["id"] as? Int) == 2 else { continue }
                    if let error = json["error"] {
                        finish(.failure(UsageError.jsonRpcError(String(describing: error))))
                        return
                    }
                    guard let result = json["result"] as? [String: Any],
                          let snapshot = Self.parseSnapshot(result) else {
                        finish(.failure(UsageError.invalidResponse))
                        return
                    }
                    finish(.success(snapshot))
                }
            }

            process.terminationHandler = { _ in
                state.lock.lock()
                let stderrText = String(data: state.errorBuffer, encoding: .utf8) ?? ""
                let alreadyDone = state.didResume
                state.lock.unlock()
                if !alreadyDone {
                    finish(.failure(UsageError.appServerExited(stderrText.trimmingCharacters(in: .whitespacesAndNewlines))))
                }
            }

            do {
                try process.run()
            } catch {
                finish(.failure(error))
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(.failure(UsageError.timeout))
            }

            Self.send([
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "ai-usage-bar",
                        "title": "AI Usage Bar",
                        "version": "0.2.0"
                    ],
                    "capabilities": [
                        "experimentalApi": true,
                        "requestAttestation": false,
                        "optOutNotificationMethods": []
                    ]
                ]
            ], to: stdin)

            DispatchQueue.global().asyncAfter(deadline: .now() + 0.35) {
                Self.send([
                    "id": 2,
                    "method": "account/rateLimits/read"
                ], to: stdin)
            }
        }
    }

    private static func send(_ object: [String: Any], to pipe: Pipe) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")
        try? pipe.fileHandleForWriting.write(contentsOf: Data(line.utf8))
    }

    private static func parseSnapshot(_ result: [String: Any]) -> CodexUsageSnapshot? {
        let byLimit = result["rateLimitsByLimitId"] as? [String: Any]
        let codex = byLimit?["codex"] as? [String: Any]
        let fallback = result["rateLimits"] as? [String: Any]
        guard let raw = codex ?? fallback else { return nil }

        return CodexUsageSnapshot(
            planType: raw["planType"] as? String,
            primary: parseWindow(raw["primary"]),
            secondary: parseWindow(raw["secondary"]),
            credits: parseCredits(raw["credits"]),
            fetchedAt: Date()
        )
    }

    private static func parseWindow(_ value: Any?) -> RateLimitWindow? {
        guard let raw = value as? [String: Any],
              let used = numeric(raw["usedPercent"]) else { return nil }
        return RateLimitWindow(
            usedPercent: used,
            windowDurationMins: numeric(raw["windowDurationMins"]).map { Int($0) },
            resetsAt: numeric(raw["resetsAt"])
        )
    }

    private static func parseCredits(_ value: Any?) -> CreditsSnapshot? {
        guard let raw = value as? [String: Any],
              let hasCredits = raw["hasCredits"] as? Bool,
              let unlimited = raw["unlimited"] as? Bool else { return nil }
        return CreditsSnapshot(
            hasCredits: hasCredits,
            unlimited: unlimited,
            balance: raw["balance"] as? String
        )
    }
}

final class ClaudeUsageClient {
    private let cacheURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/usage-bar/latest.json")
    private let bridgeURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/usage-bar/statusline-bridge")
    private let settingsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")

    func readUsage(staleAfter: TimeInterval = 600) throws -> ClaudeUsageSnapshot? {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: cacheURL)
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.claudeCacheInvalid
        }

        let rateLimits = (raw["rate_limits"] as? [String: Any]) ?? (raw["rateLimits"] as? [String: Any])
        guard let rateLimits else {
            throw UsageError.claudeCacheInvalid
        }

        let updatedSeconds = numeric(raw["updated_at"]) ?? numeric(raw["updatedAt"]) ?? Date().timeIntervalSince1970
        let updatedAt = Date(timeIntervalSince1970: updatedSeconds)
        let model = raw["model"] as? String

        return ClaudeUsageSnapshot(
            model: model,
            fiveHour: Self.parseWindow(rateLimits["five_hour"] ?? rateLimits["5_hour"], durationMins: 300),
            sevenDay: Self.parseWindow(rateLimits["seven_day"] ?? rateLimits["7_day"], durationMins: 10_080),
            updatedAt: updatedAt,
            isStale: Date().timeIntervalSince(updatedAt) > staleAfter
        )
    }

    func readAuthStatus() -> ClaudeAuthStatus? {
        guard let claudePath = Self.findClaudeCodePath() else {
            return nil
        }
        guard FileManager.default.isExecutableFile(atPath: claudePath) else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = ["auth", "status", "--json"]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let loggedIn = raw["loggedIn"] as? Bool else {
            return nil
        }

        return ClaudeAuthStatus(
            loggedIn: loggedIn,
            authMethod: raw["authMethod"] as? String,
            subscriptionType: raw["subscriptionType"] as? String
        )
    }

    func setupStatus() -> ClaudeSetupStatus {
        let path = Self.findClaudeCodePath()
        return ClaudeSetupStatus(
            bridgeInstalled: isBridgeInstalled(),
            claudeCodeAvailable: path != nil,
            claudeCodePath: path
        )
    }

    func installBridge() throws {
        guard let sourceURL = Bundle.main.url(forResource: "statusline-bridge", withExtension: nil) else {
            throw NSError(domain: "AIUsageBar", code: 1, userInfo: [NSLocalizedDescriptionKey: "App bundle 缺少 Claude statusline bridge"])
        }

        let manager = FileManager.default
        try manager.createDirectory(at: bridgeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: bridgeURL.path) {
            try manager.removeItem(at: bridgeURL)
        }
        try manager.copyItem(at: sourceURL, to: bridgeURL)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bridgeURL.path)

        var settings: [String: Any] = [:]
        if manager.fileExists(atPath: settingsURL.path) {
            let data = try Data(contentsOf: settingsURL)
            settings = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }

        if let existing = settings["statusLine"] as? [String: Any],
           existing["command"] as? String != bridgeURL.path {
            let backupURL = bridgeURL.deletingLastPathComponent().appendingPathComponent("previous-statusline.json")
            let backup: [String: Any] = [
                "saved_at": ISO8601DateFormatter().string(from: Date()),
                "statusLine": existing
            ]
            let backupData = try JSONSerialization.data(withJSONObject: backup, options: [.prettyPrinted, .sortedKeys])
            try backupData.write(to: backupURL)
        }

        settings["statusLine"] = [
            "type": "command",
            "command": bridgeURL.path,
            "refreshInterval": 10
        ]

        try manager.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsURL)
    }

    func openClaudeLogin() throws {
        guard let path = Self.findClaudeCodePath() else {
            throw NSError(domain: "AIUsageBar", code: 2, userInfo: [NSLocalizedDescriptionKey: "找不到 Claude Code"])
        }
        try openTerminal(command: "\(shellQuote(path)) auth login --claudeai")
    }

    func openClaudeCode() throws {
        guard let path = Self.findClaudeCodePath() else {
            throw NSError(domain: "AIUsageBar", code: 3, userInfo: [NSLocalizedDescriptionKey: "找不到 Claude Code"])
        }
        try openTerminal(command: shellQuote(path))
    }

    private func isBridgeInstalled() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: bridgeURL.path),
              let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let statusLine = settings["statusLine"] as? [String: Any] else {
            return false
        }
        return statusLine["type"] as? String == "command"
            && statusLine["command"] as? String == bridgeURL.path
    }

    private func openTerminal(command: String) throws {
        let script = """
        #!/bin/zsh
        \(command)
        echo
        echo 'AI Usage Bar: you can close this window when finished.'
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-usage-bar-\(UUID().uuidString).command")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func findClaudeCodePath() -> String? {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code")
        let manager = FileManager.default
        guard let versions = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return nil
        }

        return versions
            .map { $0.appendingPathComponent("claude.app/Contents/MacOS/claude").path }
            .filter { manager.isExecutableFile(atPath: $0) }
            .sorted { lhs, rhs in
                lhs.localizedStandardCompare(rhs) == .orderedDescending
            }
            .first
    }

    private static func parseWindow(_ value: Any?, durationMins: Int) -> RateLimitWindow? {
        guard let raw = value as? [String: Any],
              let used = numeric(raw["used_percentage"] ?? raw["usedPercent"]) else { return nil }
        return RateLimitWindow(
            usedPercent: used,
            windowDurationMins: durationMins,
            resetsAt: numeric(raw["resets_at"] ?? raw["resetsAt"])
        )
    }
}

func numeric(_ value: Any?) -> Double? {
    switch value {
    case let number as NSNumber:
        return number.doubleValue
    case let string as String:
        return Double(string)
    default:
        return nil
    }
}

func formatPercent(_ value: Double) -> String {
    if value.rounded() == value {
        return "\(Int(value))%"
    }
    return String(format: "%.1f%%", value)
}

final class UsageState {
    private let codexClient = CodexUsageClient()
    private let claudeClient = ClaudeUsageClient()
    private var timer: Timer?
    private var observers: [() -> Void] = []

    private(set) var codexSnapshot: CodexUsageSnapshot?
    private(set) var claudeSnapshot: ClaudeUsageSnapshot?
    private(set) var claudeAuthStatus: ClaudeAuthStatus?
    private(set) var claudeSetupStatus = ClaudeSetupStatus(bridgeInstalled: false, claudeCodeAvailable: false, claudeCodePath: nil)
    private(set) var isLoadingCodex = false
    private(set) var codexError: String?
    private(set) var claudeError: String?
    private(set) var setupMessage: String?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func observe(_ callback: @escaping () -> Void) {
        observers.append(callback)
    }

    func refresh() {
        reloadClaude()
        guard !isLoadingCodex else {
            notify()
            return
        }

        isLoadingCodex = true
        notify()

        Task {
            do {
                let fetched = try await codexClient.fetchUsage()
                await MainActor.run {
                    self.codexSnapshot = fetched
                    self.codexError = nil
                    self.isLoadingCodex = false
                    self.notify()
                }
            } catch {
                await MainActor.run {
                    self.codexError = error.localizedDescription
                    self.isLoadingCodex = false
                    self.notify()
                }
            }
        }
    }

    private func reloadClaude() {
        claudeSetupStatus = claudeClient.setupStatus()
        do {
            claudeSnapshot = try claudeClient.readUsage()
            claudeAuthStatus = claudeClient.readAuthStatus()
            claudeError = nil
        } catch {
            claudeAuthStatus = claudeClient.readAuthStatus()
            claudeError = error.localizedDescription
        }
    }

    func installClaudeBridge() {
        do {
            try claudeClient.installBridge()
            setupMessage = "Claude statusline bridge 已安裝"
            reloadClaude()
            notify()
        } catch {
            setupMessage = error.localizedDescription
            notify()
        }
    }

    func openClaudeLogin() {
        do {
            try claudeClient.openClaudeLogin()
            setupMessage = "已開啟 Claude Code 官方登入"
        } catch {
            setupMessage = error.localizedDescription
        }
        notify()
    }

    func openClaudeCode() {
        do {
            try claudeClient.openClaudeCode()
            setupMessage = "已開啟 Claude Code；送出一則訊息後會產生用量"
        } catch {
            setupMessage = error.localizedDescription
        }
        notify()
    }

    private func notify() {
        observers.forEach { $0() }
    }
}

final class ProgressRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let resetLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()

    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        valueLabel.alignment = .right
        valueLabel.lineBreakMode = .byTruncatingTail

        resetLabel.font = .systemFont(ofSize: 11, weight: .regular)
        resetLabel.textColor = .secondaryLabelColor
        resetLabel.alignment = .center

        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 100
        progress.controlSize = .small
        progress.style = .bar

        let header = NSStackView(views: [titleLabel, valueLabel])
        header.orientation = .horizontal
        header.spacing = 8
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [header, progress, resetLabel])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor),
            resetLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progress.heightAnchor.constraint(equalToConstant: 6),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 260)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(window: RateLimitWindow?, resetFormatter: DateFormatter) {
        guard let window else {
            valueLabel.stringValue = "--"
            resetLabel.stringValue = "尚無資料"
            progress.doubleValue = 0
            return
        }

        valueLabel.stringValue = "已用 \(formatPercent(window.usedPercent)) · 剩 \(formatPercent(window.remainingPercent))"
        progress.doubleValue = min(100, max(0, window.usedPercent))
        if let resetsAt = window.resetsAt {
            resetLabel.stringValue = "重置：\(resetFormatter.string(from: Date(timeIntervalSince1970: resetsAt)))"
        } else {
            resetLabel.stringValue = "重置時間未知"
        }
    }
}

final class SetupStepView: NSView {
    private let baseTitle: String
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton(title: "", target: nil, action: nil)

    init(title: String, buttonTitle: String) {
        self.baseTitle = title
        super.init(frame: .zero)
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2

        actionButton.title = buttonTitle
        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .small

        let labels = NSStackView(views: [titleLabel, detailLabel])
        labels.orientation = .vertical
        labels.spacing = 2

        let stack = NSStackView(views: [labels, actionButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        actionButton.setContentHuggingPriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setAction(target: AnyObject, action: Selector) {
        actionButton.target = target
        actionButton.action = action
    }

    func update(done: Bool, detail: String, buttonTitle: String, enabled: Bool) {
        titleLabel.stringValue = "\(done ? "OK" : "需要設定") \(baseTitle)"
        detailLabel.stringValue = detail
        actionButton.title = buttonTitle
        actionButton.isEnabled = enabled
    }
}

final class PopoverViewController: NSViewController {
    private enum Layout {
        static let width: CGFloat = 390
        static let contentWidth: CGFloat = 330
        static let minHeight: CGFloat = 380
        static let maxHeight: CGFloat = 640
    }

    private let state: UsageState
    private let titleLabel = NSTextField(labelWithString: "AI 使用量")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let codexLabel = NSTextField(labelWithString: "Codex")
    private let codexPrimaryRow = ProgressRowView(title: "Codex 5 小時額度")
    private let codexSecondaryRow = ProgressRowView(title: "Codex 7 天額度")
    private let codexInfoLabel = NSTextField(labelWithString: "")
    private let claudeLabel = NSTextField(labelWithString: "Claude")
    private let claudeFiveHourRow = ProgressRowView(title: "Claude 5 小時額度")
    private let claudeSevenDayRow = ProgressRowView(title: "Claude 7 天額度")
    private let claudeInfoLabel = NSTextField(labelWithString: "")
    private let claudeBridgeStep = SetupStepView(title: "Claude statusline bridge", buttonTitle: "安裝")
    private let claudeLoginStep = SetupStepView(title: "Claude Code 登入", buttonTitle: "登入")
    private let claudeResponseStep = SetupStepView(title: "第一次用量更新", buttonTitle: "開啟")
    private let setupMessageLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(labelWithString: "")
    private let refreshButton = NSButton(title: "刷新", target: nil, action: nil)
    private let quitButton = NSButton(title: "結束", target: nil, action: nil)
    private let resetFormatter = DateFormatter()
    private let fetchedFormatter = DateFormatter()
    private var contentStack: NSStackView?

    init(state: UsageState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
        resetFormatter.dateFormat = "M/d HH:mm"
        fetchedFormatter.dateFormat = "HH:mm:ss"
        state.observe { [weak self] in
            self?.render()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: Layout.width, height: Layout.maxHeight))
        view.wantsLayer = true
        preferredContentSize = NSSize(width: Layout.width, height: Layout.maxHeight)

        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.alignment = .center
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        subtitleLabel.maximumNumberOfLines = 2

        [codexLabel, claudeLabel].forEach {
            $0.font = .systemFont(ofSize: 14, weight: .semibold)
            $0.textColor = .labelColor
            $0.alignment = .center
        }

        [codexInfoLabel, claudeInfoLabel].forEach {
            $0.font = .systemFont(ofSize: 12)
            $0.textColor = .secondaryLabelColor
            $0.maximumNumberOfLines = 2
            $0.alignment = .center
        }

        setupMessageLabel.font = .systemFont(ofSize: 11)
        setupMessageLabel.textColor = .secondaryLabelColor
        setupMessageLabel.maximumNumberOfLines = 2

        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 3

        refreshButton.bezelStyle = .rounded
        refreshButton.controlSize = .small
        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)

        quitButton.bezelStyle = .rounded
        quitButton.controlSize = .small
        quitButton.target = self
        quitButton.action = #selector(quitTapped)

        claudeBridgeStep.setAction(target: self, action: #selector(installClaudeBridgeTapped))
        claudeLoginStep.setAction(target: self, action: #selector(loginClaudeTapped))
        claudeResponseStep.setAction(target: self, action: #selector(openClaudeCodeTapped))

        let actions = NSStackView(views: [refreshButton, quitButton])
        actions.orientation = .horizontal
        actions.spacing = 6
        actions.alignment = .centerY

        let stack = NSStackView(views: [
            titleLabel,
            subtitleLabel,
            actions,
            codexLabel,
            codexPrimaryRow,
            codexSecondaryRow,
            codexInfoLabel,
            claudeLabel,
            claudeFiveHourRow,
            claudeSevenDayRow,
            claudeInfoLabel,
            claudeBridgeStep,
            claudeLoginStep,
            claudeResponseStep,
            setupMessageLabel,
            errorLabel
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 13
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 0, bottom: 18, right: 0)
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        contentStack = stack

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            view.widthAnchor.constraint(equalToConstant: Layout.width),
            titleLabel.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            subtitleLabel.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            codexPrimaryRow.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            codexSecondaryRow.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            claudeFiveHourRow.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            claudeSevenDayRow.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            codexLabel.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            claudeLabel.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            codexInfoLabel.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            claudeInfoLabel.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            setupMessageLabel.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            errorLabel.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            claudeBridgeStep.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            claudeLoginStep.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            claudeResponseStep.widthAnchor.constraint(equalToConstant: Layout.contentWidth)
        ])

        render()
    }

    @objc private func refreshTapped() {
        state.refresh()
    }

    @objc private func quitTapped() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func installClaudeBridgeTapped() {
        state.installClaudeBridge()
    }

    @objc private func loginClaudeTapped() {
        state.openClaudeLogin()
    }

    @objc private func openClaudeCodeTapped() {
        state.openClaudeCode()
    }

    private func render() {
        refreshButton.isEnabled = !state.isLoadingCodex
        refreshButton.title = state.isLoadingCodex ? "讀取中" : "刷新"
        subtitleLabel.stringValue = "每 30 秒更新；Claude 由 statusline 快取提供"

        if let snapshot = state.codexSnapshot {
            let plan = snapshot.planType?.uppercased() ?? "UNKNOWN"
            codexLabel.stringValue = "Codex \(plan)"
            codexPrimaryRow.update(window: snapshot.primary, resetFormatter: resetFormatter)
            codexSecondaryRow.update(window: snapshot.secondary, resetFormatter: resetFormatter)
            let creditText: String
            if let credits = snapshot.credits {
                creditText = credits.unlimited ? "Credits：無限制" : "Credits：\(credits.balance ?? "未知")"
            } else {
                creditText = "Credits：尚無資料"
            }
            codexInfoLabel.stringValue = "\(creditText) · 更新於 \(fetchedFormatter.string(from: snapshot.fetchedAt))"
        } else {
            codexLabel.stringValue = "Codex"
            codexPrimaryRow.update(window: nil, resetFormatter: resetFormatter)
            codexSecondaryRow.update(window: nil, resetFormatter: resetFormatter)
            codexInfoLabel.stringValue = state.isLoadingCodex ? "正在讀取 Codex app-server..." : "尚未取得資料"
        }

        if let snapshot = state.claudeSnapshot {
            claudeLabel.stringValue = "Claude"
            claudeFiveHourRow.update(window: snapshot.fiveHour, resetFormatter: resetFormatter)
            claudeSevenDayRow.update(window: snapshot.sevenDay, resetFormatter: resetFormatter)
            let modelText = snapshot.model.map { "模型：\($0) · " } ?? ""
            claudeInfoLabel.stringValue = "\(modelText)最後更新：\(fetchedFormatter.string(from: snapshot.updatedAt)) · Claude 回應後才更新"
        } else {
            claudeLabel.stringValue = "Claude"
            claudeFiveHourRow.update(window: nil, resetFormatter: resetFormatter)
            claudeSevenDayRow.update(window: nil, resetFormatter: resetFormatter)
            if let auth = state.claudeAuthStatus, !auth.loggedIn {
                claudeInfoLabel.stringValue = "Claude Code 未登入：執行 claude auth login --claudeai"
            } else if let auth = state.claudeAuthStatus, auth.loggedIn {
                let plan = auth.subscriptionType?.uppercased() ?? auth.authMethod ?? "已登入"
                claudeInfoLabel.stringValue = "\(plan)：等待 Claude Code 第一個 API 回應"
            } else {
                claudeInfoLabel.stringValue = "尚未收到 Claude Code statusline 用量資料"
            }
        }

        let setup = state.claudeSetupStatus
        let loggedIn = state.claudeAuthStatus?.loggedIn == true
        let hasClaudeUsage = state.claudeSnapshot != nil
        let setupComplete = setup.bridgeInstalled && loggedIn && hasClaudeUsage

        claudeBridgeStep.update(
            done: setup.bridgeInstalled,
            detail: setup.bridgeInstalled ? "已寫入 Claude Code settings，只接收官方 statusline JSON" : "安全安裝，不讀 token / cookie / Keychain",
            buttonTitle: setup.bridgeInstalled ? "重裝" : "安裝",
            enabled: true
        )

        claudeLoginStep.update(
            done: loggedIn,
            detail: loggedIn ? "Claude Code 已由官方客戶端登入" : (setup.claudeCodeAvailable ? "開啟官方 Claude Code 登入流程" : "尚未找到 Claude Code"),
            buttonTitle: loggedIn ? "已登入" : "登入",
            enabled: setup.claudeCodeAvailable && !loggedIn
        )

        claudeResponseStep.update(
            done: hasClaudeUsage,
            detail: hasClaudeUsage ? "已收到 rate_limits 快取" : "登入後送出一則 Claude Code 訊息即可更新",
            buttonTitle: hasClaudeUsage ? "開啟" : "開啟",
            enabled: setup.claudeCodeAvailable
        )

        claudeBridgeStep.isHidden = setupComplete
        claudeLoginStep.isHidden = setupComplete
        claudeResponseStep.isHidden = setupComplete
        setupMessageLabel.stringValue = setupComplete ? "" : (state.setupMessage ?? "")
        setupMessageLabel.isHidden = setupComplete || setupMessageLabel.stringValue.isEmpty

        let errors = [state.codexError.map { "Codex：\($0)" }, state.claudeError.map { "Claude Code：\($0)" }]
            .compactMap { $0 }
        errorLabel.stringValue = errors.joined(separator: "\n")
        errorLabel.isHidden = errorLabel.stringValue.isEmpty

        updatePreferredSize()
    }

    private func updatePreferredSize() {
        view.layoutSubtreeIfNeeded()
        let fittingHeight = contentStack?.fittingSize.height ?? Layout.minHeight
        let height = min(Layout.maxHeight, max(Layout.minHeight, ceil(fittingHeight)))
        let size = NSSize(width: Layout.width, height: height)
        preferredContentSize = size
        if view.frame.size != size {
            view.setFrameSize(size)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let state = UsageState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if let button = statusItem.button {
            button.title = "GPT --  Claude --"
            button.target = self
            button.action = #selector(togglePopover)
        }

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 390, height: 600)
        popover.contentViewController = PopoverViewController(state: state)

        state.observe { [weak self] in
            self?.updateStatusTitle()
        }
        state.start()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            state.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updateStatusTitle() {
        guard let button = statusItem.button else { return }
        let codex: String
        if let used = state.codexSnapshot?.primary?.usedPercent {
            codex = formatPercent(used)
        } else {
            codex = state.isLoadingCodex ? "..." : "--"
        }

        let claude: String
        if let used = state.claudeSnapshot?.fiveHour?.usedPercent {
            claude = formatPercent(used)
        } else {
            claude = "--"
        }
        button.title = "GPT \(codex)  Claude \(claude)"
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
