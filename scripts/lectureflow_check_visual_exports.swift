// Run on the macOS CI runner against files exported by actual iPad UI tests.
import Foundation
import AppKit
import ImageIO
import PDFKit

guard CommandLine.arguments.count == 3 else {
    fatalError("usage: swift lectureflow_check_visual_exports.swift INPUT_DIRECTORY OUTPUT_DIRECTORY")
}
let input = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let fm = FileManager.default
try fm.createDirectory(at: output, withIntermediateDirectories: true)
let files = try fm.contentsOfDirectory(at: input, includingPropertiesForKeys: nil)
var reports: [[String: Any]] = []
var pngCount = 0
var pdfCount = 0
for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
    let ext = file.pathExtension.lowercased()
    guard ["png", "pdf", "md", "txt"].contains(ext) else { continue }
    let data = try Data(contentsOf: file)
    precondition(!data.isEmpty, "Empty export: \(file.lastPathComponent)")
    try data.write(to: output.appendingPathComponent(file.lastPathComponent), options: .atomic)
    if ext == "png" {
        precondition(data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]), "Invalid PNG signature")
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        precondition(image.width >= 500 && image.height >= 150, "PNG export unexpectedly small")
        pngCount += 1
        reports.append(["file": file.lastPathComponent, "kind": "png", "bytes": data.count,
                        "width": image.width, "height": image.height])
    } else if ext == "pdf" {
        let document = PDFDocument(data: data)!
        precondition(document.pageCount > 0 && document.pageCount <= 200, "Invalid PDF pagination")
        var pageSizes: [[Double]] = []
        for index in 0..<document.pageCount {
            let page = document.page(at: index)!
            let bounds = page.bounds(for: .mediaBox)
            precondition(bounds.width.isFinite && bounds.height.isFinite && bounds.width > 0 && bounds.height > 0)
            pageSizes.append([Double(bounds.width), Double(bounds.height)])
            // Render every page, so a malformed graphical page cannot hide
            // behind a successful text-only first page or file signature.
            let thumbnail = page.thumbnail(of: CGSize(width: 850, height: 1200), for: .mediaBox)
            var imageRect = CGRect(origin: .zero, size: thumbnail.size)
            let cgImage = thumbnail.cgImage(forProposedRect: &imageRect, context: nil, hints: nil)!
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            let rendered = bitmap.representation(using: .png, properties: [:])!
            let name = file.deletingPathExtension().lastPathComponent + "-page-\(index + 1).png"
            try rendered.write(to: output.appendingPathComponent(name))
        }
        pdfCount += 1
        reports.append(["file": file.lastPathComponent, "kind": "pdf", "bytes": data.count,
                        "pages": document.pageCount, "page_sizes": pageSizes,
                        "extractable_text_characters": document.string?.count ?? 0])
    }
}
precondition(pngCount >= 3, "UI tests must actually export table, scatter and bar PNG files")
precondition(pdfCount >= 2, "UI tests must actually export both course PDFs")
let result: [String: Any] = ["passed": true, "png_count": pngCount, "pdf_count": pdfCount, "files": reports]
try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("VISUAL-EXPORT-CHECKS.json"))
print("Visual export files decoded and every PDF page rendered: \(pngCount) PNG, \(pdfCount) PDF")
