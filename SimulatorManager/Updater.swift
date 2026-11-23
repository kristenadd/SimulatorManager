import AppKit
import Combine
import Sparkle

/// Checks for and installs updates with Sparkle. The feed URL, signing key and check interval are
/// in Info.plist; releases (and their signed appcast.xml) come from the GitHub release workflow.
@MainActor
final class Updater: NSObject, ObservableObject {
    static let shared = Updater()

    /// False while a check or install is already in progress.
    @Published private(set) var canCheckForUpdates = false
    @Published var automaticallyChecks = false {
        didSet {
            if updater.automaticallyChecksForUpdates != automaticallyChecks {
                updater.automaticallyChecksForUpdates = automaticallyChecks
            }
        }
    }

    private var controller: SPUStandardUpdaterController!
    private var updater: SPUUpdater { controller.updater }
    private var observers: Set<AnyCancellable> = []
    private var started = false

    private override init() {
        super.init()
        // Debug builds don't check on their own: they'd always find the latest release
        // newer than themselves, and installing it would replace the debug build with
        // the release one.
        #if DEBUG
        let start = false
        #else
        let start = true
        #endif
        controller = SPUStandardUpdaterController(
            startingUpdater: start, updaterDelegate: nil, userDriverDelegate: nil)
        started = start
        automaticallyChecks = updater.automaticallyChecksForUpdates
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] canCheck in
                guard let self else { return }
                // An updater that hasn't started yet reports false, but checking starts it.
                self.canCheckForUpdates = canCheck || !self.started
            }
            .store(in: &observers)
    }

    func checkForUpdates() {
        if !started { controller.startUpdater(); started = true }
        controller.checkForUpdates(nil)
    }
}

/// The standard macOS About panel (icon, name, version, copyright), with credits
/// describing the app and linking to its source.
enum AboutPanel {
    static let repositoryURL = URL(string: "https://github.com/kristenadd/SimulatorManager")!

    @MainActor
    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    private static var credits: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 6
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]

        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: "Keep your simulators tidy.\n", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]))
        text.append(NSAttributedString(string: """
            Launch and manage simulators, delete old runtimes, and clean up \
            simulator data left behind when a runtime is removed.\n
            """, attributes: body))
        var link = body
        link[.link] = repositoryURL
        text.append(NSAttributedString(string: "github.com/kristenadd/SimulatorManager", attributes: link))
        return text
    }
}
