import SwiftUI
import UIKit

extension LFVisualKind {
    var displayName: String {
        switch self {
        case .table: return "对照表"
        case .flow: return "流程图"
        case .causal: return "因果关系图"
        case .bar: return "柱状图"
        case .line: return "折线图"
        case .scatter: return "散点图"
        case .formula: return "公式与步骤"
        }
    }
    var symbol: String {
        switch self {
        case .table: return "tablecells"
        case .flow: return "arrow.triangle.branch"
        case .causal: return "point.3.connected.trianglepath.dotted"
        case .bar: return "chart.bar.fill"
        case .line: return "chart.xyaxis.line"
        case .scatter: return "chart.dots.scatter"
        case .formula: return "function"
        }
    }
}

struct LFVisualNotesCard: View {
    let block: LFVisualBlock
    let sourceDescription: String
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Label(block.kind.displayName, systemImage: block.kind.symbol)
                    .font(.caption.bold()).foregroundStyle(.blue)
                Spacer()
                Button("全屏", action: open)
                    .accessibilityIdentifier("lectureflow.visual.fullscreen.\(block.id)")
            }
            Text(block.title.chinese).font(.headline)
            Text(block.title.english).font(.caption).foregroundStyle(.secondary)
            LFVisualIllustration(block: block, sourceDescription: sourceDescription, maximumPixels: 900_000)
                .frame(maxHeight: 290).clipped()
            if !block.caption.chinese.isEmpty { Text(block.caption.chinese).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct LFVisualIllustration: View {
    let block: LFVisualBlock
    let sourceDescription: String
    var maximumPixels: CGFloat = 4_000_000
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .accessibilityLabel("\(block.kind.displayName)：\(block.title.chinese)，\(block.title.english)")
                    .accessibilityIdentifier("lectureflow.visual.image.\(block.id)")
            } else { ProgressView("绘制图文笔记…") }
        }
        .task(id: block) { image = LFVisualRenderer.image(for: block, sourceDescription: sourceDescription, maximumPixels: maximumPixels) }
    }
}

struct LFVisualNotesGallery: View {
    @ObservedObject var model: LectureFlowModel
    let blocks: [LFVisualBlock]
    let initialID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID = ""
    @State private var zoom: CGFloat = 1
    @State private var showingData = false
    @State private var document: LFVisualShareDocument?
    private var selected: LFVisualBlock? { blocks.first { $0.id == selectedID } ?? blocks.first }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack {
                    Picker("图表", selection: $selectedID) {
                        ForEach(blocks) { block in Text(block.title.chinese).tag(block.id) }
                    }.pickerStyle(.menu).accessibilityIdentifier("lectureflow.visual.picker")
                    Spacer()
                    Button { zoom = max(0.65, zoom - 0.25) } label: { Image(systemName: "minus.magnifyingglass") }
                        .accessibilityLabel("缩小图表")
                    Text("\(Int((zoom * 100).rounded()))%")
                        .font(.caption.monospacedDigit()).accessibilityIdentifier("lectureflow.visual.zoom")
                    Button { zoom = min(2.5, zoom + 0.25) } label: { Image(systemName: "plus.magnifyingglass") }
                        .accessibilityLabel("放大图表")
                    Button("适合屏幕") { zoom = 1 }
                }.padding(.horizontal)
                if let selected {
                    GeometryReader { geometry in
                        ScrollView([.horizontal, .vertical]) {
                            LFVisualIllustration(block: selected, sourceDescription: LFVisualRenderer.sources(selected, segments: model.lesson?.segments ?? []))
                                .frame(width: max(320, geometry.size.width - 32) * zoom)
                                .padding(16)
                        }
                        .background(Color(uiColor: .systemGray6))
                    }
                    HStack {
                        Label(selected.kind.displayName, systemImage: selected.kind.symbol)
                        Spacer()
                        Button("完整数据") { showingData = true }
                            .accessibilityIdentifier("lectureflow.visual.details")
                        Button("分享 PNG", systemImage: "photo") { Task { await model.exportVisual(selected) } }
                            .accessibilityIdentifier("lectureflow.visual.export.png")
                        Button("整课 PDF", systemImage: "doc.richtext") { Task { await model.exportPDF() } }
                            .accessibilityIdentifier("lectureflow.visual.export.pdf")
                    }.padding(.horizontal)
                    if let name = model.lastExportName {
                        Text("已导出：\(name)").font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("lectureflow.export.filename")
                    }
                }
            }.padding(.vertical, 12)
                .navigationTitle("课堂图文笔记")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .onAppear { selectedID = initialID ?? blocks.first?.id ?? "" }
        .onChange(of: selectedID) { _, _ in zoom = 1 }
        .onChange(of: model.exportURL) { _, url in
            if let url { document = LFVisualShareDocument(url: url) }
        }
        .sheet(item: $document, onDismiss: { model.exportURL = nil }) { LFVisualShareSheet(url: $0.url) }
        .sheet(isPresented: $showingData) {
            if let selected {
                NavigationStack {
                    ScrollView { LFVisualDataView(block: selected, sourceDescription: LFVisualRenderer.sources(selected, segments: model.lesson?.segments ?? [])).padding(24) }
                        .navigationTitle("完整图文数据").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingData = false } } }
                }.presentationDetents([.large])
            }
        }
        .alert("导出未完成", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("知道了") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
}

