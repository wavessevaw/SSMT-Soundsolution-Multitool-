import SSMTCore
import SwiftUI

/// Quick stage plan: a palette of equipment symbols, the stage with draggable items, and an
/// inspector for the selected item.
struct StagePlanEditor: View {
    @EnvironmentObject var store: InputListStore
    @EnvironmentObject var loc: Localizer
    @State private var dragging: StageItem.ID?
    @State private var dragTranslation: CGSize = .zero

    private var plan: StagePlan { store.doc.stage }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            palette
            HStack(alignment: .top, spacing: 16) {
                canvas
                    .frame(minHeight: 440)
                    .frame(maxWidth: .infinity)
                inspector
                    .frame(width: 250)
            }
            stageControls
        }
    }

    // MARK: Palette

    private var palette: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(StageItemKind.allCases, id: \.self) { kind in
                    Button { add(kind) } label: {
                        VStack(spacing: 4) {
                            StageSymbolIcon(kind: kind).frame(width: 38, height: 28)
                            Text(loc.t("stage.kind.\(kind.rawValue)")).font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                                .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.85)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(width: 78, height: 70)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(loc.t("stage.add.help"))
                }
            }
        }
    }

    private func add(_ kind: StageItemKind) {
        var id: StageItem.ID?
        store.edit(loc.t("stage.add.help")) { d in
            let label = kind == .text ? loc.t("stage.text.default") : ""
            id = d.stage.add(kind, label: label)
        }
        store.selectedItem = id
    }

    // MARK: Canvas

    private var canvas: some View {
        GeometryReader { geo in
            let shown = displayedPlan(in: geo.size)
            let g = StageGeometry(plan: shown, size: geo.size)
            ZStack {
                StagePlanDrawing(plan: shown, ink: .editor, audience: loc.t("stage.audience"), selected: store.selectedItem)
                    .contentShape(Rectangle())
                    .onTapGesture { store.selectedItem = nil }
                ForEach(shown.items) { item in
                    let r = g.rect(of: item)
                    Rectangle()
                        .fill(Color.white.opacity(0.001))
                        .frame(width: max(r.width, 16), height: max(r.height, 16))
                        .rotationEffect(.degrees(item.rotation))
                        .position(x: r.midX, y: r.midY)
                        .onTapGesture { store.selectedItem = item.id }
                        .gesture(
                            DragGesture(minimumDistance: 2)
                                .onChanged { v in
                                    store.selectedItem = item.id
                                    dragging = item.id
                                    dragTranslation = v.translation
                                }
                                .onEnded { v in commitDrag(id: item.id, translation: v.translation, size: geo.size) }
                        )
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous).fill(Color.black.opacity(0.2)))
        }
        .focusable()
        .onDeleteCommand { deleteSelected() }
        .onMoveCommand { dir in nudge(dir) }
    }

    /// The plan with the item being dragged shown at its live position (not yet snapped or saved).
    private func displayedPlan(in size: CGSize) -> StagePlan {
        guard let id = dragging, let i = plan.items.firstIndex(where: { $0.id == id }) else { return plan }
        var p = plan
        let g = StageGeometry(plan: plan, size: size)
        p.items[i].x += Double(dragTranslation.width / g.scale)
        p.items[i].y -= Double(dragTranslation.height / g.scale)
        return p
    }

    /// Drop: one undoable move, snapped to the grid and kept on stage.
    private func commitDrag(id: StageItem.ID, translation: CGSize, size: CGSize) {
        dragging = nil
        dragTranslation = .zero
        guard let item = plan.items.first(where: { $0.id == id }) else { return }
        let g = StageGeometry(plan: plan, size: size)
        let c = g.point(item.x, item.y)
        let target = g.stage(CGPoint(x: c.x + translation.width, y: c.y + translation.height))
        store.edit(loc.t("stage.move")) { $0.stage.move(id, to: target) }
    }

    private func deleteSelected() {
        guard let id = store.selectedItem else { return }
        store.edit(loc.t("action.delete")) { $0.stage.remove([id]) }
        store.selectedItem = nil
    }

    private func nudge(_ dir: MoveCommandDirection) {
        guard let id = store.selectedItem, let item = plan.items.first(where: { $0.id == id }) else { return }
        let step = plan.grid > 0 ? plan.grid : 0.1
        var p = (x: item.x, y: item.y)
        switch dir {
        case .left: p.x -= step
        case .right: p.x += step
        case .up: p.y += step
        case .down: p.y -= step
        @unknown default: break
        }
        store.edit(loc.t("stage.move")) { $0.stage.move(id, to: p) }
    }

    // MARK: Inspector

    @ViewBuilder private var inspector: some View {
        if let id = store.selectedItem, let i = plan.items.firstIndex(where: { $0.id == id }) {
            let item = plan.items[i]
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    StageSymbolIcon(kind: item.kind).frame(width: 34, height: 26)
                    Text(loc.t("stage.kind.\(item.kind.rawValue)")).font(.system(size: 14, weight: .semibold))
                }
                field(loc.t(item.kind == .text ? "stage.text" : "stage.label"), text: binding(i, \.label))
                if item.kind != .text {
                    field(loc.t("stage.info"), text: binding(i, \.info))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: loc.t("stage.rotation"), item.rotation)).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    HStack {
                        Slider(value: Binding(get: { item.rotation }, set: { v in store.edit { $0.stage.items[i].rotation = (v / 15).rounded() * 15 } }),
                               in: 0...345, step: 15)
                        Button { store.edit { $0.stage.rotate(id, by: 90) } } label: { Image(systemName: "rotate.right") }
                            .buttonStyle(.borderless).help("+90°")
                    }
                }
                if item.kind == .text {
                    Stepper(String(format: loc.t("stage.fontSize"), item.fontSize),
                            value: Binding(get: { item.fontSize }, set: { v in store.edit { $0.stage.items[i].fontSize = v } }), in: 8...48, step: 2)
                } else {
                    Stepper(String(format: loc.t("stage.width"), item.width),
                            value: Binding(get: { item.width }, set: { v in store.edit { $0.stage.items[i].width = v } }), in: 0.2...12, step: 0.1)
                    Stepper(String(format: loc.t("stage.depth"), item.depth),
                            value: Binding(get: { item.depth }, set: { v in store.edit { $0.stage.items[i].depth = v } }), in: 0.2...12, step: 0.1)
                }
                HStack(spacing: 8) {
                    iconButton("plus.square.on.square", loc.t("action.duplicate")) {
                        var newID: StageItem.ID?
                        store.edit { newID = $0.stage.duplicate(id) }
                        store.selectedItem = newID
                    }
                    iconButton("square.3.layers.3d.top.filled", loc.t("stage.front")) { store.edit { $0.stage.bringToFront(id) } }
                    iconButton("square.3.layers.3d.bottom.filled", loc.t("stage.back")) { store.edit { $0.stage.sendToBack(id) } }
                    Spacer()
                    iconButton("trash", loc.t("action.delete")) { deleteSelected() }
                }
            }
            .font(.system(size: 13))
            .glassCard(padding: 14)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "hand.point.up.left").font(.system(size: 20)).foregroundStyle(Theme.textMuted)
                Text(loc.t("stage.hint")).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(padding: 14)
        }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            TextField("", text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func iconButton(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon) }.buttonStyle(SSMTButtonStyle()).help(help)
    }

    private func binding(_ i: Int, _ key: WritableKeyPath<StageItem, String>) -> Binding<String> {
        Binding(get: { store.doc.stage.items.indices.contains(i) ? store.doc.stage.items[i][keyPath: key] : "" },
                set: { v in store.edit { if $0.stage.items.indices.contains(i) { $0.stage.items[i][keyPath: key] = v } } })
    }

    // MARK: Stage size

    private var stageControls: some View {
        HStack(spacing: 20) {
            Stepper(String(format: loc.t("stage.size.width"), plan.width),
                    value: Binding(get: { plan.width }, set: { v in store.edit { $0.stage.width = v; $0.stage.clampAll() } }), in: 2...40, step: 0.5)
            Stepper(String(format: loc.t("stage.size.depth"), plan.depth),
                    value: Binding(get: { plan.depth }, set: { v in store.edit { $0.stage.depth = v; $0.stage.clampAll() } }), in: 2...30, step: 0.5)
            Toggle(loc.t("stage.snap"), isOn: Binding(get: { plan.grid > 0 }, set: { v in store.edit { $0.stage.grid = v ? 0.25 : 0 } }))
            Spacer()
        }
        .font(.system(size: 13))
    }
}
