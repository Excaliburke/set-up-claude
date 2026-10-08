// Set Up Claude: a small Mac app that runs claude-setup.sh (bundled in the
// app's Resources) and shows its progress in one window, so nobody has to open
// Terminal or type anything.
//
// The script reports progress as lines that start with "@@" (see app_event in
// claude-setup.sh). Everything else it prints goes in the Details panel. When
// setup fails, the script waits for the person's choice, which the app sends
// as "help" or "close" on the script's standard input.

import AppKit
import CryptoKit
import SwiftUI

// MARK: - Model

enum StepState: String {
    case wait, progress, pending, success, warn, fail, skip
}

struct Step: Identifiable {
    let id: Int
    var title: String
    var state: StepState = .wait
    var note: String = ""
}

enum Phase: Equatable {
    case ready
    case running
    case succeeded
    case failed
    case helpOpened(inApp: Bool)
    case stopped
}

final class SetupRunner: ObservableObject {
    static let shared = SetupRunner()

    static let welcome = """
    This sets up Claude on your Mac: the Claude app, Claude Code, and Git. It takes about 10 to 20 minutes, and most of it runs by itself.

    Two steps need you when they come up: clicking **Install** in Apple's window, and **signing in** with your work account in your browser.

    Click **Start setup** when you're ready.
    """

    // The script sends its own list when it starts; this is what shows before then.
    private static let initialTitles = [
        "Check your Mac",
        "Install Git (Apple's developer tools)",
        "Install the Claude app",
        "Install Claude Code for Terminal",
        "Sign in to Claude Code",
        "Set up Git",
        "Sign in to the Claude app",
        "Final check",
    ]

    @Published var heading = "Set up Claude"
    @Published var message = SetupRunner.welcome
    @Published var steps: [Step] = SetupRunner.makeSteps(SetupRunner.initialTitles)
    @Published var details = ""
    @Published var phase: Phase = .ready {
        didSet { updateWindow() }
    }

    weak var window: NSWindow? {
        didSet { updateWindow() }
    }

    private var process: Process?
    private var input: FileHandle?
    private var unread = Data()
    private var launchHandled = false
    // For automated testing: "--choose=help" or "--choose=close" answers the
    // failure screen by itself after a few seconds.
    private var autoChoice: String?

    // Steps waiting on the person still count as done once setup has finished.
    var finishedCount: Int {
        if phase == .succeeded { return steps.count }
        return steps.filter { [.success, .warn, .fail, .skip].contains($0.state) }.count
    }

    private static func makeSteps(_ titles: [String]) -> [Step] {
        titles.enumerated().map { Step(id: $0.offset, title: $0.element) }
    }

    func handleLaunchArguments() {
        guard !launchHandled else { return }
        launchHandled = true
        let arguments = CommandLine.arguments
        if let choice = arguments.first(where: { $0.hasPrefix("--choose=") }) {
            autoChoice = String(choice.dropFirst("--choose=".count))
        }
        if arguments.contains("--start") {
            start()
        }
    }

    func start() {
        guard phase == .ready || phase == .stopped else { return }
        guard let script = Bundle.main.url(forResource: "claude-setup", withExtension: "sh") else {
            details += "The setup script is missing from this app. Download Set Up Claude again.\n"
            phase = .stopped
            return
        }

        steps = Self.makeSteps(Self.initialTitles)
        heading = "Set up Claude"
        details = ""

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_SETUP_UI"] = "app"
        environment["CLAUDE_SETUP_RERUN_TEXT"] = "open the Set Up Claude app again and click Start setup"
        if environment["LANG"] == nil {
            environment["LANG"] = "en_US.UTF-8"
        }
        process.environment = environment

        let output = Pipe()
        let input = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = input

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            DispatchQueue.main.async { self?.receive(data) }
        }
        process.terminationHandler = { [weak self] ended in
            let status = ended.terminationStatus
            // Let the last lines of output arrive before deciding what happened.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.processEnded(status: status) }
        }

