import Cocoa
import SceneKit

public final class ThreeMFView: SCNView {
    // Camera state
    private var cameraNode: SCNNode!
    private var camera: SCNCamera!

    private var pivot: SCNVector3 = SCNVector3Zero
    private var initialPivot: SCNVector3 = SCNVector3Zero

    private var distance: CGFloat = 100.0
    private var initialDistance: CGFloat = 100.0
    private var minDistance: CGFloat = 1.0
    private var maxDistance: CGFloat = 5000.0

    private var yaw: CGFloat = CGFloat.pi / 4.0      // 45 degrees
    private var pitch: CGFloat = CGFloat.pi / 6.0    // 30 degrees
    private let initialYaw: CGFloat = CGFloat.pi / 4.0
    private let initialPitch: CGFloat = CGFloat.pi / 6.0

    // References to scene components
    private var modelContainer: SCNNode?
    private var gridNode: SCNNode?

    // Display options
    public private(set) var isWireframe: Bool = false
    public private(set) var isGridVisible: Bool = true

    // Callbacks
    public var onFileDropped: ((URL) -> Void)?
    public var onCameraChanged: (() -> Void)?

    // Drag-and-drop visual indicator
    private var isDragOver: Bool = false {
        didSet {
            needsDisplay = true
        }
    }

    public override init(frame frameRect: NSRect, options: [String : Any]? = nil) {
        super.init(frame: frameRect, options: options)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        self.backgroundColor = NSColor.windowBackgroundColor
        self.antialiasingMode = .multisampling2X
        self.preferredFramesPerSecond = 60
        self.allowsCameraControl = false // We implement custom orbit, pan, and zoom controls

        setupCamera()
        registerForDraggedTypes([.fileURL])
    }

    private func setupCamera() {
        camera = SCNCamera()
        camera.automaticallyAdjustsZRange = true
        camera.zNear = 0.1
        camera.zFar = 100_000.0
        camera.fieldOfView = 40.0

        cameraNode = SCNNode()
        cameraNode.name = "ViewerCamera"
        cameraNode.camera = camera

        let initialScene = SCNScene()
        initialScene.rootNode.addChildNode(cameraNode)
        self.scene = initialScene
        self.pointOfView = cameraNode
    }

    public func setModelScene(_ info: ModelSceneInfo) {
        // Move our controlled camera into the new scene (it is still parented to the
        // previous scene otherwise, which leaves the view with a detached point of view).
        cameraNode.removeFromParentNode()
        info.scene.rootNode.addChildNode(cameraNode)

        self.scene = info.scene
        self.modelContainer = info.modelContainer
        self.gridNode = info.gridNode
        self.pointOfView = cameraNode

        // Re-apply display options to the new model
        gridNode?.isHidden = !isGridVisible
        if isWireframe { applyWireframe(true, to: modelContainer) }

        // Update grid colors to match current view appearance
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if let grid = self.gridNode {
            ModelSceneBuilder.updateGridAppearance(in: grid, isDark: isDark)
        }

        // Frame the model's bounding sphere so it fits the view at any orientation
        let d = info.dimensions
        let radius = max(CGFloat(0.5), 0.5 * sqrt(d.x * d.x + d.y * d.y + d.z * d.z))
        let halfFov = (camera.fieldOfView * .pi / 180.0) / 2.0
        let targetDistance = radius / sin(halfFov) * 1.05

        self.initialPivot = info.center
        self.pivot = info.center

        self.initialDistance = targetDistance
        self.distance = targetDistance
        self.minDistance = radius * 0.05
        self.maxDistance = targetDistance * 20.0

        self.yaw = initialYaw
        self.pitch = initialPitch

        updateCameraTransform()
    }

