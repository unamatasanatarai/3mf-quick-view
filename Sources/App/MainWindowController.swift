import Cocoa
import SceneKit
import UniformTypeIdentifiers

public final class MainWindowController: NSWindowController {
    // UI elements
    private var threeDView: ThreeMFView!
    private var emptyStateView: NSView!
    private var infoBarView: NSVisualEffectView!
    private var infoLabel: NSTextField!
    private var controlsStack: NSStackView!

    private var wireframeButton: NSButton!
    private var gridButton: NSButton!
    private var resetViewButton: NSButton!
    private var openFileButton: NSButton!

    private var currentDocument: ThreeMFDocument?

    public convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 900, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = AppConfig.appName
        window.minSize = NSSize(width: 500, height: 400)
        self.init(window: window)
        setupViews()
    }

    private func setupViews() {
        guard let window = self.window, let contentView = window.contentView else { return }

        // 1. 3D Scene View
        threeDView = ThreeMFView(frame: contentView.bounds)
        threeDView.translatesAutoresizingMaskIntoConstraints = false
        threeDView.onFileDropped = { [weak self] url in
            self?.openFile(at: url)
        }
        contentView.addSubview(threeDView)

        // 2. Empty State View
        emptyStateView = createEmptyStateView()
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(emptyStateView)

        // 3. Info / Status Overlay Bar at the bottom
        infoBarView = NSVisualEffectView()
        infoBarView.translatesAutoresizingMaskIntoConstraints = false
        infoBarView.material = .hudWindow
        infoBarView.blendingMode = .withinWindow
        infoBarView.state = .active
        infoBarView.wantsLayer = true
        infoBarView.layer?.cornerRadius = 8
        infoBarView.layer?.masksToBounds = true
        infoBarView.isHidden = true
        contentView.addSubview(infoBarView)

        // Info text
        infoLabel = NSTextField(labelWithString: "")
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        infoLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        infoLabel.textColor = .labelColor
        infoLabel.lineBreakMode = .byTruncatingTail
        infoBarView.addSubview(infoLabel)

        // Control buttons
        controlsStack = NSStackView()
        controlsStack.translatesAutoresizingMaskIntoConstraints = false
        controlsStack.orientation = .horizontal
        controlsStack.spacing = 8
        controlsStack.alignment = .centerY
        infoBarView.addSubview(controlsStack)

        resetViewButton = NSButton(title: "Reset View", target: self, action: #selector(resetViewAction))
        resetViewButton.bezelStyle = .inline
        resetViewButton.toolTip = "Reset camera orientation and framing (R / Space)"
        controlsStack.addArrangedSubview(resetViewButton)

        gridButton = NSButton(title: "Grid", target: self, action: #selector(toggleGridAction))
        gridButton.bezelStyle = .inline
        gridButton.toolTip = "Toggle build plate ground grid (G)"
        controlsStack.addArrangedSubview(gridButton)

        wireframeButton = NSButton(title: "Wireframe", target: self, action: #selector(toggleWireframeAction))
        wireframeButton.bezelStyle = .inline
        wireframeButton.toolTip = "Toggle wireframe display mode (W)"
        controlsStack.addArrangedSubview(wireframeButton)

        openFileButton = NSButton(title: "Open…", target: self, action: #selector(openFileAction))
        openFileButton.bezelStyle = .inline
        openFileButton.toolTip = "Open another 3MF file (⌘O)"
        controlsStack.addArrangedSubview(openFileButton)

        // Autolayout constraints
        NSLayoutConstraint.activate([
            // 3D View fills content view
            threeDView.topAnchor.constraint(equalTo: contentView.topAnchor),
            threeDView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            threeDView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            threeDView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            // Empty state fills content view
            emptyStateView.topAnchor.constraint(equalTo: contentView.topAnchor),
            emptyStateView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            // Info bar pinned to bottom
            infoBarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            infoBarView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            infoBarView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            infoBarView.heightAnchor.constraint(equalToConstant: 40),

            infoLabel.leadingAnchor.constraint(equalTo: infoBarView.leadingAnchor, constant: 14),
            infoLabel.centerYAnchor.constraint(equalTo: infoBarView.centerYAnchor),
            infoLabel.trailingAnchor.constraint(lessThanOrEqualTo: controlsStack.leadingAnchor, constant: -10),

            controlsStack.trailingAnchor.constraint(equalTo: infoBarView.trailingAnchor, constant: -10),
            controlsStack.centerYAnchor.constraint(equalTo: infoBarView.centerYAnchor),
        ])
    }

    private func createEmptyStateView() -> NSView {
        let view = DropZoneView()
        view.onFileDropped = { [weak self] url in
            self?.openFile(at: url)
        }

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        view.addSubview(stack)

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        if let iconUrl = Bundle.main.url(forResource: "AppIcon", withExtension: "png") ?? Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let appIcon = NSImage(contentsOf: iconUrl) {
            iconView.image = appIcon
        } else if let appIcon = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage {
            iconView.image = appIcon
        } else if let icon = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: "3MF Model") {
            iconView.image = icon
            iconView.contentTintColor = .secondaryLabelColor
        }
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.widthAnchor.constraint(equalToConstant: 80).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 80).isActive = true
        stack.addArrangedSubview(iconView)

        let titleLabel = NSTextField(labelWithString: "3MF Quick Look")
        titleLabel.font = NSFont.systemFont(ofSize: 22, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        stack.addArrangedSubview(titleLabel)

        let descLabel = NSTextField(labelWithString: "Drop a .3mf file here to view 3D model")
        descLabel.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        descLabel.textColor = .secondaryLabelColor
        descLabel.alignment = .center
        stack.addArrangedSubview(descLabel)

        let hintLabel = NSTextField(labelWithString: "Rotate: Left Drag • Pan: 2-Finger Scroll • Zoom: Pinch")
        hintLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.alignment = .center
        stack.addArrangedSubview(hintLabel)

        let openBtn = NSButton(title: "Open 3MF File…", target: self, action: #selector(openFileAction))
        openBtn.bezelStyle = .rounded
        openBtn.controlSize = .large
        stack.addArrangedSubview(openBtn)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        return view
    }

    public func openFile(at url: URL) {
        do {
            let doc = try ThreeMFParser.load(from: url)
            self.currentDocument = doc
            let sceneInfo = ModelSceneBuilder.build(from: doc)

            threeDView.setModelScene(sceneInfo)
            emptyStateView.isHidden = true
            infoBarView.isHidden = false

            // Update title
            let filename = url.lastPathComponent
            window?.title = "\(filename) — \(AppConfig.appName)"
            window?.representedURL = url

            // Update stats
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            let triCount = formatter.string(from: NSNumber(value: sceneInfo.totalTriangles)) ?? "\(sceneInfo.totalTriangles)"
            let vertCount = formatter.string(from: NSNumber(value: sceneInfo.totalVertices)) ?? "\(sceneInfo.totalVertices)"
            let dims = sceneInfo.dimensions
            let dimsStr = String(format: "%.1f × %.1f × %.1f mm", Double(dims.x), Double(dims.z), Double(dims.y)) // X x Y x Z in 3MF terms

            infoLabel.stringValue = "\(dimsStr)  •  \(triCount) triangles  •  \(vertCount) vertices"
            updateButtonTitles()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Failed to Open 3MF File"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            if let win = self.window {
                alert.beginSheetModal(for: win, completionHandler: nil)
            } else {
                alert.runModal()
            }
        }
    }

    private func updateButtonTitles() {
        wireframeButton.title = threeDView.isWireframe ? "Shaded" : "Wireframe"
        gridButton.title = threeDView.isGridVisible ? "Hide Grid" : "Show Grid"
    }

    @objc public func openFileAction() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let types = [UTType(filenameExtension: "3mf"), UTType(filenameExtension: "model")].compactMap { $0 }
        panel.allowedContentTypes = types
        panel.message = "Choose a 3MF file to view"

        guard let win = self.window else { return }
        panel.beginSheetModal(for: win) { [weak self] response in
            if response == .OK, let url = panel.url {
                self?.openFile(at: url)
            }
        }
    }

    @objc public func resetViewAction() {
        threeDView.resetView()
    }

    @objc public func toggleWireframeAction() {
        threeDView.toggleWireframe()
        updateButtonTitles()
    }

    @objc public func toggleGridAction() {
        threeDView.toggleGrid()
        updateButtonTitles()
    }
}

// MARK: - Drop Zone View for Empty State

private final class DropZoneView: NSView {
    public var onFileDropped: ((URL) -> Void)?
    private var isDragOver: Bool = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let url = extractFileURL(from: sender) else { return [] }
        if url.pathExtension.lowercased() == "3mf" || url.pathExtension.lowercased() == "model" {
            isDragOver = true
            return .copy
        }
        return []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDragOver = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDragOver = false
        guard let url = extractFileURL(from: sender) else { return false }
        onFileDropped?(url)
        return true
    }

    private func extractFileURL(from sender: NSDraggingInfo) -> URL? {
        let pasteboard = sender.draggingPasteboard
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              let first = urls.first else {
            return nil
        }
        return first
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if isDragOver {
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
            dirtyRect.fill(using: .sourceOver)

            let borderPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 12, dy: 12), xRadius: 16, yRadius: 16)
            borderPath.lineWidth = 4
            let pattern: [CGFloat] = [10, 6]
            borderPath.setLineDash(pattern, count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            borderPath.stroke()
        }
    }
}
