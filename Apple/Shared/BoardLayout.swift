import ProxyGaugeCore
import ProxyGaugeSession
import SwiftUI

enum BoardStyle {
    static let cornerRadius: CGFloat = 12
    static let spacing: CGFloat = 12
    static let tileMinWidth: CGFloat = 280
    static let compactTileMinWidth: CGFloat = 210
    static let accountCardMinWidth: CGFloat = 300
    #if os(macOS)
    static let providerCardMinWidth: CGFloat = 340
    #else
    static let providerCardMinWidth: CGFloat = tileMinWidth
    #endif
    static let accountCardMaxWidth: CGFloat = 440
    static let providersForCompactTiles = 4

    static var cardBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemGroupedBackground)
        #endif
    }

    static var pageBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemGroupedBackground)
        #endif
    }
}

struct BoardCard: ViewModifier {
    var inset: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .padding(inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(BoardStyle.cardBackground, in: .rect(cornerRadius: BoardStyle.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: BoardStyle.cornerRadius)
                    .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
            }
    }
}

extension View {
    func boardCard(inset: CGFloat = 12) -> some View {
        modifier(BoardCard(inset: inset))
    }
}

struct EqualHeightGrid: Layout {
    var minItemWidth: CGFloat
    var maxItemWidth: CGFloat?
    var maxColumns: Int?
    var spacing: CGFloat = BoardStyle.spacing

    private func columns(for width: CGFloat, count: Int) -> Int {
        guard width.isFinite, width > 0 else { return 1 }
        let fitting = min(Int((width + spacing) / (minItemWidth + spacing)), maxColumns ?? .max)
        return max(1, maxItemWidth == nil ? min(count, fitting) : fitting)
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> (itemWidth: CGFloat, heights: [CGFloat], columns: Int) {
        let columns = columns(for: width, count: subviews.count)
        let fitted = width.isFinite ? (width - spacing * CGFloat(columns - 1)) / CGFloat(columns) : minItemWidth
        let fillsRow = columns == 1 || columns == maxColumns
        let itemWidth = fillsRow ? fitted : min(fitted, maxItemWidth ?? fitted)
        let heights = stride(from: 0, to: subviews.count, by: columns).map { start in
            subviews[start..<min(start + columns, subviews.count)]
                .map { $0.sizeThatFits(ProposedViewSize(width: itemWidth, height: nil)).height }
                .max() ?? 0
        }
        return (itemWidth, heights, columns)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width ?? minItemWidth
        let layout = rows(subviews, width: width)
        let height = layout.heights.reduce(0, +) + spacing * CGFloat(max(0, layout.heights.count - 1))
        return CGSize(width: width.isFinite ? width : layout.itemWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = rows(subviews, width: bounds.width)
        var y = bounds.minY
        for (row, height) in layout.heights.enumerated() {
            for column in 0..<layout.columns {
                let index = row * layout.columns + column
                guard index < subviews.count else { break }
                let x = bounds.minX + CGFloat(column) * (layout.itemWidth + spacing)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: layout.itemWidth, height: height))
            }
            y += height + spacing
        }
    }
}
