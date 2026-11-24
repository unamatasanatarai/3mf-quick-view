import Foundation
import SceneKit
import AppKit

public struct ModelSceneInfo {
    public let scene: SCNScene
    public let modelContainer: SCNNode
    public let gridNode: SCNNode
    public let boundingBox: (min: SCNVector3, max: SCNVector3)
    public let dimensions: SCNVector3
    public let center: SCNVector3
    public let totalTriangles: Int
    public let totalVertices: Int
    public let objectCount: Int
}

public final class ModelSceneBuilder {
    // Default palette for models without explicit colors
    private static let colorPalette: [NSColor] = [
        NSColor(red: 0.95, green: 0.44, blue: 0.13, alpha: 1.0), // Filament Orange
        NSColor(red: 0.20, green: 0.60, blue: 0.86, alpha: 1.0), // Cyan Blue
        NSColor(red: 0.23, green: 0.70, blue: 0.44, alpha: 1.0), // Emerald Green
        NSColor(red: 0.60, green: 0.35, blue: 0.71, alpha: 1.0), // Amethyst Purple
        NSColor(red: 0.90, green: 0.30, blue: 0.35, alpha: 1.0), // Crimson Red
        NSColor(red: 0.95, green: 0.77, blue: 0.06, alpha: 1.0), // Sunflower Yellow
    ]

