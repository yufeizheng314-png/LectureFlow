import Foundation

// Portable companions to the rendered PNG/PDF notes. Markdown tables keep
// numeric data editable; diagram edges remain readable without a renderer.
enum LFVisualTextExport {
    static func render(_ blocks: [LFVisualBlock], format: LFExportFormat) -> String {
        guard !blocks.isEmpty else { return "" }
        let markdown = format == .markdown
        func readable(_ value: LFKeyTerm) -> String { markdown ? cell(pair(value)) : pair(value) }
        var result = "\(markdown ? "## " : "")图文笔记 / Visual notes\n\n"
        for block in blocks {
            result += "\(markdown ? "### " : "")\(readable(block.title))\n\n\(readable(block.caption))\n\n"
            if let table = block.table {
                result += grid(headers: table.columns.map(pair), rows: table.rows.map { $0.map(pair) }, markdown: markdown)
            }
            if let diagram = block.diagram {
                let labels = Dictionary(uniqueKeysWithValues: diagram.nodes.map { ($0.id, readable($0.label)) })
                // Use generated identifiers, never source text as Mermaid syntax.
                if markdown {
                    let ids = Dictionary(uniqueKeysWithValues: diagram.nodes.enumerated().map { ($0.element.id, "n\($0.offset)") })
                    result += "```mermaid\nflowchart TD\n"
                    for node in diagram.nodes {
                        result += "  \(ids[node.id]!)[\"\(mermaid(pair(node.label)))\"]\n"
                    }
                    for edge in diagram.edges {
                        guard let from = ids[edge.from], let to = ids[edge.to] else { continue }
                        let label = edge.label.map { "|\"\(mermaid(pair($0)))\"|" } ?? ""
                        result += "  \(from) -->\(label) \(to)\n"
                    }
                    result += "```\n\n"
                }
                for edge in diagram.edges {
                    let link = edge.label.map { " — \(readable($0)) —→ " } ?? " → "
                    result += "- \(labels[edge.from] ?? edge.from)\(link)\(labels[edge.to] ?? edge.to)\n"
                }
                let connected = Set(diagram.edges.flatMap { [$0.from, $0.to] })
                for node in diagram.nodes where !connected.contains(node.id) { result += "- \(readable(node.label))\n" }
                result += "\n"
            }
            if let chart = block.chart {
                result += "X: \(readable(chart.xLabel))\nY: \(readable(chart.yLabel))\n\n"
                var rows: [[String]] = []
                for series in chart.series {
                    for point in series.points {
                        rows.append([pair(series.label), point.label.map(pair) ?? "", String(point.x), String(point.y)])
                    }
                }
                result += grid(headers: ["系列 / Series", "标签 / Label", "X", "Y"], rows: rows, markdown: markdown)
            }
            if let formula = block.formula {
                // A dynamically longer fence preserves formulas containing ticks.
                let longest = formula.expression.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
                let fence = String(repeating: "`", count: max(3, longest + 1))
                result += markdown ? "\(fence)text\n\(formula.expression)\n\(fence)\n\n" : "\(formula.expression)\n\n"
                result += grid(headers: ["符号 / Symbol", "含义 / Meaning"],
                               rows: formula.symbols.map { [$0.symbol, pair($0.meaning)] }, markdown: markdown)
                for (index, step) in formula.steps.enumerated() { result += "\(index + 1). \(readable(step))\n" }
                result += "\n"
            }
            result += "来源 / Sources: \(block.sourceSegmentIDs.map { markdown ? cell($0) : $0 }.joined(separator: ", "))\n\n"
        }
        return result
    }

    private static func pair(_ text: LFKeyTerm) -> String { "\(text.english) / \(text.chinese)" }

    private static func grid(headers: [String], rows: [[String]], markdown: Bool) -> String {
        if markdown {
            let heading = "| " + headers.map(cell).joined(separator: " | ") + " |\n"
            let separator = "| " + headers.map { _ in "---" }.joined(separator: " | ") + " |\n"
            return heading + separator + rows.map { "| " + $0.map(cell).joined(separator: " | ") + " |" }.joined(separator: "\n") + "\n\n"
        }
        return headers.joined(separator: "\t") + "\n" + rows.map { $0.map { $0.components(separatedBy: .newlines).joined(separator: " ") }.joined(separator: "\t") }.joined(separator: "\n") + "\n\n"
    }

    private static func cell(_ text: String) -> String {
        let escaped: [Character: String] = ["&": "&amp;", "<": "&lt;", ">": "&gt;", "|": "&#124;",
            "`": "&#96;", "\\": "&#92;", "*": "&#42;", "_": "&#95;", "[": "&#91;", "]": "&#93;",
            "#": "&#35;", "!": "&#33;", "\n": "<br>", "\r": "<br>"]
        return text.replacingOccurrences(of: "\r\n", with: "\n").map { escaped[$0] ?? String($0) }.joined()
    }

    private static func mermaid(_ text: String) -> String {
        text.replacingOccurrences(of: "#", with: "#35;").replacingOccurrences(of: "&", with: "#38;")
            .replacingOccurrences(of: "\"", with: "#quot;").replacingOccurrences(of: "<", with: "#60;")
            .replacingOccurrences(of: ">", with: "#62;").replacingOccurrences(of: "|", with: "#124;")
            .replacingOccurrences(of: "`", with: "#96;").components(separatedBy: .newlines).joined(separator: " ")
    }
}