private struct LFVisualShareDocument: Identifiable { let id = UUID(); let url: URL }
private struct LFVisualShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.view.accessibilityIdentifier = "lectureflow.share.sheet"
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct LFVisualDataView: View {
    let block: LFVisualBlock
    let sourceDescription: String
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            pair(block.title, font: .title2)
            pair(block.caption)
            if let table = block.table {
                ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                    VStack(alignment: .leading, spacing: 10) {
                        Text("第 \(index + 1) 行").font(.headline)
                        ForEach(Array(row.enumerated()), id: \.offset) { column, value in
                            if column < table.columns.count { pair(table.columns[column], font: .caption) }
                            pair(value)
                        }
                    }.padding().background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            if let diagram = block.diagram {
                ForEach(Array(diagram.nodes.enumerated()), id: \.offset) { index, node in
                    Text("\(index + 1)").font(.headline); pair(node.label)
                }
                Divider()
                ForEach(Array(diagram.edges.enumerated()), id: \.offset) { _, edge in
                    let from = diagram.nodes.first { $0.id == edge.from }?.label
                    let to = diagram.nodes.first { $0.id == edge.to }?.label
                    if let from, let to {
                        Text("\(from.chinese) → \(to.chinese)").font(.headline)
                        Text("\(from.english) → \(to.english)")
                    }
                    if let label = edge.label { pair(label) }
                }
            }
            if let chart = block.chart {
                Text("X 轴 / X axis").font(.headline); pair(chart.xLabel)
                Text("Y 轴 / Y axis").font(.headline); pair(chart.yLabel)
                ForEach(chart.series) { series in
                    pair(series.label, font: .headline)
                    ForEach(Array(series.points.enumerated()), id: \.offset) { _, point in
                        HStack(alignment: .top) {
                            Text("x = \(LFVisualRenderer.value(point.x)), y = \(LFVisualRenderer.value(point.y))")
                                .font(.body.monospacedDigit())
                            if let label = point.label { pair(label) }
                        }
                    }
                }
            }
            if let formula = block.formula {
                Text(formula.expression).font(.title2.monospaced()).textSelection(.enabled)
                ForEach(Array(formula.symbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol.symbol).font(.headline.monospaced()); pair(symbol.meaning)
                }
                ForEach(Array(formula.steps.enumerated()), id: \.offset) { index, step in
                    Text("\(index + 1).").font(.headline); pair(step)
                }
            }
            if !sourceDescription.isEmpty {
                Text(sourceDescription).font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
    }
    private func pair(_ value: LFKeyTerm, font: Font = .body) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(value.chinese); Text(value.english).foregroundStyle(.secondary) }.font(font)
    }
}

