import Foundation
import SceneKit

// MARK: - 3MF Data Models

public struct ThreeMFTriangle {
    public let v1: Int32
    public let v2: Int32
    public let v3: Int32
    public let pid: String?
    public let p1: Int32?
    public let p2: Int32?
    public let p3: Int32?

    public init(v1: Int32, v2: Int32, v3: Int32, pid: String? = nil, p1: Int32? = nil, p2: Int32? = nil, p3: Int32? = nil) {
        self.v1 = v1
        self.v2 = v2
        self.v3 = v3
        self.pid = pid
        self.p1 = p1
        self.p2 = p2
        self.p3 = p3
    }
}

public struct ThreeMFMesh {
    public var vertices: [SCNVector3]
    public var triangles: [ThreeMFTriangle]

    public init(vertices: [SCNVector3] = [], triangles: [ThreeMFTriangle] = []) {
        self.vertices = vertices
        self.triangles = triangles
    }
}

public struct ThreeMFComponent {
    public let path: String?
    public let objectId: String
    public let transform: SCNMatrix4?

    public init(path: String? = nil, objectId: String, transform: SCNMatrix4? = nil) {
        self.path = path
        self.objectId = objectId
        self.transform = transform
    }
}

public struct ThreeMFObject {
    public let id: String
    public let sourcePath: String?
    public let name: String?
    public let type: String?
    public var mesh: ThreeMFMesh?
    public var components: [ThreeMFComponent]
    public let pid: String?
    public let pindex: Int?

    public init(id: String, sourcePath: String? = nil, name: String? = nil, type: String? = nil, mesh: ThreeMFMesh? = nil, components: [ThreeMFComponent] = [], pid: String? = nil, pindex: Int? = nil) {
        self.id = id
        self.sourcePath = sourcePath
        self.name = name
        self.type = type
        self.mesh = mesh
        self.components = components
        self.pid = pid
        self.pindex = pindex
    }
}

public struct ThreeMFBuildItem {
    public let objectId: String
    public let transform: SCNMatrix4?
    public let partNumber: String?

    public init(objectId: String, transform: SCNMatrix4? = nil, partNumber: String? = nil) {
        self.objectId = objectId
        self.transform = transform
        self.partNumber = partNumber
    }
}

public struct ThreeMFColor {
    public let r: CGFloat
    public let g: CGFloat
    public let b: CGFloat
    public let a: CGFloat

    public init(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1.0) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// Parse hex color string e.g. "#RRGGBB" or "#RRGGBBAA"
    public static func from(hex: String) -> ThreeMFColor? {
        var cleanHex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanHex.hasPrefix("#") {
            cleanHex.removeFirst()
        }
        guard cleanHex.count == 6 || cleanHex.count == 8 else { return nil }

        var intVal: UInt64 = 0
        guard Scanner(string: cleanHex).scanHexInt64(&intVal) else { return nil }

        if cleanHex.count == 6 {
            let r = CGFloat((intVal >> 16) & 0xFF) / 255.0
            let g = CGFloat((intVal >> 8) & 0xFF) / 255.0
            let b = CGFloat(intVal & 0xFF) / 255.0
            return ThreeMFColor(r: r, g: g, b: b, a: 1.0)
        } else {
            let r = CGFloat((intVal >> 24) & 0xFF) / 255.0
            let g = CGFloat((intVal >> 16) & 0xFF) / 255.0
            let b = CGFloat((intVal >> 8) & 0xFF) / 255.0
            let a = CGFloat(intVal & 0xFF) / 255.0
            return ThreeMFColor(r: r, g: g, b: b, a: a)
        }
    }

    public var nsColor: NSColor {
        return NSColor(red: r, green: g, blue: b, alpha: a)
    }
}

public final class ThreeMFDocument {
    public var unit: String
    public var title: String?
    public var objects: [String: ThreeMFObject]
    public var buildItems: [ThreeMFBuildItem]
    public var colors: [String: [ThreeMFColor]]
    public var fileURL: URL?