        do {
            try process.run()
        } catch {
            details += "Couldn't start setup: \(error.localizedDescription)\n"
            phase = .stopped
            return
        }
        self.process = process
        self.input = input.fileHandleForWriting
        phase = .running
    }

    func chooseHelp() {
        send("help")
    }

    func closeAfterFailure() {
        send("close")
        NSApp.terminate(nil)
    }

    // Called when the app quits.
    func stop() {
        send("close")
        if let process, process.isRunning {
            process.terminate()
        }
    }

    private func send(_ answer: String) {
        guard let input else { return }
        try? input.write(contentsOf: Data((answer + "\n").utf8))
        try? input.close()
        self.input = nil
    }

    private func receive(_ data: Data) {
        unread.append(data)
        while let newline = unread.firstIndex(of: 0x0A) {
            let line = unread.subdata(in: unread.startIndex..<newline)
            unread = unread.subdata(in: (newline + 1)..<unread.endIndex)
            handle(String(decoding: line, as: UTF8.self))
        }
    }

    private func handle(_ line: String) {
        guard line.hasPrefix("@@") else {
            details += line + "\n"
            return
        }
        let fields = line.dropFirst(2)
            .components(separatedBy: "\t")
            .map { $0.replacingOccurrences(of: "\\n", with: "\n") }
        switch fields[0] {
        case "steps" where fields.count > 1:
            steps = Self.makeSteps(fields[1].components(separatedBy: "|"))
        case "step" where fields.count > 3:
            if let index = Int(fields[1]), steps.indices.contains(index) {
                steps[index].state = StepState(rawValue: fields[2]) ?? .wait
                steps[index].note = fields[3]
            }
        case "message" where fields.count > 1:
            message = fields[1]
        case "final" where fields.count > 3:
            heading = fields[2]
            message = fields[3]
            phase = fields[1] == "success" ? .succeeded : .failed
            if phase == .failed, let autoChoice {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    if autoChoice == "help" { self?.chooseHelp() } else { self?.send("close") }
                }
            }
        case "helpopened" where fields.count > 1:
            phase = .helpOpened(inApp: fields[1] == "app")
        default:
            break
        }
    }

    private func processEnded(status: Int32) {
        input = nil
        guard phase == .running else { return }
        heading = "Setup stopped"
        message = "Setup stopped before it finished. **Details** below shows what happened. You can open Set Up Claude again and click **Start setup** to try again; it skips the steps that already worked."
        phase = .stopped
    }

    // Setup can't be stopped by closing the window halfway through; quitting
    // asks first (see AppDelegate).
    private func updateWindow() {
        guard let window else { return }
        if phase == .running {
            window.styleMask.remove(.closable)
        } else {
            window.styleMask.insert(.closable)
        }
    }
}

// MARK: - Updates

// Each GitHub release carries a latest.json describing itself (see release.sh).
// The app reads the newest one when it opens and offers to update.
struct ReleaseInfo: Decodable {
    let version: String
    let url: URL
    let sha256: String
    let notes: String?
}

enum UpdateState: Equatable {
    case none
    case available(version: String, notes: String)
    case updating(String)
    case failed(String)
}

struct UpdateError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

final class Updater: ObservableObject {
    static let shared = Updater()