    public static func build(from document: ThreeMFDocument) -> ModelSceneInfo {
        let scene = SCNScene()

        // Root container for all 3MF geometry
        let modelContainer = SCNNode()
        modelContainer.name = "ModelContainer"

        var colorIndex = 0

        func getColor(for object: ThreeMFObject) -> NSColor {
            if let pid = object.pid, let pindex = object.pindex, let group = document.colors[pid], pindex < group.count {
                return group[pindex].nsColor
            }
            let color = colorPalette[colorIndex % colorPalette.count]
            colorIndex += 1
            return color
        }

        func createNode(for object: ThreeMFObject, inheritedColor: NSColor?) -> SCNNode {
            let node = SCNNode()
            node.name = object.name ?? "Object_\(object.id)"

            let objectColor = inheritedColor ?? getColor(for: object)

            if let mesh = object.mesh, !mesh.vertices.isEmpty, !mesh.triangles.isEmpty {
                if let geometry = buildGeometry(from: mesh, defaultColor: objectColor) {
                    node.geometry = geometry
                }
            }

            for comp in object.components {
                if let childObj = document.findObject(path: comp.path, id: comp.objectId, currentSourcePath: object.sourcePath) {
                    let childNode = createNode(for: childObj, inheritedColor: objectColor)
                    if let transform = comp.transform {
                        childNode.transform = transform
                    }
                    node.addChildNode(childNode)
                }
            }

            return node
        }

        var instantiatedObjects = 0

        if !document.buildItems.isEmpty {
            for item in document.buildItems {
                if let obj = document.findObject(path: nil, id: item.objectId) {
                    let itemNode = createNode(for: obj, inheritedColor: nil)
                    if let transform = item.transform {
                        itemNode.transform = transform
                    }
                    modelContainer.addChildNode(itemNode)
                    instantiatedObjects += 1
                }
            }
        }

        // Fallback: If build items didn't instantiate anything or have no geometry, load all mesh objects
        if instantiatedObjects == 0 || modelContainer.childNodes.isEmpty {
            var visitedIds = Set<String>()
            for (_, obj) in document.objects {
                if obj.mesh != nil && !obj.mesh!.vertices.isEmpty {
                    if !visitedIds.contains(obj.id) {
                        visitedIds.insert(obj.id)
                        let node = createNode(for: obj, inheritedColor: nil)
                        modelContainer.addChildNode(node)
                        instantiatedObjects += 1
                    }
                }
            }
        }

        // Apply scale to millimeters if unit is not millimeters
        let scale = document.unitScaleToMillimeters
        if abs(scale - 1.0) > 0.0001 {
            modelContainer.scale = SCNVector3(scale, scale, scale)
        }

        // In 3MF, Z is the vertical build axis.
        // In SceneKit, Y is the vertical axis.
        // We orient the model container by rotating -90 degrees around X:
        // 3MF (x, y, z) -> SceneKit (x, z, -y) where Z becomes height (+Y).
        modelContainer.eulerAngles = SCNVector3(-CGFloat.pi / 2.0, 0, 0)

        // Add model container to scene to compute world bounding box
        scene.rootNode.addChildNode(modelContainer)

        // boundingBox is expressed in the container's local (3MF, Z-up, unscaled) space.
        // Transform its corners into world space (Y-up, millimeters) before measuring.
        let local = modelContainer.boundingBox
        var minVec = SCNVector3(CGFloat.greatestFiniteMagnitude, .greatestFiniteMagnitude, .greatestFiniteMagnitude)
        var maxVec = SCNVector3(-CGFloat.greatestFiniteMagnitude, -.greatestFiniteMagnitude, -.greatestFiniteMagnitude)
        for cx in [local.min.x, local.max.x] {
            for cy in [local.min.y, local.max.y] {
                for cz in [local.min.z, local.max.z] {
                    let w = modelContainer.convertPosition(SCNVector3(cx, cy, cz), to: nil)
                    minVec = SCNVector3(min(minVec.x, w.x), min(minVec.y, w.y), min(minVec.z, w.z))
                    maxVec = SCNVector3(max(maxVec.x, w.x), max(maxVec.y, w.y), max(maxVec.z, w.z))
                }
            }
        }
        if !(minVec.x.isFinite && maxVec.x.isFinite) || minVec.x > maxVec.x {
            minVec = SCNVector3Zero
            maxVec = SCNVector3Zero
        }

        let dims = SCNVector3(
            max(0.1, maxVec.x - minVec.x),
            max(0.1, maxVec.y - minVec.y),
            max(0.1, maxVec.z - minVec.z)
        )
        let rawCenter = SCNVector3(
            (minVec.x + maxVec.x) * 0.5,
            (minVec.y + maxVec.y) * 0.5,
            (minVec.z + maxVec.z) * 0.5
        )

        // Offset (in world space) so the model is centered over the origin in X/Z and its
        // bottom rests on the build plate (Y = 0).
        let currentPos = modelContainer.position
        modelContainer.position = SCNVector3(
            currentPos.x - rawCenter.x,
            currentPos.y - minVec.y,
            currentPos.z - rawCenter.z
        )

        let visualCenter = SCNVector3(0, dims.y * 0.5, 0)

        // Create build plate / ground grid
        let isDark: Bool
        if let match = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) {
            isDark = (match == .darkAqua)
        } else {
            isDark = true
        }
        let gridNode = buildGroundGrid(dimensions: dims, isDark: isDark)
        gridNode.position = SCNVector3(0, 0, 0)
        scene.rootNode.addChildNode(gridNode)

        // Lighting setup
        let maxDim = max(dims.x, max(dims.y, dims.z))
        setupLighting(in: scene, center: visualCenter, maxDimension: maxDim)

