import Cocoa
import QuickLookUI
import SceneKit

/// Label that never intercepts mouse events, so drags/scrolls reach the 3D view underneath.
private final class PassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@objc(PreviewViewController)
public class PreviewViewController: NSViewController, QLPreviewingController {
    private var threeMFView: ThreeMFView!
    private var infoLabel: PassthroughLabel!

    public override func loadView() {
        threeMFView = ThreeMFView(frame: NSRect(x: 0, y: 0, width: 900, height: 650))
        threeMFView.autoresizingMask = [.width, .height]

        infoLabel = PassthroughLabel(labelWithString: "")
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        infoLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.lineBreakMode = .byTruncatingTail
        threeMFView.addSubview(infoLabel)
        NSLayoutConstraint.activate([
            infoLabel.leadingAnchor.constraint(equalTo: threeMFView.leadingAnchor, constant: 12),
            infoLabel.trailingAnchor.constraint(lessThanOrEqualTo: threeMFView.trailingAnchor, constant: -12),
            infoLabel.bottomAnchor.constraint(equalTo: threeMFView.bottomAnchor, constant: -10),
        ])

        self.view = threeMFView
        self.preferredContentSize = NSSize(width: 900, height: 650)
    }

    public override var acceptsFirstResponder: Bool {
        return true
    }

    public override func scrollWheel(with event: NSEvent) {
        threeMFView?.scrollWheel(with: event)
    }

    public override func magnify(with event: NSEvent) {
        threeMFView?.magnify(with: event)
    }

    // MARK: - QLPreviewingController

    @objc public func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        // Ensure the view hierarchy exists before the async work completes.
        _ = self.view

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let doc = try ThreeMFParser.load(from: url)
                let sceneInfo = ModelSceneBuilder.build(from: doc)
                guard sceneInfo.totalTriangles > 0 else {
                    throw ThreeMFParserError.emptyDocument
                }

                DispatchQueue.main.async {
                    self.threeMFView.setModelScene(sceneInfo)
                    self.infoLabel.stringValue = Self.summary(for: sceneInfo)
                    handler(nil)
                }
            } catch {
                DispatchQueue.main.async {
                    handler(error)
                }
            }
        }
    }

    private static func summary(for info: ModelSceneInfo) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let tris = formatter.string(from: NSNumber(value: info.totalTriangles)) ?? "\(info.totalTriangles)"
        let d = info.dimensions
        // World is Y-up; report in 3MF terms: X × Y(depth) × Z(height)
        let dims = String(format: "%.1f × %.1f × %.1f mm", Double(d.x), Double(d.z), Double(d.y))
        return "\(dims)  •  \(tris) triangles   —   drag: rotate  •  scroll: pan  •  pinch: zoom"
    }
}
