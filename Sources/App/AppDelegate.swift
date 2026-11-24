import Cocoa
import os

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: AppConfig.bundleIdentifier, category: "Application")

    private var statusBarController: StatusBarController?
    private lazy var mainWindowController: MainWindowController = MainWindowController()

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        if let iconUrl = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") ?? Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
           let img = NSImage(contentsOf: iconUrl) {
            NSApp.applicationIconImage = img
        }

        setupMainMenu()

        let sbController = StatusBarController()
        sbController.onOpenWindow = { [weak self] in
            self?.showWindow()
        }
        sbController.refreshMenu()
        self.statusBarController = sbController

        showWindow()

        // Check command-line arguments for files passed directly
        let args = CommandLine.arguments
        if args.count > 1 {
            let possiblePath = args[1]
            if !possiblePath.hasPrefix("-") {
                let url = URL(fileURLWithPath: possiblePath)
                if FileManager.default.fileExists(atPath: url.path) {
                    mainWindowController.openFile(at: url)
                }
            }
        }

        Self.logger.info("\(AppConfig.appName, privacy: .public) started successfully.")
    }

    public func showWindow() {
        mainWindowController.showWindow(nil)
        mainWindowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - File Opening Handlers for Finder / Open With

    public func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        showWindow()
        mainWindowController.openFile(at: url)
        return true
    }

    public func application(_ sender: NSApplication, openFiles filenames: [String]) {
        guard let first = filenames.first else { return }
        _ = application(sender, openFile: first)
        sender.reply(toOpenOrPrint: .success)
    }

    // MARK: - Menu Setup

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // Application Menu
        let appMenuItem = NSMenuItem(title: AppConfig.appName, action: nil, keyEquivalent: "")
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu(title: AppConfig.appName)
        appMenu.addItem(withTitle: "About \(AppConfig.appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())

        let hideItem = NSMenuItem(title: "Hide \(AppConfig.appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(hideItem)

        let hideOthersItem = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)

        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit \(AppConfig.appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu

        // File Menu
        let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        mainMenu.addItem(fileMenuItem)

        let fileMenu = NSMenu(title: "File")
        let openItem = NSMenuItem(title: "Open 3MF File…", action: #selector(openDocumentAction), keyEquivalent: "o")
        openItem.target = self
        fileMenu.addItem(openItem)
        fileMenu.addItem(NSMenuItem.separator())

        let closeItem = NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenu.addItem(closeItem)
        fileMenuItem.submenu = fileMenu

        // View Menu
        let viewMenuItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        mainMenu.addItem(viewMenuItem)

        let viewMenu = NSMenu(title: "View")
        let resetViewItem = NSMenuItem(title: "Reset View", action: #selector(resetViewAction), keyEquivalent: "r")
        resetViewItem.target = self
        viewMenu.addItem(resetViewItem)

        let toggleGridItem = NSMenuItem(title: "Toggle Grid", action: #selector(toggleGridAction), keyEquivalent: "g")
        toggleGridItem.target = self
        viewMenu.addItem(toggleGridItem)

        let toggleWireframeItem = NSMenuItem(title: "Toggle Wireframe", action: #selector(toggleWireframeAction), keyEquivalent: "w")
        toggleWireframeItem.keyEquivalentModifierMask = [.command, .shift]
        toggleWireframeItem.target = self
        viewMenu.addItem(toggleWireframeItem)
        viewMenuItem.submenu = viewMenu

        // Window Menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)

        let windowMenu = NSMenu(title: "Window")
        let openWindowItem = NSMenuItem(title: "Open Window", action: #selector(openWindowFromMenu), keyEquivalent: "")
        openWindowItem.target = self
        windowMenu.addItem(openWindowItem)
        windowMenu.addItem(NSMenuItem.separator())

        let minimizeItem = NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(minimizeItem)
        windowMenuItem.submenu = windowMenu

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    @objc private func openWindowFromMenu() {
        showWindow()
    }

    @objc private func openDocumentAction() {
        showWindow()
        mainWindowController.openFileAction()
    }

    @objc private func resetViewAction() {
        mainWindowController.resetViewAction()
    }

    @objc private func toggleGridAction() {
        mainWindowController.toggleGridAction()
    }

    @objc private func toggleWireframeAction() {
        mainWindowController.toggleWireframeAction()
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
