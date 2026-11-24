import AppKit
import QuickLookThumbnailing

@objc(ThumbnailProvider)
public class ThumbnailProvider: QLThumbnailProvider {
    public override func provideThumbnail(for request: QLFileThumbnailRequest,
                                          _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let url = request.fileURL
        let maxSize = request.maximumSize
        let scale = max(1, request.scale)

        // 1. Fast path: thumbnail image embedded by the slicer / authoring app.
        var image = ModelSnapshot.embeddedThumbnail(in: url)

        // 2. Fallback: render the actual geometry offscreen.
        if image == nil {
            do {
                let doc = try ThreeMFParser.load(from: url)
                let info = ModelSceneBuilder.build(from: doc)
                guard info.totalTriangles > 0 else { throw ThreeMFParserError.emptyDocument }
                let px = CGSize(width: maxSize.width * scale, height: maxSize.height * scale)
                image = ModelSnapshot.render(info, size: px)
            } catch {
                handler(nil, error)
                return
            }
        }

        guard let img = image, img.size.width > 0, img.size.height > 0 else {
            handler(nil, ThreeMFParserError.emptyDocument)
            return
        }

        // Aspect-fit the image into the requested maximum size.
        let aspect = img.size.width / img.size.height
        var ctxSize = maxSize
        if aspect >= 1 {
            ctxSize.height = (maxSize.width / aspect).rounded()
        } else {
            ctxSize.width = (maxSize.height * aspect).rounded()
        }
        ctxSize.width = max(1, ctxSize.width)
        ctxSize.height = max(1, ctxSize.height)

        let reply = QLThumbnailReply(contextSize: ctxSize, currentContextDrawing: { () -> Bool in
            img.draw(in: NSRect(origin: .zero, size: ctxSize), from: .zero, operation: .copy, fraction: 1.0)
            return true
        })
        handler(reply, nil)
    }
}