    public init(unit: String = "millimeter", title: String? = nil, objects: [String: ThreeMFObject] = [:], buildItems: [ThreeMFBuildItem] = [], colors: [String: [ThreeMFColor]] = [:], fileURL: URL? = nil) {
        self.unit = unit
        self.title = title
        self.objects = objects
        self.buildItems = buildItems
        self.colors = colors
        self.fileURL = fileURL
    }

    /// Multiplier to normalize coordinates to millimeters
    public var unitScaleToMillimeters: CGFloat {
        switch unit.lowercased() {
        case "micron": return 0.001
        case "centimeter": return 10.0
        case "meter": return 1000.0
        case "inch": return 25.4
        case "foot": return 304.8
        default: return 1.0 // millimeter
        }
    }

    public func findObject(path: String?, id: String, currentSourcePath: String? = nil) -> ThreeMFObject? {
        if let p = path, !p.isEmpty {
            let clean = normalizePath(p)
            if let obj = objects["\(clean):\(id)"] { return obj }
            if let obj = objects["/\(clean):\(id)"] { return obj }
            if let obj = objects["\(p):\(id)"] { return obj }

            let filename = URL(fileURLWithPath: p).lastPathComponent
            for (key, obj) in objects {
                if key.contains(filename) && obj.id == id {
                    return obj
                }
            }
        }

        if let cur = currentSourcePath, !cur.isEmpty {
            let clean = normalizePath(cur)
            if let obj = objects["\(clean):\(id)"] { return obj }
            if let obj = objects["/\(clean):\(id)"] { return obj }
            if let obj = objects["\(cur):\(id)"] { return obj }
        }

        if let obj = objects[id] { return obj }

        for (_, obj) in objects {
            if obj.id == id { return obj }
        }

        return nil
    }

    private func normalizePath(_ p: String) -> String {
        var s = p.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("/") { s.removeFirst() }
        return s
    }

    public var totalTriangles: Int {
        var count = 0
        if !buildItems.isEmpty {
            for item in buildItems {
                if let obj = findObject(path: nil, id: item.objectId) {
                    count += countTriangles(for: obj)
                }
            }
        }
        if count == 0 {
            for (_, object) in objects {
                if let mesh = object.mesh {
                    count += mesh.triangles.count
                }
            }
        }
        return count
    }

    public var totalVertices: Int {
        var count = 0
        if !buildItems.isEmpty {
            for item in buildItems {
                if let obj = findObject(path: nil, id: item.objectId) {
                    count += countVertices(for: obj)
                }
            }
        }
        if count == 0 {
            for (_, object) in objects {
                if let mesh = object.mesh {
                    count += mesh.vertices.count
                }
            }
        }
        return count
    }

    private func countTriangles(for obj: ThreeMFObject) -> Int {
        var total = obj.mesh?.triangles.count ?? 0
        for comp in obj.components {
            if let child = findObject(path: comp.path, id: comp.objectId, currentSourcePath: obj.sourcePath) {
                total += countTriangles(for: child)
            }
        }
        return total
    }

    private func countVertices(for obj: ThreeMFObject) -> Int {
        var total = obj.mesh?.vertices.count ?? 0
        for comp in obj.components {
            if let child = findObject(path: comp.path, id: comp.objectId, currentSourcePath: obj.sourcePath) {
                total += countVertices(for: child)
            }
        }
        return total
    }
}

// MARK: - 3MF Matrix Utilities

public enum ThreeMFMatrixParser {
    public static func parse(_ string: String) -> SCNMatrix4? {
        let parts = string.split(whereSeparator: { $0.isWhitespace }).compactMap { Double($0).map { CGFloat($0) } }
        guard parts.count == 12 else { return nil }

        return SCNMatrix4(
            m11: parts[0],  m12: parts[1],  m13: parts[2],  m14: 0,
            m21: parts[3],  m22: parts[4],  m23: parts[5],  m24: 0,
            m31: parts[6],  m32: parts[7],  m33: parts[8],  m34: 0,
            m41: parts[9],  m42: parts[10], m43: parts[11], m44: 1
        )
    }
}
