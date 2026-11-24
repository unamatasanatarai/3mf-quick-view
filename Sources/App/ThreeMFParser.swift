import Foundation
import SceneKit

public enum ThreeMFParserError: LocalizedError {
    case fileNotFound(String)
    case extractionFailed(String)
    case modelFileNotFound
    case xmlParseError(String)
    case emptyDocument

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .extractionFailed(let detail):
            return "Failed to extract 3MF archive: \(detail)"
        case .modelFileNotFound:
            return "No valid 3D model found inside 3MF package"
        case .xmlParseError(let detail):
            return "Failed to parse 3MF model XML: \(detail)"
        case .emptyDocument:
            return "3MF document contains no displayable meshes or objects"
        }
    }
}

public final class ThreeMFParser {
    private var document: ThreeMFDocument = ThreeMFDocument()

    public static func load(from url: URL) throws -> ThreeMFDocument {
        let parser = ThreeMFParser()
        return try parser.parse(url: url)
    }

    public func parse(url: URL) throws -> ThreeMFDocument {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ThreeMFParserError.fileNotFound(url.path)
        }

        self.document = ThreeMFDocument()
        self.document.fileURL = url

        let isModelXml = url.pathExtension.lowercased() == "model" || url.pathExtension.lowercased() == "xml"

        if isModelXml {
            let data = try Data(contentsOf: url)
            parseModelData(data, relativePath: url.lastPathComponent, isPrimary: true)
            return self.document
        }

        // Read the OPC/ZIP package fully in-process (no subprocess: the Quick Look
        // extension is sandboxed and may not exec /usr/bin/unzip).
        let archive: ZipArchive
        do {
            archive = try ZipArchive(url: url)
        } catch {
            throw ThreeMFParserError.extractionFailed(error.localizedDescription)
        }

        var modelEntries = archive.entries.filter { $0.path.lowercased().hasSuffix(".model") }
        guard !modelEntries.isEmpty else {
            throw ThreeMFParserError.modelFileNotFound
        }

        // The root model (build items, metadata) must be parsed first: it is the "primary" part.
        let rootPath = ThreeMFParser.rootModelPath(in: archive) ?? "3D/3dmodel.model"
        let rootLower = ZipArchive.normalize(rootPath).lowercased()
        modelEntries.sort { a, b in
            let aRoot = ZipArchive.normalize(a.path).lowercased() == rootLower
            let bRoot = ZipArchive.normalize(b.path).lowercased() == rootLower
            if aRoot != bRoot { return aRoot }
            return a.path < b.path
        }
        let hasRoot = modelEntries.first.map { ZipArchive.normalize($0.path).lowercased() == rootLower } ?? false

        for (index, entry) in modelEntries.enumerated() {
            let data: Data
            do {
                data = try archive.extract(entry)
            } catch {
                if index == 0 && hasRoot {
                    throw ThreeMFParserError.extractionFailed(error.localizedDescription)
                }
                continue
            }
            parseModelData(data, relativePath: ZipArchive.normalize(entry.path), isPrimary: index == 0)
        }

