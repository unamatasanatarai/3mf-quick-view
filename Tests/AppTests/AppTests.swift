import Foundation
import SceneKit
import AppKit

public enum AppTests {
    private static func sampleModelURL() throws -> URL {
        let testCube = URL(fileURLWithPath: "models/test_cube.3mf")
        if FileManager.default.fileExists(atPath: testCube.path) {
            return testCube
        }
        let fox = URL(fileURLWithPath: "models/design fox reindeer rabbit.3mf")
        if FileManager.default.fileExists(atPath: fox.path) {
            return fox
        }
        let eeyore = URL(fileURLWithPath: "models/flexi+eeyore+profile.3mf")
        if FileManager.default.fileExists(atPath: eeyore.path) {
            return eeyore
        }
        throw NSError(domain: "Test", code: 404, userInfo: [NSLocalizedDescriptionKey: "No test fixture found in models/"])
    }

    public static func run(testRunner: (String, () throws -> Void) -> Void) {
        testRunner("AppConfig returns valid non-empty application name") {
            assert(!AppConfig.appName.isEmpty, "App name should not be empty")
        }

        testRunner("AppConfig returns valid bundle identifier") {
            assert(!AppConfig.bundleIdentifier.isEmpty, "Bundle identifier should not be empty")
            assert(AppConfig.bundleIdentifier.contains("."), "Bundle identifier should be reverse-DNS style")
        }

        testRunner("AppConfig provides version string") {
            assert(!AppConfig.version.isEmpty, "Version should not be empty")
        }

        testRunner("AppConfig provides build number") {
            assert(!AppConfig.buildNumber.isEmpty, "Build number should not be empty")
        }

        testRunner("StatusBarController initializes menu correctly") {
            let controller = StatusBarController()
            assert(controller.currentMenu.items.count >= 2, "Menu should have items")
            assert(controller.currentMenu.items.contains { $0.title.contains("Quit") }, "Menu should contain quit item")
        }

        testRunner("ThreeMFColor parses 6-digit and 8-digit hex colors") {
            let color6 = ThreeMFColor.from(hex: "#FF8000")
            assert(color6 != nil, "Hex with # should parse")
            assert(abs(color6!.r - 1.0) < 0.01, "Red channel should be ~1.0")
            assert(abs(color6!.g - 0.5) < 0.02, "Green channel should be ~0.5")
            assert(abs(color6!.b - 0.0) < 0.01, "Blue channel should be ~0.0")

            let color8 = ThreeMFColor.from(hex: "00FF0080")
            assert(color8 != nil, "8-digit hex without # should parse")
            assert(abs(color8!.g - 1.0) < 0.01, "Green channel should be ~1.0")
            assert(abs(color8!.a - 0.5) < 0.02, "Alpha channel should be ~0.5")

            assert(ThreeMFColor.from(hex: "invalid") == nil, "Invalid hex should return nil")
        }

        testRunner("ThreeMFMatrixParser parses 12 floats affine matrix correctly") {
            let matrixStr = "1 0 0 0 1 0 0 0 1 10 20 30"
            let matrix = ThreeMFMatrixParser.parse(matrixStr)
            assert(matrix != nil, "Valid 12 floats should parse into SCNMatrix4")
            assert(matrix!.m11 == 1 && matrix!.m22 == 1 && matrix!.m33 == 1, "Diagonal elements should be 1")
            assert(matrix!.m41 == 10 && matrix!.m42 == 20 && matrix!.m43 == 30, "Translation row should be (10, 20, 30)")
            assert(matrix!.m44 == 1, "Affine m44 should be 1")

            assert(ThreeMFMatrixParser.parse("1 2 3") == nil, "Incomplete matrix string should return nil")
        }

        testRunner("ThreeMFParser parses XML model with mesh, vertices and triangles") {
            let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
              <metadata name="Title">Unit Test Pyramid</metadata>
              <resources>
                <object id="1" name="Pyramid" type="model">
                  <mesh>
                    <vertices>
                      <vertex x="0.0" y="0.0" z="0.0" />
                      <vertex x="10.0" y="0.0" z="0.0" />
                      <vertex x="10.0" y="10.0" z="0.0" />
                      <vertex x="0.0" y="10.0" z="0.0" />
                      <vertex x="5.0" y="5.0" z="10.0" />
                    </vertices>
                    <triangles>
                      <triangle v1="0" v2="2" v3="1" />
                      <triangle v1="0" v2="3" v3="2" />
                      <triangle v1="0" v2="1" v3="4" />
                      <triangle v1="1" v2="2" v3="4" />
                      <triangle v1="2" v2="3" v3="4" />
                      <triangle v1="3" v2="0" v3="4" />
                    </triangles>
                  </mesh>
                </object>
              </resources>
              <build>
                <item objectid="1" />
              </build>
            </model>
            """
            guard let data = xml.data(using: .utf8) else {
                throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create XML data"])
            }

            let parser = ThreeMFParser()
            let doc = try parser.parse(xmlData: data)

            assert(doc.title == "Unit Test Pyramid", "Title should match")
            assert(doc.unit == "millimeter", "Unit should be millimeter")
            assert(doc.objects.count == 1, "Should have 1 object")
            assert(doc.buildItems.count == 1, "Should have 1 build item")
            assert(doc.totalVertices == 5, "Should have 5 vertices")
            assert(doc.totalTriangles == 6, "Should have 6 triangles")
        }

        testRunner("ModelSceneBuilder creates SCNScene with geometry, lighting and ground grid") {
            let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
              <resources>
                <object id="1" name="Box" type="model">
                  <mesh>
                    <vertices>
                      <vertex x="0" y="0" z="0" />
                      <vertex x="20" y="0" z="0" />
                      <vertex x="20" y="20" z="0" />
                      <vertex x="0" y="20" z="0" />
                      <vertex x="0" y="0" z="20" />
                      <vertex x="20" y="0" z="20" />
                      <vertex x="20" y="20" z="20" />
                      <vertex x="0" y="20" z="20" />
                    </vertices>
                    <triangles>
                      <triangle v1="0" v2="2" v3="1" />
                      <triangle v1="0" v2="3" v3="2" />
                      <triangle v1="4" v2="5" v3="6" />
                      <triangle v1="4" v2="6" v3="7" />
                    </triangles>
                  </mesh>
                </object>
              </resources>
              <build>
                <item objectid="1" />
              </build>
            </model>
            """
            let doc = try ThreeMFParser().parse(xmlData: xml.data(using: .utf8)!)
            let sceneInfo = ModelSceneBuilder.build(from: doc)

            assert(sceneInfo.scene.rootNode.childNodes.count >= 2, "Scene should contain model and grid nodes")
            assert(sceneInfo.totalTriangles == 4, "Should have 4 triangles")
            assert(sceneInfo.totalVertices == 8, "Should have 8 vertices")
            assert(sceneInfo.dimensions.x > 0 && sceneInfo.dimensions.y > 0 && sceneInfo.dimensions.z > 0, "Dimensions should be positive")
        }

        testRunner("ThreeMFParser loads actual .3mf zip package file from disk") {
            let testCubeURL = URL(fileURLWithPath: "models/test_cube.3mf")
            let foxURL = URL(fileURLWithPath: "models/design fox reindeer rabbit.3mf")
            let eeyoreURL = URL(fileURLWithPath: "models/flexi+eeyore+profile.3mf")
            let targetURL: URL
            if FileManager.default.fileExists(atPath: testCubeURL.path) {
                targetURL = testCubeURL
            } else if FileManager.default.fileExists(atPath: foxURL.path) {
                targetURL = foxURL
            } else if FileManager.default.fileExists(atPath: eeyoreURL.path) {
                targetURL = eeyoreURL
            } else {
                throw NSError(domain: "Test", code: 404, userInfo: [NSLocalizedDescriptionKey: "No 3MF fixture found in models/"])
            }

            do {
                let doc = try ThreeMFParser.load(from: targetURL)
                assert(!doc.objects.isEmpty, "Document should parse objects")
                assert(doc.totalVertices > 0, "Document should have vertices")
                assert(doc.totalTriangles > 0, "Document should have triangles")

                let sceneInfo = ModelSceneBuilder.build(from: doc)
                assert(sceneInfo.totalTriangles > 0, "Scene should have triangles")

                if targetURL == testCubeURL {
                    assert(doc.title == "Test Cube", "Doc title should be Test Cube")
                    assert(doc.totalVertices == 8, "Cube should have 8 vertices")
                    assert(doc.totalTriangles == 12, "Cube should have 12 triangles (6 faces * 2)")
                    assert(sceneInfo.totalTriangles == 12, "Scene should have 12 triangles")
                }
            }

            // Also test real-world multi-file 3MF packages in models/ directory
            let sampleModels = ["models/HI-HO.3mf", "models/FlyingProp Set Speed.3mf", "models/USB+Case.3mf"]
            for path in sampleModels {
                let url = URL(fileURLWithPath: path)
                if FileManager.default.fileExists(atPath: url.path) {
                    let doc = try ThreeMFParser.load(from: url)
                    let sceneInfo = ModelSceneBuilder.build(from: doc)
                    assert(sceneInfo.totalTriangles > 0, "Model \(path) should have triangles")
                    assert(sceneInfo.totalVertices > 0, "Model \(path) should have vertices")
                    assert(sceneInfo.scene.rootNode.childNodes.count > 0, "Scene for \(path) should have nodes")
                }
            }
        }

        testRunner("ZipArchive reads stored and deflated entries without a subprocess") {
            let fixtureURL = try sampleModelURL()
            let archive = try ZipArchive(url: fixtureURL)
            guard let model = archive.entries.first(where: { $0.path.hasSuffix(".model") }) else {
                throw NSError(domain: "Test", code: 2, userInfo: [NSLocalizedDescriptionKey: "3dmodel.model entry missing"])
            }
            let data = try archive.extract(model)
            assert(data.count == model.uncompressedSize, "Extracted size should match header")
            assert(String(decoding: data.prefix(64), as: UTF8.self).contains("<?xml"), "Model part should be XML")
        }

        testRunner("ModelSceneBuilder converts 3MF Z-up to SceneKit Y-up and rests model on plate") {
            // 10 (X) x 20 (Y) x 40 (Z, height) box placed off-origin
            let xml = """
            <model unit="millimeter"><resources><object id="1" type="model"><mesh><vertices>
            <vertex x="100" y="100" z="5"/><vertex x="110" y="100" z="5"/><vertex x="110" y="120" z="5"/><vertex x="100" y="120" z="5"/>
            <vertex x="100" y="100" z="45"/><vertex x="110" y="100" z="45"/><vertex x="110" y="120" z="45"/><vertex x="100" y="120" z="45"/>
            </vertices><triangles>
            <triangle v1="0" v2="1" v3="2"/><triangle v1="4" v2="5" v3="6"/><triangle v1="0" v2="3" v3="7"/>
            </triangles></mesh></object></resources><build><item objectid="1"/></build></model>
            """
            let doc = try ThreeMFParser().parse(xmlData: xml.data(using: .utf8)!)
            let info = ModelSceneBuilder.build(from: doc)
            assert(abs(info.dimensions.x - 10) < 0.01, "Width (X) should be 10, got \(info.dimensions.x)")
            assert(abs(info.dimensions.y - 40) < 0.01, "Height (SceneKit Y = 3MF Z) should be 40, got \(info.dimensions.y)")
            assert(abs(info.dimensions.z - 20) < 0.01, "Depth (SceneKit Z = 3MF Y) should be 20, got \(info.dimensions.z)")
            let box = info.modelContainer.boundingBox
            var minY = CGFloat.greatestFiniteMagnitude
            for z in [box.min.z, box.max.z] {
                minY = min(minY, info.modelContainer.convertPosition(SCNVector3(box.min.x, box.min.y, z), to: nil).y)
            }
            assert(abs(minY) < 0.01, "Model bottom should rest on Y = 0, got \(minY)")
            assert(abs(info.center.y - 20) < 0.01, "Center should be at half height")
        }

        testRunner("ThreeMFView keeps its camera when a model scene is loaded twice") {
            let view = ThreeMFView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            let doc = try ThreeMFParser.load(from: try sampleModelURL())
            let first = ModelSceneBuilder.build(from: doc)
            view.setModelScene(first)
            let second = ModelSceneBuilder.build(from: doc)
            view.setModelScene(second)
            guard let pov = view.pointOfView else {
                throw NSError(domain: "Test", code: 3, userInfo: [NSLocalizedDescriptionKey: "No point of view"])
            }
            var root: SCNNode = pov
            while let parent = root.parent { root = parent }
            assert(root === second.scene.rootNode, "Camera must live in the currently displayed scene")
        }

        testRunner("ThreeMFView controls: left-drag rotates, 2-finger scroll/right-drag pans, pinch/wheel zooms") {
            let view = ThreeMFView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            let doc = try ThreeMFParser.load(from: try sampleModelURL())
            let info = ModelSceneBuilder.build(from: doc)
            view.setModelScene(info)
            guard let cam = view.pointOfView else { throw NSError(domain: "Test", code: 4) }

            func dist(_ a: SCNVector3, _ b: SCNVector3) -> CGFloat {
                sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y) + (a.z - b.z) * (a.z - b.z))
            }
            func mouse(_ type: CGEventType, _ button: CGMouseButton, dx: Int64, dy: Int64) -> NSEvent {
                let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: button)!
                e.setIntegerValueField(.mouseEventDeltaX, value: dx)
                e.setIntegerValueField(.mouseEventDeltaY, value: dy)
                return NSEvent(cgEvent: e)!
            }

            // 1. Rotate: left drag orbits camera around pivot
            let p0 = cam.position
            let r0 = dist(p0, info.center)
            view.mouseDown(with: mouse(.leftMouseDown, .left, dx: 0, dy: 0))
            view.mouseDragged(with: mouse(.leftMouseDragged, .left, dx: 40, dy: 15))
            view.mouseUp(with: mouse(.leftMouseUp, .left, dx: 0, dy: 0))
            let p1 = cam.position
            assert(dist(p0, p1) > 1, "Left drag should orbit the camera")
            assert(abs(dist(p1, info.center) - r0) < 0.01, "Orbit should keep the distance to the pivot")

            // 2. Pan: right drag translates camera without rotating
            let o1 = cam.orientation
            view.rightMouseDown(with: mouse(.rightMouseDown, .right, dx: 0, dy: 0))
            view.rightMouseDragged(with: mouse(.rightMouseDragged, .right, dx: 30, dy: -20))
            view.rightMouseUp(with: mouse(.rightMouseUp, .right, dx: 0, dy: 0))
            let p2 = cam.position
            assert(dist(p1, p2) > 0.5, "Right drag should pan the camera")
            let o2 = cam.orientation
            assert(abs(o1.x - o2.x) + abs(o1.y - o2.y) + abs(o1.z - o2.z) + abs(o1.w - o2.w) < 0.001, "Pan should not rotate")

            // 3. Pan: 2-finger scroll (precise pixel deltas) pans the camera without rotating
            let oPreScroll = cam.orientation
            let pPreScroll = cam.position
            let twoFingerScroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 25, wheel2: 20, wheel3: 0)!
            view.scrollWheel(with: NSEvent(cgEvent: twoFingerScroll)!)
            let pPostScroll = cam.position
            assert(dist(pPreScroll, pPostScroll) > 0.1, "Two-finger scroll should pan the camera")
            let oPostScroll = cam.orientation
            assert(abs(oPreScroll.x - oPostScroll.x) + abs(oPreScroll.y - oPostScroll.y) + abs(oPreScroll.z - oPostScroll.z) + abs(oPreScroll.w - oPostScroll.w) < 0.001, "Two-finger scroll pan should not rotate")

            // 4. Zoom: pinch (magnify gesture) zooms in or out
            final class MockPinchEvent: NSEvent {
                private let _mag: CGFloat
                init(magnification: CGFloat) {
                    self._mag = magnification
                    super.init()
                }
                required init?(coder: NSCoder) { fatalError() }
                override var magnification: CGFloat { _mag }
                override var type: NSEvent.EventType { .magnify }
            }
            let pPrePinch = cam.position
            view.magnify(with: MockPinchEvent(magnification: 0.25))
            let pPostPinch = cam.position
            assert(dist(pPrePinch, pPostPinch) > 0.1, "Pinch should change camera distance")

            // 5. Zoom: traditional notched mouse wheel zooms
            let beforeWheel = cam.position
            let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0)!
            view.scrollWheel(with: NSEvent(cgEvent: wheel)!)
            let afterWheel = cam.position
            assert(dist(beforeWheel, afterWheel) > 0.5, "Scroll wheel should zoom noticeably")

            // Reset returns to the initial framing
            view.resetView(animated: false)
            assert(dist(cam.position, p0) < 0.01, "Reset should restore the initial camera")
        }

        testRunner("ThreeMFView initializes with custom camera and accepts mouse events") {
            let view = ThreeMFView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            assert(!view.allowsCameraControl, "allowsCameraControl should be false to use custom zoom/rotate/pan")
            assert(view.pointOfView != nil, "pointOfView should be configured")
            assert(view.isGridVisible == true, "Grid should be visible by default")
            assert(view.isWireframe == false, "Wireframe should be false by default")

            view.toggleGrid()
            assert(view.isGridVisible == false, "toggleGrid should flip grid visibility")

            view.toggleWireframe()
            assert(view.isWireframe == true, "toggleWireframe should flip wireframe state")
        }

        testRunner("ModelSceneBuilder builds structured ground grid with floor, minor, major, center and border") {
            let grid = ModelSceneBuilder.buildGroundGrid(dimensions: SCNVector3(140, 80, 70), isDark: true)
            assert(grid.name == "GroundGrid", "Root name should be GroundGrid")

            let floorNode = grid.childNode(withName: "GridFloor", recursively: true)
            assert(floorNode != nil, "GridFloor node must exist")
            let floorMat = floorNode?.geometry?.material(named: "GridFloorMat")
            assert(floorMat != nil, "GridFloorMat must exist")

            let minorNode = grid.childNode(withName: "GridMinorLines", recursively: true)
            assert(minorNode != nil, "GridMinorLines node must exist")

            let majorNode = grid.childNode(withName: "GridMajorLines", recursively: true)
            assert(majorNode != nil, "GridMajorLines node must exist")

            let centerNode = grid.childNode(withName: "GridCenterLines", recursively: true)
            assert(centerNode != nil, "GridCenterLines node must exist")

            let borderNode = grid.childNode(withName: "GridBorder", recursively: true)
            assert(borderNode != nil, "GridBorder node must exist")

            // Test updating appearance to light mode
            ModelSceneBuilder.updateGridAppearance(in: grid, isDark: false)
            let lightMinorMat = minorNode?.geometry?.material(named: "GridMinorMat")
            assert(lightMinorMat?.diffuse.contents != nil, "Material should have diffuse contents after appearance update")

            // Test updating appearance back to dark mode
            ModelSceneBuilder.updateGridAppearance(in: grid, isDark: true)
            let darkMinorMat = minorNode?.geometry?.material(named: "GridMinorMat")
            assert(darkMinorMat?.diffuse.contents != nil, "Material should have diffuse contents after appearance update")
        }

        testRunner("Application bundle resources contain valid AppIcon.png and AppIcon.icns") {
            let iconPng = URL(fileURLWithPath: "Resources/AppIcon.png")
            let iconIcns = URL(fileURLWithPath: "Resources/AppIcon.icns")
            assert(FileManager.default.fileExists(atPath: iconPng.path), "Resources/AppIcon.png should exist")
            assert(FileManager.default.fileExists(atPath: iconIcns.path), "Resources/AppIcon.icns should exist")

            let pngData = try? Data(contentsOf: iconPng)
            assert(pngData != nil && pngData!.count > 1000, "AppIcon.png should contain image data")

            let icnsData = try? Data(contentsOf: iconIcns)
            assert(icnsData != nil && icnsData!.count > 1000, "AppIcon.icns should contain icon data")
        }
    }
}
