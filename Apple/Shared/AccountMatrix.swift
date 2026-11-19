import ProxyGaugeCore
import SwiftUI

struct AccountMatrix: View {
    static let columnsBeforeScrolling = 5

    let overview: ProviderOverview
    @State private var rowHeights: [Int: [String: CGFloat]] = [:]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var labelWidth: CGFloat = 66
    @ScaledMetric(relativeTo: .caption) private var columnWidth: CGFloat = 60
    @ScaledMetric(relativeTo: .caption) private var totalWidth: CGFloat = 56

    private var windows: [PooledWindow] { overview.pool.windows }
    private var capacity: Double { Double(overview.pool.accounts) * 100 }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            AccountMatrixStack(overview: overview)
        } else {
            grid
        }
    }

    private var grid: some View {
        HStack(alignment: .top, spacing: 6) {
            labels
                .frame(width: labelWidth, alignment: .leading)
            accountColumns
            totals
                .frame(width: totalWidth, alignment: .trailing)
        }
        .onChange(of: overview.columns.map(\.id)) { _, ids in
            let kept = Set(ids + ["labels", "totals"])
            rowHeights = rowHeights.mapValues { $0.filter { kept.contains($0.key) } }
        }
        .onChange(of: windows.count) { _, count in
            rowHeights = rowHeights.filter { $0.key < count + 2 }
        }
    }

    @ViewBuilder
    private var accountColumns: some View {
        if overview.columns.count >= Self.columnsBeforeScrolling {
            scrollingColumns
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 4) {
                    ForEach(overview.columns) { column in
                        AccountMatrixColumn(column: column, overview: overview, rowHeights: $rowHeights)
                            .frame(minWidth: columnWidth, maxWidth: .infinity)
                    }
                }
                scrollingColumns
            }
        }
    }

    private var scrollingColumns: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 4) {
                ForEach(overview.columns) { column in
                    AccountMatrixColumn(column: column, overview: overview, rowHeights: $rowHeights)
                        .frame(width: columnWidth)
                }
            }
        }
        .scrollIndicators(.visible)
        .scrollIndicatorsFlash(onAppear: true)
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 0).matrixRow(0, cell: "labels", heights: $rowHeights)
            Color.clear.frame(height: 0).matrixRow(1, cell: "labels", heights: $rowHeights)
            ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                window.title
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .matrixRow(index + 2, cell: "labels", heights: $rowHeights, alignment: .leading)
            }
        }
        .accessibilityHidden(true)
    }

    private var totals: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text("Total")
                .font(.caption.weight(.semibold))
                .matrixRow(0, cell: "totals", heights: $rowHeights, alignment: .trailing)
            Text("of \(HeadroomStyle.percentText(capacity))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .matrixRow(1, cell: "totals", heights: $rowHeights, alignment: .trailing)
            ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                VStack(alignment: .trailing, spacing: 1) {
                    Text(verbatim: HeadroomStyle.percentText(overview.total(window.barID)))
                        .font(.callout.monospacedDigit().weight(.semibold))
                    if window.capacityPercent != capacity {
                        Text("of \(HeadroomStyle.percentText(window.capacityPercent))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .matrixRow(index + 2, cell: "totals", heights: $rowHeights, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: AccountMatrixWording.totalSentence(overview)))
    }
}

private struct AccountMatrixStack: View {
    let overview: ProviderOverview

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(overview.columns) { column in
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: column.name)
                        .font(.caption.weight(.semibold))
                    AccountStatusText(status: column.status)
                        .font(.caption2.weight(.medium))
                    ForEach(overview.pool.windows) { window in
                        let cell = column.cell(window.barID)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline) {
                                window.title
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 6)
                                AccountMatrixNumber(cell: cell, rounded: overview.roundedCells(window.barID)[column.id])
                            }
                            MiniRemainingBar(cell: cell)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(column.isBlocked ? Color.orange.opacity(0.12) : Color.clear, in: .rect(cornerRadius: 8))
                .opacity(column.status == .disabled ? 0.6 : 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: AccountMatrixWording.columnSentence(column, windows: overview.pool.windows)))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Total")
                    .font(.caption.weight(.semibold))
                ForEach(overview.pool.windows) { window in
                    HStack(alignment: .firstTextBaseline) {
                        window.title
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 6)
                        Text(verbatim: HeadroomStyle.percentText(overview.total(window.barID)))
                            .font(.callout.monospacedDigit().weight(.semibold))
                        Text("of \(HeadroomStyle.percentText(window.capacityPercent))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: AccountMatrixWording.totalSentence(overview)))
        }
    }
}

