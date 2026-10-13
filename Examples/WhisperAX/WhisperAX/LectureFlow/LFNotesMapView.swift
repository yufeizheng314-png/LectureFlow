import SwiftUI
import UIKit

struct LFNotesMapView: View {
    let title: String
    let nodes: [LFConceptNode]
    var viewportHeight: CGFloat = 420
    @State private var zoom: CGFloat = 0.85
    @State private var selection: LFMapSelection?

    private let rootID = "lectureflow-map-root"
    private let palette: [Color] = [.blue, .teal, .purple, .orange, .indigo, .pink]

    var body: some View {
        let layout = LFMapLayout(nodes: nodes)
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Text("思维导图").font(.headline)
                    Spacer(minLength: 8)
                    Button { changeZoom(-0.2) } label: { Image(systemName: "minus.magnifyingglass") }
                        .disabled(zoom <= 0.45)
                        .accessibilityLabel("缩小导图")
                    Text("\(Int((zoom * 100).rounded()))%")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 36)
                    Button { changeZoom(0.2) } label: { Image(systemName: "plus.magnifyingglass") }
                        .disabled(zoom >= 1.65)
                        .accessibilityLabel("放大导图")
                    Button {
                        zoom = 0.85
                        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(rootID, anchor: .center) }
                    } label: { Image(systemName: "scope") }
                        .accessibilityLabel("回到课程中心")
                }
                .buttonStyle(.borderless)
                .font(.title3)

                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        Canvas { context, _ in
                            for edge in layout.edges {
                                var path = Path()
                                path.move(to: edge.start)
                                let middle = (edge.start.x + edge.end.x) / 2
                                path.addCurve(to: edge.end,
                                    control1: CGPoint(x: middle, y: edge.start.y),
                                    control2: CGPoint(x: middle, y: edge.end.y))
                                context.stroke(path, with: .color(palette[edge.branch % palette.count].opacity(0.5)),
                                               style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            }
                        }
                        .frame(width: layout.size.width, height: layout.size.height)

                        ForEach(layout.items) { item in
                            conceptCard(item)
                                .frame(width: LFMapLayout.cardWidth, height: LFMapLayout.cardHeight)
                                .position(item.center)
                        }

                        Button {
                            selection = LFMapSelection(id: rootID, english: title, chinese: "", isRoot: true)
                        } label: {
                            VStack(spacing: 7) {
                                Image(systemName: "book.closed.fill").font(.title3)
                                Text(title).font(.headline).lineLimit(3).multilineTextAlignment(.center)
                            }
                            .padding(14)
                            .frame(width: LFMapLayout.rootWidth, height: LFMapLayout.rootHeight)
                            .foregroundStyle(.white)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18))
                            .shadow(color: Color.accentColor.opacity(0.18), radius: 8, y: 3)
                        }
                        .buttonStyle(.plain)
                        .id(rootID)
                        .position(layout.rootCenter)
                        .accessibilityLabel("课程：\(title)")
                    }
                    .frame(width: layout.size.width, height: layout.size.height)
                    .scaleEffect(zoom, anchor: .topLeading)
                    .frame(width: layout.size.width * zoom, height: layout.size.height * zoom, alignment: .topLeading)
                }
                .frame(height: viewportHeight)
                .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.07), lineWidth: 1))
                .onAppear { proxy.scrollTo(rootID, anchor: .center) }

                Text("拖动查看分支 · 点击节点查看双语内容")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(item: $selection) { item in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(item.english).font(.title3).textSelection(.enabled)
                        if !item.chinese.isEmpty {
                            Divider()
                            Text(item.chinese).font(.title3).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(24)
                }
                .navigationTitle(item.isRoot ? "课程" : "双语节点")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { selection = nil } }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func changeZoom(_ amount: CGFloat) {
        zoom = min(1.65, max(0.45, zoom + amount))
    }

    private func conceptCard(_ item: LFMapItem) -> some View {
        let color = palette[item.branch % palette.count]
        return Button {
            selection = LFMapSelection(id: item.id, english: item.node.english, chinese: item.node.chinese, isRoot: false)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Circle().fill(color).frame(width: 5, height: 5)
                    Text(item.depth == 1 ? "主题" : "层级 \(item.depth)")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(color)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Text(item.node.english).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Text(item.node.chinese).font(.system(size: 13)).lineLimit(2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(color.opacity(0.45), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityLabel("\(item.node.english)，\(item.node.chinese)")
        .accessibilityHint("查看完整双语内容")
    }
}

private struct LFMapSelection: Identifiable {
    let id: String
    let english: String
    let chinese: String
    let isRoot: Bool
}

private struct LFMapItem: Identifiable {
    let id: String
    let node: LFConceptNode
    let center: CGPoint
    let depth: Int
    let branch: Int
}

private struct LFMapEdge {
    let start: CGPoint
    let end: CGPoint
    let branch: Int
}

private struct LFMapTree {
    let id: String
    let node: LFConceptNode
    let children: [LFMapTree]
    var depth: Int { 1 + (children.map(\.depth).max() ?? 0) }
    var height: CGFloat {
        guard !children.isEmpty else { return LFMapLayout.cardHeight }
        return max(LFMapLayout.cardHeight,
            children.reduce(0) { $0 + $1.height } + CGFloat(children.count - 1) * LFMapLayout.rowGap)
    }
}

private struct LFMapLayout {
    static let cardWidth: CGFloat = 196
    static let cardHeight: CGFloat = 112
    static let rootWidth: CGFloat = 220
    static let rootHeight: CGFloat = 120
    static let columnGap: CGFloat = 44
    static let rowGap: CGFloat = 18
    private static let margin: CGFloat = 30
    let size: CGSize
    let rootCenter: CGPoint
    var items: [LFMapItem] = []
    var edges: [LFMapEdge] = []

    init(nodes: [LFConceptNode]) {
        var budget = 40
        var branches: [(tree: LFMapTree, branch: Int, side: CGFloat)] = []
        var leftHeight: CGFloat = 0
        var rightHeight: CGFloat = 0
        for (index, node) in nodes.enumerated() {
            guard let tree = Self.boundedTree(node, id: "branch-\(index)", depth: 1, budget: &budget) else { break }
            let side: CGFloat = rightHeight <= leftHeight ? 1 : -1
            branches.append((tree, index, side))
            if side > 0 { rightHeight += tree.height + Self.rowGap }
            else { leftHeight += tree.height + Self.rowGap }
        }
        if leftHeight > 0 { leftHeight -= Self.rowGap }
        if rightHeight > 0 { rightHeight -= Self.rowGap }
        let leftDepth = branches.filter { $0.side < 0 }.map { $0.tree.depth }.max() ?? 0
        let rightDepth = branches.filter { $0.side > 0 }.map { $0.tree.depth }.max() ?? 0
        let step = Self.cardWidth + Self.columnGap
        size = CGSize(width: Self.rootWidth + CGFloat(leftDepth + rightDepth) * step + Self.margin * 2,
                      height: max(Self.rootHeight, max(leftHeight, rightHeight)) + Self.margin * 2)
        rootCenter = CGPoint(x: Self.margin + CGFloat(leftDepth) * step + Self.rootWidth / 2, y: size.height / 2)
        var leftTop = (size.height - leftHeight) / 2
        var rightTop = (size.height - rightHeight) / 2
        for branch in branches {
            let top = branch.side > 0 ? rightTop : leftTop
            place(branch.tree, depth: 1, branch: branch.branch, side: branch.side, top: top,
                  parentCenter: rootCenter, parentWidth: Self.rootWidth)
            if branch.side > 0 { rightTop += branch.tree.height + Self.rowGap }
            else { leftTop += branch.tree.height + Self.rowGap }
        }
    }

    private static func boundedTree(_ node: LFConceptNode, id: String, depth: Int, budget: inout Int) -> LFMapTree? {
        guard depth <= 4, budget > 0 else { return nil }
        budget -= 1
        var children: [LFMapTree] = []
        for (index, child) in node.children.enumerated() {
            if let tree = boundedTree(child, id: id + "/\(index)", depth: depth + 1, budget: &budget) {
                children.append(tree)
            }
            if budget == 0 { break }
        }
        return LFMapTree(id: id, node: node, children: children)
    }

    private mutating func place(_ tree: LFMapTree, depth: Int, branch: Int, side: CGFloat, top: CGFloat,
                                parentCenter: CGPoint, parentWidth: CGFloat) {
        let distance = Self.rootWidth / 2 + Self.columnGap + Self.cardWidth / 2
            + CGFloat(depth - 1) * (Self.cardWidth + Self.columnGap)
        let center = CGPoint(x: rootCenter.x + side * distance, y: top + tree.height / 2)
        items.append(LFMapItem(id: tree.id, node: tree.node, center: center, depth: depth, branch: branch))
        edges.append(LFMapEdge(start: CGPoint(x: parentCenter.x + side * parentWidth / 2, y: parentCenter.y),
                               end: CGPoint(x: center.x - side * Self.cardWidth / 2, y: center.y), branch: branch))
        var childTop = top
        for child in tree.children {
            place(child, depth: depth + 1, branch: branch, side: side, top: childTop,
                  parentCenter: center, parentWidth: Self.cardWidth)
            childTop += child.height + Self.rowGap
        }
    }
}
