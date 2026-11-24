import AppKit
import Metal
import SceneKit

/// Thumbnail helpers: embedded 3MF thumbnails and offscreen SceneKit rendering.
public enum ModelSnapshot {
    /// Returns a slicer-rendered image of the model embedded in the package, if any.
    ///
    /// Only renders of the actual geometry are used: Bambu Studio / OrcaSlicer write the plate
    /// render to `Metadata/plate_1.png` and PrusaSlicer to `Metadata/thumbnail.png`. The OPC
    /// thumbnail relationship (`Auxiliaries/.thumbnails/...`) is skipped on purpose: for files
    /// downloaded from model sites it is often a cover photo, not the model.
    public static func embeddedThumbnail(in url: URL) -> NSImage? {
        guard let archive = try? ZipArchive(url: url) else { return nil }
        for path in ["Metadata/plate_1.png", "Metadata/thumbnail.png"] {
            if let entry = archive.entry(named: path),
               let data = try? archive.extract(entry),
               let image = NSImage(data: data),
               image.size.width > 0 {
                return image
            }
        }
        return nil
    }

    /// Renders the model offscreen with the same framing as the interactive viewer.
    public static func render(_ info: ModelSceneInfo, size: CGSize) -> NSImage? {
        guard size.width >= 1, size.height >= 1,
              let device = MTLCreateSystemDefaultDevice() else { return nil }

        info.gridNode.isHidden = true

        let camera = SCNCamera()
        camera.fieldOfView = 40
        camera.automaticallyAdjustsZRange = true
        let cameraNode = SCNNode()
        cameraNode.camera = camera

        let d = info.dimensions
        let radius = max(CGFloat(0.5), 0.5 * sqrt(d.x * d.x + d.y * d.y + d.z * d.z))
        let distance = radius / sin((camera.fieldOfView * .pi / 180.0) / 2.0) * 1.02
        let yaw = CGFloat.pi / 4.0
        let pitch = CGFloat.pi / 6.0
        let c = info.center
        cameraNode.position = SCNVector3(
            c.x + distance * cos(pitch) * sin(yaw),
            c.y + distance * sin(pitch),
            c.z + distance * cos(pitch) * cos(yaw))
        cameraNode.look(at: c, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        info.scene.rootNode.addChildNode(cameraNode)
        info.scene.background.contents = NSColor.clear

        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = info.scene
        renderer.pointOfView = cameraNode
        renderer.autoenablesDefaultLighting = false
        return renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
    }
}