    private func updateCameraTransform() {
        guard cameraNode != nil else { return }

        let cosPitch = cos(pitch)
        let sinPitch = sin(pitch)
        let cosYaw = cos(yaw)
        let sinYaw = sin(yaw)

        let x = pivot.x + distance * cosPitch * sinYaw
        let y = pivot.y + distance * sinPitch
        let z = pivot.z + distance * cosPitch * cosYaw

        cameraNode.position = SCNVector3(x, y, z)
        cameraNode.look(at: pivot, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))

        needsDisplay = true
        onCameraChanged?()
    }

    // MARK: - View Controls

    public func resetView(animated: Bool = true) {
        self.pivot = self.initialPivot
        self.distance = self.initialDistance
        self.yaw = self.initialYaw
        self.pitch = self.initialPitch

        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 0.3 : 0
        updateCameraTransform()
        SCNTransaction.commit()
    }

    public func toggleWireframe() {
        isWireframe.toggle()
        applyWireframe(isWireframe, to: modelContainer)
    }

    private func applyWireframe(_ wireframe: Bool, to node: SCNNode?) {
        guard let node = node else { return }
        if let geometry = node.geometry {
            for material in geometry.materials {
                material.fillMode = wireframe ? .lines : .fill
            }
        }
        for child in node.childNodes {
            applyWireframe(wireframe, to: child)
        }
    }

    public func toggleGrid() {
        isGridVisible.toggle()
        gridNode?.isHidden = !isGridVisible
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if let grid = self.gridNode {
            ModelSceneBuilder.updateGridAppearance(in: grid, isDark: isDark)
        }
    }

    // MARK: - Mouse & Gesture Interaction
    //
    //   Rotate: left mouse drag
    //   Pan:    two-finger scroll (trackpad), right mouse drag (also middle drag or modifier + left drag)
    //   Zoom:   trackpad pinch, or traditional mouse scroll wheel

    private enum DragMode { case none, rotate, pan }
    private var dragMode: DragMode = .none

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    public override var acceptsFirstResponder: Bool {
        return true
    }

    public override func becomeFirstResponder() -> Bool {
        return true
    }

    public override var mouseDownCanMoveWindow: Bool {
        return false
    }

    // Active continuous rendering with automatic idle power-down
    private var idleTimer: Timer?

    private func startInteraction() {
        self.rendersContinuously = true
        idleTimer?.invalidate()
        idleTimer = nil
    }

    private func endInteractionDebounced(delay: TimeInterval = 0.15) {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.rendersContinuously = false
        }
    }

    private func beginDrag(_ mode: DragMode) {
        dragMode = mode
        startInteraction()
        window?.makeFirstResponder(self)
        (mode == .rotate ? NSCursor.closedHand : NSCursor.openHand).set()
    }

    private func endDrag() {
        dragMode = .none
        endInteractionDebounced()
        NSCursor.arrow.set()
    }

    private func handleDrag(_ event: NSEvent) {
        switch dragMode {
        case .rotate: rotateCamera(deltaX: event.deltaX, deltaY: event.deltaY)
        case .pan: panCamera(deltaX: event.deltaX, deltaY: event.deltaY)
        case .none: break
        }
    }

    // 1. ROTATE: Left Mouse Button Drag (modifier + left drag pans)
    public override func mouseDown(with event: NSEvent) {
        let panModifiers: NSEvent.ModifierFlags = [.option, .shift, .control]
        let isPan = !event.modifierFlags.intersection(panModifiers).isEmpty
        beginDrag(isPan ? .pan : .rotate)
    }

    public override func mouseDragged(with event: NSEvent) {
        handleDrag(event)
    }

    public override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 { resetView() }
        endDrag()
    }

    // 2. PAN: Right Mouse Button Drag
    public override func rightMouseDown(with event: NSEvent) {
        beginDrag(.pan)
    }

    public override func rightMouseDragged(with event: NSEvent) {
        handleDrag(event)
    }

    public override func rightMouseUp(with event: NSEvent) {
        endDrag()
    }

    // No context menu: right button is reserved for panning
    public override func menu(for event: NSEvent) -> NSMenu? {
        return nil
    }

    // Middle Mouse Drag also pans (CAD convention)
    public override func otherMouseDown(with event: NSEvent) {
        beginDrag(.pan)
    }

    public override func otherMouseDragged(with event: NSEvent) {
        handleDrag(event)
    }

    public override func otherMouseUp(with event: NSEvent) {
        endDrag()
    }



    private func rotateCamera(deltaX: CGFloat, deltaY: CGFloat) {
        let sensitivity: CGFloat = 0.01 // radians per point
        yaw -= deltaX * sensitivity
        pitch += deltaY * sensitivity

        // Clamp pitch to avoid flipping over the poles
        let maxPitch = CGFloat.pi / 2.0 - 0.01
        pitch = max(-maxPitch, min(maxPitch, pitch))

        updateCameraTransform()
    }

    private func panCamera(deltaX: CGFloat, deltaY: CGFloat) {
        guard cameraNode != nil, bounds.height > 0 else { return }

        // World units per screen point at the pivot depth, so the model follows the cursor
        let halfFov = (camera.fieldOfView * .pi / 180.0) / 2.0
        let unitsPerPoint = 2.0 * distance * tan(halfFov) / bounds.height

        let right = cameraNode.worldRight
        let up = cameraNode.worldUp
        let dx = -deltaX * unitsPerPoint
        let dy = deltaY * unitsPerPoint // NSEvent deltaY is positive when moving down

        pivot = SCNVector3(
            pivot.x + right.x * dx + up.x * dy,
            pivot.y + right.y * dx + up.y * dy,
            pivot.z + right.z * dx + up.z * dy
        )

        updateCameraTransform()
    }

    private func zoom(by factor: CGFloat) {
        guard factor.isFinite, factor > 0 else { return }
        distance = max(minDistance, min(maxDistance, distance * factor))
        updateCameraTransform()
    }

    // 3. PAN: Two-finger scroll (trackpad) / ZOOM: Traditional notched mouse wheel
    public override func scrollWheel(with event: NSEvent) {
        startInteraction()
        if event.hasPreciseScrollingDeltas {
            // Trackpad two-finger scroll: pan the preview
            guard abs(event.scrollingDeltaX) > 0.0001 || abs(event.scrollingDeltaY) > 0.0001 else {
                endInteractionDebounced()
                return
            }
            panCamera(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
        } else {
            // Traditional notched mouse wheel (no pinch gesture): zoom
            let delta = abs(event.scrollingDeltaY) > 0.0001 ? event.scrollingDeltaY : event.scrollingDeltaX
            guard abs(delta) > 0.0001 else {
                endInteractionDebounced()
                return
            }
            let perUnit: CGFloat = 0.08
            zoom(by: exp(-delta * perUnit))
        }
        endInteractionDebounced()
    }

    // 3b. ZOOM: Trackpad pinch
    public override func magnify(with event: NSEvent) {
        startInteraction()
        zoom(by: exp(-event.magnification * 1.5))
        endInteractionDebounced()
    }

    // Keyboard shortcuts
    public override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "r":
            resetView()
        case "w":
            toggleWireframe()
        case "g":
            toggleGrid()
        case "=", "+":
            zoom(by: 0.85)
        case "-":
            zoom(by: 1.0 / 0.85)
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Drag and Drop Handling

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let url = extractFileURL(from: sender) else { return [] }
        if url.pathExtension.lowercased() == "3mf" || url.pathExtension.lowercased() == "model" {
            isDragOver = true
            return .copy
        }
        return []
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        isDragOver = false
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
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

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if isDragOver {
            NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
            dirtyRect.fill(using: .sourceOver)

            let borderPath = NSBezierPath(rect: bounds.insetBy(dx: 4, dy: 4))
            borderPath.lineWidth = 4
            let pattern: [CGFloat] = [8, 4]
            borderPath.setLineDash(pattern, count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            borderPath.stroke()
        }
    }
}
