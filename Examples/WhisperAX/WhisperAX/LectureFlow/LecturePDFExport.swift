// LectureFlow additions. See LICENSE and LectureFlow/THIRD_PARTY_NOTICES.txt.
import CoreText
import Foundation
import UIKit

enum LecturePDFExport {
    static func write(text: String, title: String, to url: URL) throws {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let body = CGRect(x: 42, y: 48, width: 511, height: 736)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        style.paragraphSpacing = 7
        let document = NSAttributedString(string: text, attributes: [
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
        }
        guard !layoutFailed else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}