        return ModelSceneInfo(
            scene: scene,
            modelContainer: modelContainer,
            gridNode: gridNode,
            boundingBox: (minVec, maxVec),
            dimensions: dims,
            center: visualCenter,
            totalTriangles: document.totalTriangles,
            totalVertices: document.totalVertices,
            objectCount: max(1, instantiatedObjects)
        )
    }

    private static func buildGeometry(from mesh: ThreeMFMesh, defaultColor: NSColor) -> SCNGeometry? {
        guard !mesh.vertices.isEmpty, !mesh.triangles.isEmpty else { return nil }

        let vertexSource = SCNGeometrySource(vertices: mesh.vertices)

        var indices: [Int32] = []
        indices.reserveCapacity(mesh.triangles.count * 3)
        for tri in mesh.triangles {
            indices.append(tri.v1)
            indices.append(tri.v2)
            indices.append(tri.v3)
        }

        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [vertexSource], elements: [element])

        // Material setup: clean, professional 3D print finish with high-performance shading
        let material = SCNMaterial()
        material.lightingModel = .blinn
        material.diffuse.contents = defaultColor
        material.specular.contents = NSColor(white: 0.25, alpha: 1.0)
        material.shininess = 30.0
        material.isDoubleSided = false
        material.cullMode = .back

        geometry.materials = [material]
        return geometry
    }

    public static func buildGroundGrid(dimensions: SCNVector3, isDark: Bool = true) -> SCNNode {
        let gridRoot = SCNNode()
        gridRoot.name = "GroundGrid"

        let maxFootprint = max(dimensions.x, dimensions.z)
        let gridExtent: CGFloat
        let minorStep: CGFloat
        let majorStep: CGFloat

        if maxFootprint <= 80 {
            gridExtent = 50.0   // 100x100mm plate
            minorStep = 5.0
            majorStep = 25.0
        } else if maxFootprint <= 180 {
            gridExtent = 100.0  // 200x200mm plate
            minorStep = 10.0
            majorStep = 50.0
        } else if maxFootprint <= 280 {
            gridExtent = 150.0  // 300x300mm plate
            minorStep = 10.0
            majorStep = 50.0
        } else {
            gridExtent = max(150.0, ceil(maxFootprint * 1.25 / 50.0) * 25.0)
            minorStep = 10.0
            majorStep = 50.0
        }

        // 1. Build plate surface (floor)
        let bedWidth = gridExtent * 2.0
        let bedPlane = SCNPlane(width: bedWidth, height: bedWidth)
        bedPlane.cornerRadius = 4.0
        let floorMat = SCNMaterial()
        floorMat.name = "GridFloorMat"
        floorMat.lightingModel = .constant
        floorMat.isDoubleSided = true
        floorMat.writesToDepthBuffer = true
        floorMat.readsFromDepthBuffer = true
        floorMat.diffuse.contents = isDark ? NSColor(white: 0.12, alpha: 0.85) : NSColor(white: 0.94, alpha: 0.85)
        bedPlane.materials = [floorMat]

        let floorNode = SCNNode(geometry: bedPlane)
        floorNode.name = "GridFloor"
        floorNode.eulerAngles = SCNVector3(-CGFloat.pi / 2.0, 0, 0)
        floorNode.position = SCNVector3(0, -0.05, 0)
        gridRoot.addChildNode(floorNode)

        // Line geometries: Minor, Major, Center, and Border
        var minorVertices: [SCNVector3] = []
        var minorIndices: [Int32] = []
        var minorIdx: Int32 = 0

        var majorVertices: [SCNVector3] = []
        var majorIndices: [Int32] = []
        var majorIdx: Int32 = 0

        var centerVertices: [SCNVector3] = []
        var centerIndices: [Int32] = []
        var centerIdx: Int32 = 0

        let yOffset: CGFloat = 0.01

        var p: CGFloat = -gridExtent + minorStep
        while p <= gridExtent - minorStep + 0.001 {
            let isCenter = abs(p) < 0.001
            let isMajor = abs(p.truncatingRemainder(dividingBy: majorStep)) < 0.001 || abs(abs(p) - majorStep) < 0.001

            if isCenter {
                centerVertices.append(SCNVector3(p, yOffset, -gridExtent))
                centerVertices.append(SCNVector3(p, yOffset, gridExtent))
                centerIndices.append(centerIdx)
                centerIndices.append(centerIdx + 1)
                centerIdx += 2

                centerVertices.append(SCNVector3(-gridExtent, yOffset, p))
                centerVertices.append(SCNVector3(gridExtent, yOffset, p))
                centerIndices.append(centerIdx)
                centerIndices.append(centerIdx + 1)
                centerIdx += 2
            } else if isMajor {
                majorVertices.append(SCNVector3(p, yOffset, -gridExtent))
                majorVertices.append(SCNVector3(p, yOffset, gridExtent))
                majorIndices.append(majorIdx)
                majorIndices.append(majorIdx + 1)
                majorIdx += 2

                majorVertices.append(SCNVector3(-gridExtent, yOffset, p))
                majorVertices.append(SCNVector3(gridExtent, yOffset, p))
                majorIndices.append(majorIdx)
                majorIndices.append(majorIdx + 1)
                majorIdx += 2
            } else {
                minorVertices.append(SCNVector3(p, yOffset, -gridExtent))
                minorVertices.append(SCNVector3(p, yOffset, gridExtent))
                minorIndices.append(minorIdx)
                minorIndices.append(minorIdx + 1)
                minorIdx += 2

                minorVertices.append(SCNVector3(-gridExtent, yOffset, p))
                minorVertices.append(SCNVector3(gridExtent, yOffset, p))
                minorIndices.append(minorIdx)
                minorIndices.append(minorIdx + 1)
                minorIdx += 2
            }

            p += minorStep
        }

        // Border rectangle
        let borderVertices: [SCNVector3] = [
            SCNVector3(-gridExtent, yOffset, -gridExtent),
            SCNVector3(gridExtent, yOffset, -gridExtent),
            SCNVector3(gridExtent, yOffset, -gridExtent),
            SCNVector3(gridExtent, yOffset, gridExtent),
            SCNVector3(gridExtent, yOffset, gridExtent),
            SCNVector3(-gridExtent, yOffset, gridExtent),
            SCNVector3(-gridExtent, yOffset, gridExtent),
            SCNVector3(-gridExtent, yOffset, -gridExtent),
        ]
        let borderIndices: [Int32] = [0, 1, 2, 3, 4, 5, 6, 7]

        // Create minor lines node
        if !minorVertices.isEmpty {
            let minorGeo = SCNGeometry(sources: [SCNGeometrySource(vertices: minorVertices)],
                                       elements: [SCNGeometryElement(indices: minorIndices, primitiveType: .line)])
            let minorMat = SCNMaterial()
            minorMat.name = "GridMinorMat"
            minorMat.lightingModel = .constant
            minorMat.writesToDepthBuffer = false
            minorMat.readsFromDepthBuffer = true
            minorMat.diffuse.contents = isDark ? NSColor(white: 0.65, alpha: 0.50) : NSColor(white: 0.40, alpha: 0.45)
            minorGeo.materials = [minorMat]
            let minorNode = SCNNode(geometry: minorGeo)
            minorNode.name = "GridMinorLines"
            gridRoot.addChildNode(minorNode)
        }

        // Create major lines node
        if !majorVertices.isEmpty {
            let majorGeo = SCNGeometry(sources: [SCNGeometrySource(vertices: majorVertices)],
                                       elements: [SCNGeometryElement(indices: majorIndices, primitiveType: .line)])
            let majorMat = SCNMaterial()
            majorMat.name = "GridMajorMat"
            majorMat.lightingModel = .constant
            majorMat.writesToDepthBuffer = false
            majorMat.readsFromDepthBuffer = true
            majorMat.diffuse.contents = isDark ? NSColor(white: 0.88, alpha: 0.80) : NSColor(white: 0.18, alpha: 0.75)
            majorGeo.materials = [majorMat]
            let majorNode = SCNNode(geometry: majorGeo)
            majorNode.name = "GridMajorLines"
            gridRoot.addChildNode(majorNode)
        }

        // Create center lines node
        if !centerVertices.isEmpty {
            let centerGeo = SCNGeometry(sources: [SCNGeometrySource(vertices: centerVertices)],
                                        elements: [SCNGeometryElement(indices: centerIndices, primitiveType: .line)])
            let centerMat = SCNMaterial()
            centerMat.name = "GridCenterMat"
            centerMat.lightingModel = .constant
            centerMat.writesToDepthBuffer = false
            centerMat.readsFromDepthBuffer = true
            centerMat.diffuse.contents = isDark ? NSColor(white: 1.0, alpha: 0.95) : NSColor(white: 0.05, alpha: 0.90)
            centerGeo.materials = [centerMat]
            let centerNode = SCNNode(geometry: centerGeo)
            centerNode.name = "GridCenterLines"
            gridRoot.addChildNode(centerNode)
        }

        // Create border node
        let borderGeo = SCNGeometry(sources: [SCNGeometrySource(vertices: borderVertices)],
                                    elements: [SCNGeometryElement(indices: borderIndices, primitiveType: .line)])
        let borderMat = SCNMaterial()
        borderMat.name = "GridBorderMat"
        borderMat.lightingModel = .constant
        borderMat.writesToDepthBuffer = false
        borderMat.readsFromDepthBuffer = true
        borderMat.diffuse.contents = isDark ? NSColor(white: 0.90, alpha: 0.85) : NSColor(white: 0.15, alpha: 0.80)
        borderGeo.materials = [borderMat]
        let borderNode = SCNNode(geometry: borderGeo)
        borderNode.name = "GridBorder"
        gridRoot.addChildNode(borderNode)

        return gridRoot
    }

    public static func updateGridAppearance(in gridRoot: SCNNode, isDark: Bool) {
        if let floor = gridRoot.childNode(withName: "GridFloor", recursively: true)?.geometry?.material(named: "GridFloorMat") {
            floor.diffuse.contents = isDark ? NSColor(white: 0.12, alpha: 0.85) : NSColor(white: 0.94, alpha: 0.85)
        }
        if let minor = gridRoot.childNode(withName: "GridMinorLines", recursively: true)?.geometry?.material(named: "GridMinorMat") {
            minor.diffuse.contents = isDark ? NSColor(white: 0.65, alpha: 0.50) : NSColor(white: 0.40, alpha: 0.45)
        }
        if let major = gridRoot.childNode(withName: "GridMajorLines", recursively: true)?.geometry?.material(named: "GridMajorMat") {
            major.diffuse.contents = isDark ? NSColor(white: 0.88, alpha: 0.80) : NSColor(white: 0.18, alpha: 0.75)
        }
        if let center = gridRoot.childNode(withName: "GridCenterLines", recursively: true)?.geometry?.material(named: "GridCenterMat") {
            center.diffuse.contents = isDark ? NSColor(white: 1.0, alpha: 0.95) : NSColor(white: 0.05, alpha: 0.90)
        }
        if let border = gridRoot.childNode(withName: "GridBorder", recursively: true)?.geometry?.material(named: "GridBorderMat") {
            border.diffuse.contents = isDark ? NSColor(white: 0.90, alpha: 0.85) : NSColor(white: 0.15, alpha: 0.80)
        }
    }

    private static func setupLighting(in scene: SCNScene, center: SCNVector3, maxDimension: CGFloat) {
        // Main key light (directional, front-right-top)
        let keyLight = SCNLight()
        keyLight.type = .directional
        keyLight.color = NSColor(white: 1.0, alpha: 1.0)
        keyLight.intensity = 1000

        let keyLightNode = SCNNode()
        keyLightNode.light = keyLight
        keyLightNode.position = SCNVector3(center.x + maxDimension * 2, center.y + maxDimension * 3, center.z + maxDimension * 2.5)
        keyLightNode.look(at: center)
        scene.rootNode.addChildNode(keyLightNode)

        // Fill light (directional, back-left-top)
        let fillLight = SCNLight()
        fillLight.type = .directional
        fillLight.color = NSColor(white: 0.8, alpha: 1.0)
        fillLight.intensity = 600

        let fillLightNode = SCNNode()
        fillLightNode.light = fillLight
        fillLightNode.position = SCNVector3(center.x - maxDimension * 2, center.y + maxDimension * 2, center.z - maxDimension * 2)
        fillLightNode.look(at: center)
        scene.rootNode.addChildNode(fillLightNode)

        // Soft bottom/rim light
        let rimLight = SCNLight()
        rimLight.type = .directional
        rimLight.color = NSColor(white: 0.5, alpha: 1.0)
        rimLight.intensity = 400

        let rimLightNode = SCNNode()
        rimLightNode.light = rimLight
        rimLightNode.position = SCNVector3(center.x, center.y - maxDimension, center.z - maxDimension * 2)
        rimLightNode.look(at: center)
        scene.rootNode.addChildNode(rimLightNode)

        // Ambient light for clear visibility of shadows
        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.color = NSColor(white: 0.45, alpha: 1.0)

        let ambientNode = SCNNode()
        ambientNode.light = ambientLight
        scene.rootNode.addChildNode(ambientNode)
    }
}
