// Run on the macOS CI runner against files exported by actual iPad UI tests.
import Foundation
import AppKit
import ImageIO
import PDFKit
import CryptoKit

// Inspect rendered pixels, not extracted text: a PDF may contain searchable
// strings while its visible body is empty. The symmetric six-percent vertical
// inset excludes this exporter's header/footer and is independent of bitmap
// row orientation. It retains the text body and the graphical continuation area.
func bodyPixelEvidence(_ image: CGImage) -> [String: Any] {
    let width = image.width
    let height = image.height
    precondition(width >= 100 && height >= 100, "PDF raster unexpectedly small")
    let bytesPerRow = width * 4
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
    guard let context = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: colorSpace, bitmapInfo: bitmapInfo),
          let data = context.data else { fatalError("Cannot decode PDF raster pixels") }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    let rasterBounds = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
    context.fill(rasterBounds)
    context.draw(image, in: rasterBounds)
    let pixels = data.assumingMemoryBound(to: UInt8.self)
    let minX = Int(ceil(Double(width) * 0.05))
    let maxX = Int(floor(Double(width) * 0.95))
    let minY = Int(ceil(Double(height) * 0.06))
    let maxY = Int(floor(Double(height) * 0.94))
    var darkPixels = 0
    var sum = 0.0
    var squareSum = 0.0
    let count = (maxX - minX) * (maxY - minY)
    for y in minY..<maxY {
        for x in minX..<maxX {
            let offset = y * bytesPerRow + x * 4
            let gray = (Double(pixels[offset]) * 299 + Double(pixels[offset + 1]) * 587
                        + Double(pixels[offset + 2]) * 114) / 1000
            if gray < 245 { darkPixels += 1 }
            sum += gray
            squareSum += gray * gray
        }
    }
    let mean = sum / Double(count)
    let deviation = sqrt(max(0, squareSum / Double(count) - mean * mean))
    // A short final line can pass; a white body with only a footer cannot.
    // This is deliberately not a test of orientation, clipping or correctness.
    return ["body_nonblank": darkPixels >= 20 && deviation > 0.5,
            "body_pixels": count, "body_pixels_below_245": darkPixels,
            "body_grayscale_stddev": deviation,
            "body_normalized_crop": [0.05, 0.06, 0.95, 0.94]]
}

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
var longTableChecked = false
var longTablePDFChecked = false
let longTableDigest = SHA256.hash(data: Data("econ-long-table".utf8)).map { String(format: "%02x", $0) }.joined()
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
        if file.lastPathComponent.contains(longTableDigest) {
            precondition(image.height > image.width, "Stress table must render its complete long image")
            longTableChecked = true
        }
        reports.append(["file": file.lastPathComponent, "kind": "png", "bytes": data.count,
                        "width": image.width, "height": image.height])
    } else if ext == "pdf" {
        let document = PDFDocument(data: data)!
        precondition(document.pageCount > 0 && document.pageCount <= 200, "Invalid PDF pagination")
        var pageSizes: [[Double]] = []
        var pagePixelChecks: [[String: Any]] = []
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
            var evidence = bodyPixelEvidence(cgImage)
            evidence["page"] = index + 1
            pagePixelChecks.append(evidence)
            precondition(evidence["body_nonblank"] as? Bool == true,
                         "PDF has a blank rendered body (header/footer excluded): \(file.lastPathComponent), page \(index + 1), pixels \(evidence)")
        }
        pdfCount += 1
        if (document.string ?? "").contains("R12C6") {
            let continuations = (document.string ?? "").components(separatedBy: "Visual notes (continued)").count - 1
            precondition(continuations > 0, "Long table course must exercise graphical continuation pages")
            longTablePDFChecked = true
        }
        reports.append(["file": file.lastPathComponent, "kind": "pdf", "bytes": data.count,
                        "pages": document.pageCount, "page_sizes": pageSizes,
                        "page_pixel_checks": pagePixelChecks,
                        "extractable_text_characters": document.string?.count ?? 0])
    }
}
precondition(pngCount >= 4, "UI tests must actually export two independent tables, scatter and bar PNG files")
precondition(pdfCount >= 2, "UI tests must actually export both course PDFs")
precondition(longTableChecked && longTablePDFChecked, "Long table PNG and continued PDF must both be verified")
let result: [String: Any] = ["passed": true, "png_count": pngCount, "pdf_count": pdfCount,
    "long_table_png_and_continued_pdf": true, "files": reports]
try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("VISUAL-EXPORT-CHECKS.json"))
print("Visual export files decoded and every PDF page rendered: \(pngCount) PNG, \(pdfCount) PDF")
