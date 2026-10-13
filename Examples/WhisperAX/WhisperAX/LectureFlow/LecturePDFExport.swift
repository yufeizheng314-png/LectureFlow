// LectureFlow additions. See LICENSE and LectureFlow/THIRD_PARTY_NOTICES.txt.
import CoreText
import Foundation
import UIKit

@MainActor
enum LecturePDFExport {
    static func write(text: String, title: String, visuals: [LFVisualBlock] = [], segments: [LFConfirmedSegment] = [], to url: URL) throws {
        try LFVisualBlock.validateBlocks(visuals, allowedSourceIDs: segments.isEmpty ? nil : Set(segments.map(\.id)))
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let body = CGRect(x: 42, y: 48, width: 511, height: 736)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        style.paragraphSpacing = 7
        // CoreText can consume trailing line breaks on a separate, visually
        // empty page. Preserve indentation and internal spacing, trimming only
        // the end of the document before calculating visible string ranges.
        var content = text
        while let last = content.last, last.isWhitespace { content.removeLast() }
        let document = NSAttributedString(string: content, attributes: [
            .font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.black,
            .paragraphStyle: style,
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(document)
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: title, kCGPDFContextCreator as String: "LectureFlow"]
        var layoutFailed = false
        let renderer = UIGraphicsPDFRenderer(bounds: page, format: format)
        let data = renderer.pdfData { context in
            var position = 0
            var pageNumber = 0
            repeat {
                context.beginPage()
                pageNumber += 1
                let graphics = context.cgContext
                graphics.saveGState()
                // UIKit's footer drawing changes the text matrix, which is not
                // restored with the graphics state. Reset it on every page so
                // all CoreText pages have the same upright glyph orientation.
                graphics.textMatrix = .identity
                graphics.translateBy(x: 0, y: page.height)
                graphics.scaleBy(x: 1, y: -1)
                let path = CGPath(rect: body, transform: nil)
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: position, length: 0), path, nil)
                let visible = CTFrameGetVisibleStringRange(frame)
                guard visible.length > 0 || document.length == 0 else {
                    graphics.restoreGState()
                    layoutFailed = true
                    break
                }
                CTFrameDraw(frame, graphics)
                graphics.restoreGState()
                let footer = "LectureFlow · \(pageNumber)" as NSString
                footer.draw(at: CGPoint(x: 42, y: 811), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 9), .foregroundColor: UIColor.gray,
                ])
                position += visible.length
            } while position < document.length
            // Draw the exact same diagrams, tables, axes and legends used by
            // the app. Long blocks retain a readable width across continuation
            // pages instead of shrinking an entire long table onto one page.
            for block in visuals {
                autoreleasepool {
                    let image = LFVisualRenderer.image(for: block, sourceDescription: LFVisualRenderer.sources(block, segments: segments))
                    let scale = body.width / image.size.width
                    let scaledHeight = image.size.height * scale
                    let breaks = LFVisualRenderer.pageBreaks(for: block, sourceDescription: LFVisualRenderer.sources(block, segments: segments))
                        .map { min(scaledHeight, $0 * scale) } + [scaledHeight]
                    var offset: CGFloat = 0
                    let visualBody = CGRect(x: body.minX, y: 62, width: body.width, height: 716)
                    repeat {
                        let limit = min(scaledHeight, offset + visualBody.height)
                        // A complete row/paragraph stays together whenever it
                        // fits on a page. An unusually tall individual item is
                        // continued at the physical limit, never discarded.
                        let next = breaks.last(where: { $0 > offset + 1 && $0 <= limit }) ?? limit
                        let sliceHeight = next - offset
                        context.beginPage()
                        pageNumber += 1
                        let heading = offset == 0 ? "图文笔记 / Visual notes" : "图文笔记（续）/ Visual notes (continued)"
                        (heading as NSString).draw(at: CGPoint(x: body.minX, y: 32), withAttributes: [
                            .font: UIFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: UIColor.darkGray,
                        ])
                        let graphics = context.cgContext
                        graphics.saveGState()
                        graphics.clip(to: CGRect(x: visualBody.minX, y: visualBody.minY,
                                                  width: visualBody.width, height: sliceHeight))
                        image.draw(in: CGRect(x: visualBody.minX, y: visualBody.minY - offset, width: visualBody.width, height: scaledHeight))
                        graphics.restoreGState()
                        let footer = "LectureFlow · \(pageNumber)" as NSString
                        footer.draw(at: CGPoint(x: 42, y: 811), withAttributes: [
                            .font: UIFont.systemFont(ofSize: 9), .foregroundColor: UIColor.gray,
                        ])
                        offset = next
                    } while offset < scaledHeight
                }
            }
        }
        guard !layoutFailed else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}