    @Published var state: UpdateState = .none
    private var release: ReleaseInfo?
    // For automated testing: "--choose-update" clicks Update by itself.
    private let autoInstall = CommandLine.arguments.contains("--choose-update")

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var releasesPage: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "SetUpClaudeReleasesPage") as? String).flatMap(URL.init(string:))
    }

    private var feedURL: URL? {
        // Tests point this at a local file.
        if let override = ProcessInfo.processInfo.environment["SET_UP_CLAUDE_UPDATE_URL"] {
            return URL(string: override)
        }
        return (Bundle.main.object(forInfoDictionaryKey: "SetUpClaudeUpdateURL") as? String).flatMap(URL.init(string:))
    }

    private var teamID: String? {
        Bundle.main.object(forInfoDictionaryKey: "SetUpClaudeTeamID") as? String
    }

    func check() {
        guard let feedURL else { return }
        let request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self, let data,
                  let release = try? JSONDecoder().decode(ReleaseInfo.self, from: data),
                  Self.isNewer(release.version, than: self.currentVersion) else { return }
            DispatchQueue.main.async {
                self.release = release
                self.state = .available(version: release.version, notes: release.notes ?? "")
                if self.autoInstall {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.install() }
                }
            }
        }.resume()
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    func install() {
        guard let release else { return }
        state = .updating("Downloading version \(release.version)…")
        URLSession.shared.downloadTask(with: release.url) { [weak self] downloaded, _, error in
            guard let self else { return }
            guard let downloaded else {
                self.fail("Couldn't download the update. \(error?.localizedDescription ?? "")")
                return
            }
            do {
                // The downloaded file is removed when this handler returns, so
                // everything happens here.
                let newApp = try self.unpackAndVerify(downloaded, release: release)
                DispatchQueue.main.async { self.state = .updating("Installing version \(release.version)…") }
                try self.replaceAndRelaunch(with: newApp)
            } catch {
                self.fail(error.localizedDescription)
            }
        }.resume()
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async { self.state = .failed(message) }
    }

    // Only installs an app that matches the release's checksum, is signed by
    // the same developer as this one, and was notarized by Apple.
    private func unpackAndVerify(_ zip: URL, release: ReleaseInfo) throws -> URL {
        let data = try Data(contentsOf: zip)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == release.sha256.lowercased() else {
            throw UpdateError("The download didn't match the release, so it wasn't installed.")
        }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("set-up-claude-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let archive = work.appendingPathComponent("update.zip")
        try data.write(to: archive)
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, work.path])

        guard let app = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError("The update didn't contain the app.")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path],
                failure: "The update isn't properly signed, so it wasn't installed.")
        let signature = try run("/usr/bin/codesign", ["-dv", app.path])
        guard let teamID, signature.contains("TeamIdentifier=\(teamID)") else {
            throw UpdateError("The update is signed by a different developer, so it wasn't installed.")
        }
        try run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path],
                failure: "Apple hasn't approved the update, so it wasn't installed.")
        return app
    }

    private func replaceAndRelaunch(with newApp: URL) throws {
        let files = FileManager.default
        var target = Bundle.main.bundleURL
        // An app opened straight from Downloads runs from a hidden read-only
        // copy ("App Translocation"); update the original instead.
        if let original = Self.originalLocation(ofTranslocated: target) {
            target = original
        }
        if !files.isWritableFile(atPath: target.deletingLastPathComponent().path) {
            let applications = files.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
            try files.createDirectory(at: applications, withIntermediateDirectories: true)
            target = applications.appendingPathComponent(target.lastPathComponent)
        }

        // Copy next to the target first, so the swap happens on one disk.
        let staged = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).update-\(UUID().uuidString)")
        try files.copyItem(at: newApp, to: staged)
        if files.fileExists(atPath: target.path) {
            _ = try files.replaceItemAt(target, withItemAt: staged, backupItemName: nil, options: [.usingNewMetadataOnly])
        } else {
            try files.moveItem(at: staged, to: target)
        }

        // Reopen the new version once this one has quit.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"",
                              "sh", String(ProcessInfo.processInfo.processIdentifier), target.path]
        try relaunch.run()
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    private static func originalLocation(ofTranslocated url: URL) -> URL? {
        guard url.path.contains("/AppTranslocation/"),
              let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        typealias OriginalPath = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let originalPath = unsafeBitCast(symbol, to: OriginalPath.self)
        return originalPath(url as CFURL, nil)?.takeRetainedValue() as URL?
    }

    @discardableResult
    private func run(_ tool: String, _ arguments: [String], failure: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError(failure ?? "Updating failed: \(text)")
        }
        return text
    }
}

struct UpdateBanner: View {
    @ObservedObject var updater: Updater

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            switch updater.state {
            case .available(let version, let notes):
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("A newer version is available (\(version))").font(.system(size: 13.5, weight: .semibold))
                    if !notes.isEmpty {
                        Text(notes).font(.system(size: 12.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                Button("Update") { updater.install() }
                    .buttonStyle(.borderedProminent)
            case .updating(let status):
                ProgressView().controlSize(.small)
                Text(status).font(.system(size: 13.5))
                Spacer()
            case .failed(let message):
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text(message).font(.system(size: 13.5))
                        .fixedSize(horizontal: false, vertical: true)
                    if let page = updater.releasesPage {
                        Link("Download the newest version from GitHub", destination: page)
                            .font(.system(size: 12.5))
                    }
                }
                Spacer()
            case .none:
                EmptyView()
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.12)))
    }
}