/// The same deterministic drawing is used in the app, PNG sharing and PDF.
/// Text is measured before layout; diagrams never invent edges or chart values.
@MainActor
enum LFVisualRenderer {
    private static let ink = UIColor(red: 0.10, green: 0.16, blue: 0.26, alpha: 1)
    private static let colors: [UIColor] = [UIColor(red: 0.10, green: 0.36, blue: 0.82, alpha: 1),
        UIColor(red: 0.02, green: 0.51, blue: 0.45, alpha: 1), UIColor(red: 0.72, green: 0.25, blue: 0.16, alpha: 1)]
    private static let width: CGFloat = 1080
    private static let margin: CGFloat = 38
    private static var contentWidth: CGFloat { width - margin * 2 }

    static func sources(_ block: LFVisualBlock, segments: [LFConfirmedSegment]) -> String {
        let times = block.sourceSegmentIDs.compactMap { id in segments.first { $0.id == id }?.startTime }
            .filter { $0.isFinite && $0 >= 0 && $0 < Double(Int.max) }.sorted()
        let labels = times.map { value -> String in
            let seconds = max(0, Int(value))
            return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
        return labels.isEmpty ? "" : "课堂来源 / Lecture sources: " + labels.joined(separator: " · ")
    }

    static func number(_ value: Double) -> String {
        if value == 0 { return "0" }
        if abs(value) >= 1_000_000 || abs(value) < 0.001 { return String(format: "%.3g", value) }
        return String(format: "%.4g", value)
    }
    static func value(_ number: Double) -> String {
        let encoded = String(number)
        return encoded.hasSuffix(".0") ? String(encoded.dropLast(2)) : encoded
    }
    private static func bilingual(_ value: LFKeyTerm) -> String { value.chinese + "\n" + value.english }
    private static func attributes(_ size: CGFloat, bold: Bool = false, color: UIColor = ink) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4
        paragraph.lineBreakMode = .byWordWrapping
        return [.font: UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular), .foregroundColor: color, .paragraphStyle: paragraph]
    }
    private static func height(_ text: String, width: CGFloat, size: CGFloat = 21, bold: Bool = false) -> CGFloat {
        ceil((text as NSString).boundingRect(with: CGSize(width: max(1, width), height: 100_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes(size, bold: bold), context: nil).height) + 2
    }
    @discardableResult private static func text(_ value: String, x: CGFloat = margin, y: CGFloat, width: CGFloat = contentWidth,
                                              size: CGFloat = 21, bold: Bool = false, color: UIColor = ink, draw: Bool) -> CGFloat {
        let h = height(value, width: width, size: size, bold: bold)
        if draw { (value as NSString).draw(in: CGRect(x: x, y: y, width: width, height: h), withAttributes: attributes(size, bold: bold, color: color)) }
        return h
    }

    static func image(for block: LFVisualBlock, sourceDescription: String = "", maximumPixels: CGFloat = 8_000_000) -> UIImage {
        guard (try? LFVisualBlock.validateBlocks([block])) != nil else {
            return UIGraphicsImageRenderer(size: CGSize(width: 600, height: 100)).image { context in
                UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 600, height: 100))
                _ = text("图文内容格式不完整，请更新课程笔记。", x: 20, y: 24, width: 560, draw: true)
            }
        }
        let measured = layout(block, sourceDescription: sourceDescription, draw: false)
        let format = UIGraphicsImageRendererFormat()
        // Six card previews are small; the gallery and exports render one block
        // at a time. Bound the backing pixels even for maximum-length tables.
        format.scale = min(1.5, sqrt(maximumPixels / (width * measured)))
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: measured), format: format)
        return renderer.image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: width, height: measured))
            _ = layout(block, sourceDescription: sourceDescription, draw: true)
        }
    }

    private static func layout(_ block: LFVisualBlock, sourceDescription: String, draw: Bool) -> CGFloat {
        var y: CGFloat = 30
        y += text("LECTUREFLOW  /  \(block.kind.displayName)", y: y, size: 16, bold: true, color: colors[0], draw: draw) + 15
        y += text(bilingual(block.title), y: y, size: 29, bold: true, draw: draw) + 20
        switch block.kind {
        case .table: if let table = block.table { y = drawTable(table, y: y, draw: draw) }
        case .flow, .causal: if let diagram = block.diagram { y = drawDiagram(diagram, y: y, draw: draw) }
        case .bar, .line, .scatter: if let chart = block.chart { y = drawChart(chart, kind: block.kind, y: y, draw: draw) }
        case .formula: if let formula = block.formula { y = drawFormula(formula, y: y, draw: draw) }
        }
        if !block.caption.english.isEmpty || !block.caption.chinese.isEmpty {
            y += 24
            y += text(bilingual(block.caption), y: y, size: 19, color: .darkGray, draw: draw)
        }
        if !sourceDescription.isEmpty {
            y += 18
            y += text(sourceDescription, y: y, size: 15, color: .gray, draw: draw)
        }
        return y + 30
    }

    private static func drawTable(_ table: LFVisualTable, y start: CGFloat, draw: Bool) -> CGFloat {
        guard !table.columns.isEmpty else { return start }
        let cellWidth = contentWidth / CGFloat(table.columns.count)
        var y = start
        for (rowIndex, row) in ([table.columns] + table.rows).enumerated() {
            let rowHeight = max(72, row.map { height(bilingual($0), width: cellWidth - 24, size: 20, bold: rowIndex == 0) }.max() ?? 0) + 24
            for column in table.columns.indices {
                let rect = CGRect(x: margin + CGFloat(column) * cellWidth, y: y, width: cellWidth, height: rowHeight)
                if draw {
                    (rowIndex == 0 ? colors[0] : UIColor(red: 0.94, green: 0.97, blue: 1, alpha: rowIndex % 2 == 0 ? 0.8 : 0.35)).setFill()
                    UIBezierPath(rect: rect).fill()
                    UIColor(white: 0.83, alpha: 1).setStroke(); let border = UIBezierPath(rect: rect); border.lineWidth = 0.7; border.stroke()
                }
                if column < row.count {
                    _ = text(bilingual(row[column]), x: rect.minX + 12, y: y + 12, width: cellWidth - 24,
                             size: 20, bold: rowIndex == 0, color: rowIndex == 0 ? .white : ink, draw: draw)
                }
            }
            y += rowHeight
        }
        return y
    }

    private static func drawDiagram(_ diagram: LFVisualDiagram, y start: CGFloat, draw: Bool) -> CGFloat {
        guard !diagram.nodes.isEmpty else { return start }
        // Topological ranks keep prerequisite/effect arrows readable. Cycles are
        // placed in a final row and remain explicit in the numbered edge key.
        var ranks: [String: Int] = [:]
        var remaining = Set(diagram.nodes.map(\.id))
        for _ in diagram.nodes.indices {
            let ready = diagram.nodes.filter { node in
                remaining.contains(node.id) && diagram.edges.filter { $0.to == node.id }.allSatisfy { ranks[$0.from] != nil }
            }
            if ready.isEmpty { break }
            for node in ready {
                ranks[node.id] = (diagram.edges.filter { $0.to == node.id }.compactMap { ranks[$0.from] }.max().map { $0 + 1 }) ?? 0
                remaining.remove(node.id)
            }
        }
        let cycleRank = (ranks.values.max() ?? -1) + 1
        for id in remaining { ranks[id] = cycleRank }
        var rectangles: [String: CGRect] = [:]
        var y = start + 48
        let gap: CGFloat = 32
        for rank in 0...(ranks.values.max() ?? 0) {
            let nodes = diagram.nodes.filter { ranks[$0.id] == rank }
            for offset in stride(from: 0, to: nodes.count, by: 3) {
                let chunk = Array(nodes[offset..<min(offset + 3, nodes.count)])
                let boxWidth = (contentWidth - 120 - CGFloat(chunk.count - 1) * gap) / CGFloat(chunk.count)
                let boxHeight = max(100, chunk.map { height(bilingual($0.label), width: boxWidth - 32, size: 20, bold: true) }.max() ?? 0) + 30
                for (column, node) in chunk.enumerated() {
                    rectangles[node.id] = CGRect(x: margin + 60 + CGFloat(column) * (boxWidth + gap), y: y, width: boxWidth, height: boxHeight)
                }
                y += boxHeight + 76
            }
        }
        if draw {
            for (index, edge) in diagram.edges.enumerated() {
                guard let a = rectangles[edge.from], let b = rectangles[edge.to] else { continue }
                let startPoint = CGPoint(x: a.midX, y: a.maxY)
                let endPoint = CGPoint(x: b.midX, y: b.minY)
                let color = colors[index % colors.count].withAlphaComponent(0.7)
                color.setStroke()
                let path = UIBezierPath(); path.move(to: startPoint)
                let adjacent = b.minY > a.maxY && b.minY - a.maxY <= 80
                var labelCenter: CGPoint
                if adjacent {
                    let middleY = (startPoint.y + endPoint.y) / 2
                    path.addCurve(to: endPoint, controlPoint1: CGPoint(x: startPoint.x, y: middleY), controlPoint2: CGPoint(x: endPoint.x, y: middleY))
                    labelCenter = CGPoint(x: (startPoint.x + endPoint.x) / 2, y: middleY)
                } else {
                    // Skip-level, feedback and same-row arrows travel through
                    // an outside rail, never through an unrelated node.
                    let lane = CGFloat((index / 2) % 7) * 6
                    let railX = index % 2 == 0 ? margin + 8 + lane : width - margin - 8 - lane
                    let departY = a.maxY + 22 + CGFloat(index % 3) * 12
                    let approachY = b.minY - 22 - CGFloat(index % 3) * 10
                    path.addLine(to: CGPoint(x: startPoint.x, y: departY))
                    path.addLine(to: CGPoint(x: railX, y: departY))
                    path.addLine(to: CGPoint(x: railX, y: approachY))
                    path.addLine(to: CGPoint(x: endPoint.x, y: approachY))
                    path.addLine(to: endPoint)
                    labelCenter = CGPoint(x: railX, y: (departY + approachY) / 2)
                }
                path.lineWidth = 3; path.stroke()
                let arrow = UIBezierPath(); arrow.move(to: endPoint)
                arrow.addLine(to: CGPoint(x: endPoint.x - 6, y: endPoint.y - 12)); arrow.addLine(to: CGPoint(x: endPoint.x + 6, y: endPoint.y - 12)); arrow.close()
                color.setFill(); arrow.fill()
                let label = CGRect(x: labelCenter.x - 14, y: labelCenter.y - 14, width: 28, height: 28)
                UIColor.white.setFill(); UIBezierPath(ovalIn: label).fill()
                _ = text("\(index + 1)", x: label.minX + 5, y: label.minY + 2, width: 28, size: 17, bold: true, color: colors[index % colors.count], draw: true)
            }
            for (index, node) in diagram.nodes.enumerated() {
                guard let rect = rectangles[node.id] else { continue }
                let color = colors[index % colors.count]
                color.withAlphaComponent(0.08).setFill(); let card = UIBezierPath(roundedRect: rect, cornerRadius: 15); card.fill()
                color.setStroke(); card.lineWidth = 1.5; card.stroke()
                _ = text(bilingual(node.label), x: rect.minX + 16, y: rect.minY + 15, width: rect.width - 32, size: 20, bold: true, color: ink, draw: true)
            }
        }
        y -= 40
        if !diagram.edges.isEmpty { y += text("关系索引 / Connections", y: y, size: 20, bold: true, draw: draw) + 12 }
        for (index, edge) in diagram.edges.enumerated() {
            guard let from = diagram.nodes.first(where: { $0.id == edge.from }), let to = diagram.nodes.first(where: { $0.id == edge.to }) else { continue }
            var detail = "\(index + 1). \(from.label.chinese) → \(to.label.chinese)\n\(from.label.english) → \(to.label.english)"
            if let label = edge.label { detail += "\n" + bilingual(label) }
            y += text(detail, y: y, size: 19, draw: draw) + 14
        }
        return y
    }

    private static func domain(_ values: [Double], includeZero: Bool) -> ClosedRange<Double> {
        let finite = values.filter(\.isFinite)
        var low = finite.min() ?? 0; var high = finite.max() ?? 1
        if includeZero { low = min(0, low); high = max(0, high) }
        if low == high { let delta = max(abs(low) * 0.1, 1); low -= delta; high += delta }
        let padding = (high - low) * 0.08
        return (low - padding)...(high + padding)
    }

    private static func drawChart(_ chart: LFVisualChart, kind: LFVisualKind, y start: CGFloat, draw: Bool) -> CGFloat {
        let points = chart.series.flatMap(\.points).filter { $0.x.isFinite && $0.y.isFinite }
        let xs = Array(Set(points.map(\.x))).sorted()
        let xr = domain(points.map(\.x), includeZero: false)
        let yr = domain(points.map(\.y), includeZero: kind == .bar)
        var y = start
        y += text("Y · " + bilingual(chart.yLabel), y: y, size: 20, bold: true, draw: draw) + 12
        let plot = CGRect(x: margin + 94, y: y + 12, width: contentWidth - 114, height: 420)
        func xPosition(_ value: Double) -> CGFloat {
            if kind == .bar {
                let index = xs.firstIndex(of: value) ?? 0
                return plot.minX + (CGFloat(index) + 0.5) * plot.width / CGFloat(max(1, xs.count))
            }
            return plot.minX + CGFloat((value - xr.lowerBound) / (xr.upperBound - xr.lowerBound)) * plot.width
        }
        func yPosition(_ value: Double) -> CGFloat { plot.maxY - CGFloat((value - yr.lowerBound) / (yr.upperBound - yr.lowerBound)) * plot.height }
        if draw {
            for step in 0...4 {
                let value = yr.lowerBound + Double(step) / 4 * (yr.upperBound - yr.lowerBound)
                let position = yPosition(value)
                UIColor(white: 0.88, alpha: 1).setStroke(); let grid = UIBezierPath(); grid.move(to: CGPoint(x: plot.minX, y: position)); grid.addLine(to: CGPoint(x: plot.maxX, y: position)); grid.lineWidth = 1; grid.stroke()
                _ = text(number(value), x: margin, y: position - 12, width: 88, size: 18, draw: true)
            }
            ink.setStroke(); let axes = UIBezierPath(); axes.move(to: CGPoint(x: plot.minX, y: plot.minY)); axes.addLine(to: CGPoint(x: plot.minX, y: plot.maxY)); axes.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY)); axes.lineWidth = 2; axes.stroke()
            if yr.contains(0) {
                UIColor.gray.setStroke(); let zero = UIBezierPath(); zero.move(to: CGPoint(x: plot.minX, y: yPosition(0))); zero.addLine(to: CGPoint(x: plot.maxX, y: yPosition(0))); zero.lineWidth = 1.5; zero.stroke()
                _ = text("0", x: margin + 68, y: yPosition(0) - 10, width: 24, size: 16, bold: true, draw: true)
            }
            let ticks: [Double]
            if kind == .bar { let strideSize = max(1, Int(ceil(Double(xs.count) / 8))); ticks = xs.enumerated().filter { $0.offset % strideSize == 0 }.map(\.element) }
            else { ticks = (0...4).map { xr.lowerBound + Double($0) / 4 * (xr.upperBound - xr.lowerBound) } }
            for value in ticks { _ = text(number(value), x: xPosition(value) - 42, y: plot.maxY + 12, width: 84, size: 17, draw: true) }
            for (seriesIndex, series) in chart.series.enumerated() {
                let values = series.points.filter { $0.x.isFinite && $0.y.isFinite }.sorted { $0.x < $1.x }
                let color = colors[seriesIndex % colors.count]; color.setFill(); color.setStroke()
                if kind == .line, let first = values.first {
                    let path = UIBezierPath(); path.move(to: CGPoint(x: xPosition(first.x), y: yPosition(first.y)))
                    for point in values.dropFirst() { path.addLine(to: CGPoint(x: xPosition(point.x), y: yPosition(point.y))) }
                    path.lineWidth = 3; path.stroke()
                }
                for point in values {
                    let cx = xPosition(point.x), cy = yPosition(point.y)
                    if kind == .bar {
                        let groupWidth = plot.width / CGFloat(max(1, xs.count)) * 0.76
                        let barWidth = groupWidth / CGFloat(max(1, chart.series.count))
                        let x = cx - groupWidth / 2 + CGFloat(seriesIndex) * barWidth
                        let zero = yPosition(0)
                        let rect = CGRect(x: x, y: min(cy, zero), width: max(1, barWidth - 2), height: max(1.5, abs(cy - zero)))
                        UIBezierPath(rect: rect).fill()
                    } else {
                        UIBezierPath(ovalIn: CGRect(x: cx - 5, y: cy - 5, width: 10, height: 10)).fill()
                    }
                }
            }
        }
        y = plot.maxY + 50
        y += text("X · " + bilingual(chart.xLabel), y: y, size: 20, bold: true, draw: draw) + 18
        for (index, series) in chart.series.enumerated() {
            if draw { colors[index % colors.count].setFill(); UIBezierPath(roundedRect: CGRect(x: margin, y: y + 4, width: 20, height: 20), cornerRadius: 4).fill() }
            y += text(bilingual(series.label), x: margin + 32, y: y, width: contentWidth - 32, size: 20, bold: true, draw: draw) + 12
        }
        // Point labels never disappear into a clipped or overlapping chart axis.
        // Their exact values remain in the data key and the accessible data view.
        if points.contains(where: { $0.label != nil }) {
            y += text("数据标注 / Point labels", y: y, size: 20, bold: true, draw: draw) + 10
            for series in chart.series {
                for point in series.points {
                    guard let label = point.label else { continue }
                    y += text("\(series.label.chinese): (\(value(point.x)), \(value(point.y)))  " + bilingual(label), y: y, size: 18, draw: draw) + 8
                }
            }
        }
        return y
    }

    private static func drawFormula(_ formula: LFVisualFormula, y start: CGFloat, draw: Bool) -> CGFloat {
        var y = start
        let expressionHeight = height(formula.expression, width: contentWidth - 40, size: 32, bold: true) + 40
        if draw { colors[0].withAlphaComponent(0.07).setFill(); UIBezierPath(roundedRect: CGRect(x: margin, y: y, width: contentWidth, height: expressionHeight), cornerRadius: 18).fill() }
        _ = text(formula.expression, x: margin + 20, y: y + 20, width: contentWidth - 40, size: 32, bold: true, draw: draw)
        y += expressionHeight + 24
        for symbol in formula.symbols {
            y += text(symbol.symbol + "  ·  " + bilingual(symbol.meaning), y: y, size: 22, draw: draw) + 14
        }
        for (index, step) in formula.steps.enumerated() {
            y += text("\(index + 1).  " + bilingual(step), y: y, size: 22, bold: true, draw: draw) + 18
        }
        return y
    }
}
