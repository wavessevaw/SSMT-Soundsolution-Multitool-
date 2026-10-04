import AppKit
import SwiftUI

/// One column of `EditableRows`: fixed width, or flexible (fills the rest) when `width` is nil.
struct RowColumn: Identifiable {
    var title: String
    var width: CGFloat?
    var minWidth: CGFloat = 60
    var id: String { title }
}

/// Editable rows without NSTableView. SwiftUI's `Table` keeps AppKit cell views for rows that the document has
/// already dropped, and with text fields and pickers in the cells that crashed when rows were deleted or the
/// whole list was replaced (Delete, New patch, Undo). Here every row is a plain view keyed by its id, so a row
/// that disappears simply is not drawn any more.
///
/// Selection: click selects one row, ⌘-click toggles, ⇧-click selects a range. Delete removes the selection
/// while the rows (not a text field) have the keyboard.
struct EditableRows<Row: Identifiable, Cells: View>: View where Row.ID: Hashable {
    let columns: [RowColumn]
    let rows: [Row]
    @Binding var selection: Set<Row.ID>
    var visibleRows: ClosedRange<Int>
    var onDelete: () -> Void
    let cells: (Row) -> Cells

    @FocusState private var focused: Bool
    @State private var anchor: Row.ID?

    static var rowHeight: CGFloat { 28 }

    init(columns: [RowColumn], rows: [Row], selection: Binding<Set<Row.ID>>, visibleRows: ClosedRange<Int>,
         onDelete: @escaping () -> Void, @ViewBuilder cells: @escaping (Row) -> Cells) {
        self.columns = columns
        self.rows = rows
        _selection = selection
        self.visibleRows = visibleRows
        self.onDelete = onDelete
        self.cells = cells
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(columns) { c in
                    Text(c.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .rowCell(c)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            Divider()
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        line(row)
                    }
                }
            }
            .frame(height: CGFloat(min(max(rows.count, visibleRows.lowerBound), visibleRows.upperBound)) * Self.rowHeight)
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.18)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .focusable()
        .focused($focused)
        .onDeleteCommand {
            guard !isTypingText(), !selection.isEmpty else { return }
            onDelete()
        }
        .onChange(of: rows.map(\.id)) { ids in
            // Rows that are gone (deleted, new patch, undo) leave the selection too.
            let alive = Set(ids)
            if !selection.isSubset(of: alive) { selection.formIntersection(alive) }
            if let a = anchor, !alive.contains(a) { anchor = nil }
        }
    }

    private func line(_ row: Row) -> some View {
        let selected = selection.contains(row.id)
        return HStack(spacing: 8) { cells(row) }
            .padding(.horizontal, 8)
            .frame(height: Self.rowHeight)
            .background {
                // Clicking the row itself (not a field in it) gives the rows the keyboard, so Delete works.
                Rectangle().fill(selected ? Theme.accent.opacity(0.18) : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { focused = true }
            }
            .simultaneousGesture(TapGesture().onEnded { select(row.id) })
    }

    private func select(_ id: Row.ID) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
        } else if mods.contains(.shift), let a = anchor,
                  let i = rows.firstIndex(where: { $0.id == a }), let j = rows.firstIndex(where: { $0.id == id }) {
            selection = Set(rows[min(i, j)...max(i, j)].map(\.id))
        } else {
            selection = [id]
            anchor = id
        }
    }
}

extension View {
    /// Sizes a header or row cell to its column.
    func rowCell(_ c: RowColumn) -> some View {
        Group {
            if let w = c.width {
                self.frame(width: w, alignment: .leading)
            } else {
                self.frame(minWidth: c.minWidth, maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