        return self.document
    }

    /// Resolves the root model part from `_rels/.rels` (OPC start part), if present.
    static func rootModelPath(in archive: ZipArchive) -> String? {
        guard let relsEntry = archive.entry(named: "_rels/.rels"),
              let relsData = try? archive.extract(relsEntry),
              let rels = String(data: relsData, encoding: .utf8) else { return nil }
        // <Relationship Target="/3D/3dmodel.model" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>
        for chunk in rels.components(separatedBy: "<Relationship").dropFirst() {
            guard chunk.contains("3dmanufacturing/2013/01/3dmodel") else { continue }
            if let r = chunk.range(of: "Target=\"") {
                let rest = chunk[r.upperBound...]
                if let q = rest.firstIndex(of: "\"") {
                    return String(rest[..<q])
                }
            }
        }
        return nil
    }

    public func parse(xmlData: Data) throws -> ThreeMFDocument {
        self.document = ThreeMFDocument()
        parseModelData(xmlData, relativePath: "3D/3dmodel.model", isPrimary: true)
        return self.document
    }

    // MARK: - Fast Robust .model Parser

    private func parseModelData(_ input: Data, relativePath: String, isPrimary: Bool) {
        guard !input.isEmpty else { return }
        // strtod/strtol need a terminator, and the scanner peeks a few bytes ahead:
        // pad with NUL bytes so neither can ever read past the buffer.
        var data = input
        data.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        let count = input.count

        let normalizedPath = relativePath.hasPrefix("/") ? String(relativePath.dropFirst()) : relativePath
        let slashPath = "/" + normalizedPath

        data.withUnsafeBytes { (rawPtr: UnsafeRawBufferPointer) in
            guard let base = rawPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }

            var i = 0

            var currentObject: ThreeMFObject?
            var currentMesh: ThreeMFMesh?
            var currentColorGroupId: String?
            var currentColors: [ThreeMFColor] = []

            func skipWhitespace() {
                while i < count && (base[i] == 32 || base[i] == 9 || base[i] == 10 || base[i] == 13) {
                    i += 1
                }
            }

            func parseAttributes() -> [String: String] {
                var attrs: [String: String] = [:]
                while i < count && base[i] != 62 && base[i] != 47 { // not '>' and not '/'
                    skipWhitespace()
                    guard i < count && base[i] != 62 && base[i] != 47 else { break }

                    // Read key
                    let keyStart = i
                    while i < count && base[i] != 61 && base[i] != 32 && base[i] != 62 && base[i] != 47 {
                        i += 1
                    }
                    let keyLen = i - keyStart
                    guard keyLen > 0 else {
                        i += 1
                        continue
                    }

                    let keyStr = String(decoding: UnsafeBufferPointer(start: base + keyStart, count: keyLen), as: UTF8.self)

                    skipWhitespace()
                    guard i < count && base[i] == 61 else { continue } // '='
                    i += 1 // skip '='
                    skipWhitespace()

                    guard i < count && (base[i] == 34 || base[i] == 39) else { continue } // '"' or '\''
                    let quote = base[i]
                    i += 1 // skip quote
                    let valStart = i
                    while i < count && base[i] != quote {
                        i += 1
                    }
                    let valLen = i - valStart
                    let valStr = String(decoding: UnsafeBufferPointer(start: base + valStart, count: valLen), as: UTF8.self)
                    if i < count && base[i] == quote {
                        i += 1 // skip closing quote
                    }

                    // Strip XML namespace prefix if present in key (e.g. p:path -> path, m:color -> color)
                    let cleanKey = keyStr.components(separatedBy: ":").last?.lowercased() ?? keyStr.lowercased()
                    attrs[cleanKey] = valStr
                }
                return attrs
            }

            while i < count {
                if base[i] == 60 { // '<'
                    i += 1
                    if i < count && base[i] == 33 { // comment or DOCTYPE e.g. "<!--"
                        while i + 2 < count && !(base[i] == 45 && base[i+1] == 45 && base[i+2] == 62) {
                            i += 1
                        }
                        i += 3
                        continue
                    }
                    if i < count && base[i] == 63 { // "<?xml"
                        while i < count && base[i] != 62 { i += 1 }
                        i += 1
                        continue
                    }

                    let isClosing = (i < count && base[i] == 47) // '/'
                    if isClosing { i += 1 }

                    let tagStart = i
                    while i < count && base[i] != 32 && base[i] != 62 && base[i] != 47 && base[i] != 10 && base[i] != 13 && base[i] != 9 {
                        i += 1
                    }
                    let tagLen = i - tagStart
                    guard tagLen > 0 else { continue }

                    let rawTag = String(decoding: UnsafeBufferPointer(start: base + tagStart, count: tagLen), as: UTF8.self)
                    let tag = rawTag.components(separatedBy: ":").last?.lowercased() ?? rawTag.lowercased()

                    if isClosing {
                        // Handle closing tags
                        switch tag {
                        case "mesh":
                            if var obj = currentObject {
                                obj.mesh = currentMesh
                                currentObject = obj
                            }
                            currentMesh = nil
                        case "object":
                            if let obj = currentObject {
                                if isPrimary {
                                    document.objects[obj.id] = obj
                                } else {
                                    document.objects["\(normalizedPath):\(obj.id)"] = obj
                                    document.objects["\(slashPath):\(obj.id)"] = obj
                                    if document.objects[obj.id] == nil {
                                        document.objects[obj.id] = obj
                                    }
                                }
                            }
                            currentObject = nil
                        case "colorgroup", "basematerials":
                            if let id = currentColorGroupId {
                                document.colors[id] = currentColors
                            }
                            currentColorGroupId = nil
                            currentColors = []
                        default:
                            break
                        }

                        // Skip to '>'
                        while i < count && base[i] != 62 { i += 1 }
                        if i < count && base[i] == 62 { i += 1 }
                        continue
                    }

                    // Opening tag: parse attributes
                    let attrs = parseAttributes()

                    let isSelfClosing: Bool = {
                        var temp = i
                        while temp < count && base[temp] != 62 {
                            if base[temp] == 47 { return true }
                            temp += 1
                        }
                        return false
                    }()

                    switch tag {
                    case "model":
                        if isPrimary, let unit = attrs["unit"] {
                            document.unit = unit
                        }

                    case "metadata":
                        if isPrimary && attrs["name"]?.lowercased() == "title" {
                            // Find metadata content between '>' and '<'
                            while i < count && base[i] != 62 { i += 1 }
                            if i < count && base[i] == 62 { i += 1 }
                            let textStart = i
                            while i < count && base[i] != 60 { i += 1 }
                            let textLen = i - textStart
                            if textLen > 0 {
                                let s = String(decoding: UnsafeBufferPointer(start: base + textStart, count: textLen), as: UTF8.self)
                                document.title = s.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        }

                    case "object":
                        if let id = attrs["id"] {
                            let name = attrs["name"]
                            let type = attrs["type"]
                            let pid = attrs["pid"]
                            let pindex = attrs["pindex"].flatMap { Int($0) }
                            currentObject = ThreeMFObject(id: id, sourcePath: slashPath, name: name, type: type, mesh: nil, components: [], pid: pid, pindex: pindex)
                        }

                    case "mesh":
                        currentMesh = ThreeMFMesh()

                    case "vertices":
                        // Fast scanner for all <vertex ... /> tags inside <vertices>
                        if currentMesh != nil {
                            let approxVertices = max(64, min(1_000_000, (count - i) / 45))
                            currentMesh?.vertices.reserveCapacity(approxVertices)
                            while i < count {
                                while i < count && base[i] != 60 { i += 1 }
                                guard i + 7 < count else { break }

                                if base[i+1] == 47 && base[i+2] == 118 { // "</v" -> "</vertices>"
                                    break
                                }
                                if base[i+1] == 118 && base[i+2] == 101 && base[i+3] == 114 && base[i+4] == 116 && base[i+5] == 101 && base[i+6] == 120 { // "<vertex"
                                    i += 7
                                    var x: Double = 0, y: Double = 0, z: Double = 0
                                    while i < count && base[i] != 62 {
                                        if (base[i] == 120 || base[i] == 88) && base[i+1] == 61 && base[i+2] == 34 { // x="
                                            i += 3
                                            x = strtod(UnsafeRawPointer(base + i).assumingMemoryBound(to: CChar.self), nil)
                                        } else if (base[i] == 121 || base[i] == 89) && base[i+1] == 61 && base[i+2] == 34 { // y="
                                            i += 3
                                            y = strtod(UnsafeRawPointer(base + i).assumingMemoryBound(to: CChar.self), nil)
                                        } else if (base[i] == 122 || base[i] == 90) && base[i+1] == 61 && base[i+2] == 34 { // z="
                                            i += 3
                                            z = strtod(UnsafeRawPointer(base + i).assumingMemoryBound(to: CChar.self), nil)
                                        }
                                        i += 1
                                    }
                                    currentMesh?.vertices.append(SCNVector3(CGFloat(x), CGFloat(y), CGFloat(z)))
                                } else {
                                    i += 1
                                }
                            }
                        }

                    case "triangles":
                        // Fast scanner for all <triangle ... /> tags inside <triangles>
                        if currentMesh != nil {
                            let approxTriangles = max(64, min(2_000_000, (count - i) / 40))
                            currentMesh?.triangles.reserveCapacity(approxTriangles)
                            while i < count {
                                while i < count && base[i] != 60 { i += 1 }
                                guard i + 9 < count else { break }

                                if base[i+1] == 47 && base[i+2] == 116 { // "</t" -> "</triangles>"
                                    break
                                }
                                if base[i+1] == 116 && base[i+2] == 114 && base[i+3] == 105 && base[i+4] == 97 && base[i+5] == 110 && base[i+6] == 103 && base[i+7] == 108 && base[i+8] == 101 { // "<triangle"
                                    i += 9
                                    var v1: Int32 = 0, v2: Int32 = 0, v3: Int32 = 0
                                    let pid: String? = nil
                                    var p1: Int32?
                                    while i < count && base[i] != 62 {
                                        if base[i] == 118 && base[i+1] == 49 && base[i+2] == 61 && base[i+3] == 34 { // v1="
                                            i += 4
                                            v1 = Int32(strtol(UnsafeRawPointer(base + i).assumingMemoryBound(to: CChar.self), nil, 10))
                                        } else if base[i] == 118 && base[i+1] == 50 && base[i+2] == 61 && base[i+3] == 34 { // v2="
                                            i += 4
                                            v2 = Int32(strtol(UnsafeRawPointer(base + i).assumingMemoryBound(to: CChar.self), nil, 10))
                                        } else if base[i] == 118 && base[i+1] == 51 && base[i+2] == 61 && base[i+3] == 34 { // v3="
                                            i += 4
                                            v3 = Int32(strtol(UnsafeRawPointer(base + i).assumingMemoryBound(to: CChar.self), nil, 10))
                                        } else if base[i] == 112 && base[i+1] == 49 && base[i+2] == 61 && base[i+3] == 34 { // p1="
                                            i += 4
                                            p1 = Int32(strtol(UnsafeRawPointer(base + i).assumingMemoryBound(to: CChar.self), nil, 10))
                                        }
                                        i += 1
                                    }
                                    currentMesh?.triangles.append(ThreeMFTriangle(v1: v1, v2: v2, v3: v3, pid: pid, p1: p1))
                                } else {
                                    i += 1
                                }
                            }
                        }

                    case "component":
                        if let objectId = attrs["objectid"] {
                            let path = attrs["path"] // e.g. p:path="/3D/Objects/object_2.model"
                            let transform: SCNMatrix4? = attrs["transform"].flatMap { ThreeMFMatrixParser.parse($0) }
                            currentObject?.components.append(ThreeMFComponent(path: path, objectId: objectId, transform: transform))
                        }

                    case "colorgroup", "basematerials":
                        currentColorGroupId = attrs["id"]
                        currentColors = []

                    case "color", "base":
                        if let hex = attrs["color"] ?? attrs["displaycolor"], let c = ThreeMFColor.from(hex: hex) {
                            currentColors.append(c)
                        }

                    case "item":
                        if isPrimary, let objectId = attrs["objectid"] {
                            let transform: SCNMatrix4? = attrs["transform"].flatMap { ThreeMFMatrixParser.parse($0) }
                            let partNumber = attrs["partnumber"]
                            document.buildItems.append(ThreeMFBuildItem(objectId: objectId, transform: transform, partNumber: partNumber))
                        }

                    default:
                        break
                    }

                    if isSelfClosing {
                        if tag == "object", let obj = currentObject {
                            if isPrimary {
                                document.objects[obj.id] = obj
                            } else {
                                document.objects["\(normalizedPath):\(obj.id)"] = obj
                                document.objects["\(slashPath):\(obj.id)"] = obj
                                if document.objects[obj.id] == nil {
                                    document.objects[obj.id] = obj
                                }
                            }
                            currentObject = nil
                        }
                    }

                    // Advance past '>'
                    while i < count && base[i] != 62 { i += 1 }
                    if i < count && base[i] == 62 { i += 1 }
                } else {
                    i += 1
                }
            }
        }
    }
}