// MARK: - Views

func markdown(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
}

struct ContentView: View {
    @ObservedObject private var runner = SetupRunner.shared
    @ObservedObject private var updater = Updater.shared
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(runner.heading)
                .font(.system(size: 26, weight: .bold))
                .frame(maxWidth: .infinity, alignment: .center)

            // Updates are offered only before setup starts, never in the middle of it.
            if runner.phase == .ready && updater.state != .none {
                UpdateBanner(updater: updater)
            }

            Text(markdown(runner.message))
                .font(.system(size: 13.5))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            StepList(steps: runner.steps)

            ProgressView(value: Double(runner.finishedCount), total: Double(max(runner.steps.count, 1)))

            DisclosureGroup("Details", isExpanded: $showDetails) {
                DetailsView(text: runner.details)
                    .frame(height: 180)
                    .padding(.top, 6)
            }

            HStack(spacing: 12) {
                statusText
                Spacer(minLength: 12)
                buttons
            }
        }
        .padding(24)
        .frame(width: 760)
        .background(WindowAccessor { window in runner.window = window })
        .onAppear {
            runner.handleLaunchArguments()
            updater.check()
        }
    }

    @ViewBuilder private var statusText: some View {
        switch runner.phase {
        case .helpOpened(let inApp):
            Text(inApp
                 ? "Claude is open with a message about what happened. Read it, then press send. If the message box is empty, click in it and press Command-V."
                 : "claude.ai is open in your browser. Click in the message box, press Command-V, then press send.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        default:
            Text("Version \(updater.currentVersion)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var buttons: some View {
        switch runner.phase {
        case .ready:
            Button("Start setup") { runner.start() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        case .running:
            Button("Working…") {}
                .disabled(true)
                .controlSize(.large)
        case .succeeded:
            Button("Done") { NSApp.terminate(nil) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        case .failed:
            Button("Close") { runner.closeAfterFailure() }
                .controlSize(.large)
            Button("Get help from Claude") { runner.chooseHelp() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        case .helpOpened, .stopped:
            Button("Close") { NSApp.terminate(nil) }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
    }
}

struct StepList: View {
    let steps: [Step]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(steps) { step in
                StepRow(step: step)
                if step.id != steps.last?.id {
                    Divider()
                }
            }
        }
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}

struct StepRow: View {
    let step: Step

    var body: some View {
        HStack(spacing: 12) {
            icon
                .font(.system(size: 17))
                .frame(width: 22, height: 22)
            Text(step.title)
                .font(.system(size: 14, weight: step.state == .pending ? .semibold : .regular))
                .layoutPriority(1)
            Spacer(minLength: 12)
            Text(step.note)
                .font(.system(size: 13))
                .foregroundStyle(step.state == .fail ? Color.red : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(step.note)
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder private var icon: some View {
        switch step.state {
        case .progress:
            ProgressView().controlSize(.small)
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warn:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.yellow)
        case .fail:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .pending:
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
        case .skip:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .wait:
            Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
        }
    }
}

// The setup's own output, like a Terminal window.
struct DetailsView: View {
    let text: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(text.isEmpty ? "Nothing yet." : text)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                    Color.clear.frame(height: 1).id("end")
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
            .onChange(of: text) { _ in
                proxy.scrollTo("end", anchor: .bottom)
            }
        }
    }
}

// Hands the view's NSWindow to the runner, so it can turn off the close button
// while setup runs.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onWindow(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard SetupRunner.shared.phase == .running else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Stop setup?"
        alert.informativeText = "Setup is still running. If you stop now, you can open Set Up Claude again later and it picks up where it left off."
        alert.addButton(withTitle: "Keep going")
        alert.addButton(withTitle: "Stop setup")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        SetupRunner.shared.stop()
    }
}

@main
struct SetUpClaudeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Writing the person's choice to a script that already ended mustn't
        // crash the app.
        signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        Window("Set Up Claude", id: "setup") {
            ContentView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