private enum AccountMatrixWording {
    static func totalSentence(_ overview: ProviderOverview) -> String {
        let parts = overview.pool.windows.map { window in
            String(localized: "\(window.label ?? String(localized: window.window.label)) \(HeadroomStyle.percentText(overview.total(window.barID))) of \(HeadroomStyle.percentText(window.capacityPercent))")
        }
        return String(localized: "Total: \(parts.joined(separator: ", "))")
    }

    static func columnSentence(_ column: AccountColumn, windows: [PooledWindow]) -> String {
        let cells = windows.map { window in
            let title = window.label ?? String(localized: window.window.label)
            guard let remaining = column.cell(window.barID).remainingPercent else {
                return String(localized: "\(title) no data")
            }
            return String(localized: "\(title) \(HeadroomStyle.percentText(remaining)) left")
        }
        return "\(column.label), \(statusString(column.status)): \(cells.joined(separator: ", "))"
    }

    static func statusString(_ status: AccountColumn.Status) -> String {
        switch status {
        case .usable: String(localized: "active")
        case .blocked(let until?): String(localized: "until \(ResetClock.string(until))")
        case .blocked: String(localized: "blocked")
        case .needsSignIn: String(localized: "sign in")
        case .reportsError: String(localized: "error")
        case .disabled: String(localized: "disabled")
        }
    }
}

private struct AccountStatusText: View {
    let status: AccountColumn.Status

    var body: some View {
        switch status {
        case .usable: Text("active").foregroundStyle(.green)
        case .blocked(let until?): Text("until \(ResetClock.text(until))").foregroundStyle(.orange)
        case .blocked: Text("blocked").foregroundStyle(.orange)
        case .needsSignIn: Text("sign in").foregroundStyle(.red)
        case .reportsError: Text("error").foregroundStyle(.red)
        case .disabled: Text("disabled").foregroundStyle(.secondary)
        }
    }
}

private struct AccountMatrixColumn: View {
    let column: AccountColumn
    let overview: ProviderOverview
    @Binding var rowHeights: [Int: [String: CGFloat]]

    var body: some View {
        VStack(spacing: 0) {
            Text(verbatim: column.name)
                .font(.caption.weight(.semibold))
                .multilineTextAlignment(.center)
                .help(Text(verbatim: column.label))
                .matrixRow(0, cell: column.id, heights: $rowHeights)
            AccountStatusText(status: column.status)
                .font(.caption2.weight(.medium))
                .multilineTextAlignment(.center)
                .matrixRow(1, cell: column.id, heights: $rowHeights)
            ForEach(Array(overview.pool.windows.enumerated()), id: \.element.id) { index, window in
                let cell = column.cell(window.barID)
                VStack(spacing: 3) {
                    AccountMatrixNumber(cell: cell, rounded: overview.roundedCells(window.barID)[column.id])
                    MiniRemainingBar(cell: cell)
                        .frame(maxWidth: 52)
                }
                .padding(.vertical, 4)
                .matrixRow(index + 2, cell: column.id, heights: $rowHeights)
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
        .background(column.isBlocked ? Color.orange.opacity(0.12) : Color.clear, in: .rect(cornerRadius: 8))
        .opacity(column.status == .disabled ? 0.6 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: AccountMatrixWording.columnSentence(column, windows: overview.pool.windows)))
    }
}

private struct AccountMatrixNumber: View {
    let cell: AccountCell
    let rounded: Int?

    var body: some View {
        Text(verbatim: rounded?.formatted() ?? "–")
            .font(.callout.monospacedDigit().weight(.semibold))
            .foregroundStyle(cell.isBlocked || cell.remainingPercent == nil ? .secondary : .primary)
    }
}

private struct MiniRemainingBar: View {
    let cell: AccountCell

    var body: some View {
        GeometryReader { proxy in
            let fraction = min(1, max(0, (cell.remainingPercent ?? 0) / 100))
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                if fraction > 0 {
                    Group {
                        if cell.isBlocked {
                            BlockedStripes(color: .orange)
                        } else {
                            Rectangle().fill(HeadroomStyle.color(forRemaining: cell.remainingPercent).gradient)
                        }
                    }
                    .frame(width: max(4, proxy.size.width * fraction))
                    .clipShape(.capsule)
                }
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

private struct MatrixRow: ViewModifier {
    let row: Int
    let cell: String
    @Binding var heights: [Int: [String: CGFloat]]
    var alignment: Alignment

    func body(content: Content) -> some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { height in
                if abs(height - (heights[row]?[cell] ?? 0)) > 0.5 { heights[row, default: [:]][cell] = height }
            })
            .frame(maxWidth: .infinity, minHeight: heights[row]?.values.max() ?? 0, alignment: alignment)
    }
}

private extension View {
    func matrixRow(_ row: Int, cell: String, heights: Binding<[Int: [String: CGFloat]]>, alignment: Alignment = .center) -> some View {
        modifier(MatrixRow(row: row, cell: cell, heights: heights, alignment: alignment))
    }
}
