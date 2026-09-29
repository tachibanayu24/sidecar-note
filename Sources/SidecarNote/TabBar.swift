import AppKit
import SwiftUI

struct TabBar: View {
    @ObservedObject var store: NoteStore
    var onClose: (Note) -> Void
    @Namespace private var selection

    // Safari-style reordering: the grabbed tab follows the pointer, the others slide out of its way.
    @State private var draggingID: UUID?
    // Reference types held in @State: mutating them doesn't re-render the bar. Tab frames arrive from
    // onGeometryChange during animations (as state they would feed back into endless animation), and the
    // pointer position only needs to re-render the lifted chip, which observes `drag` itself.
    @State private var layout = TabLayout()
    @State private var drag = DragModel()

    private static let spacing: CGFloat = 2

    var body: some View {
        let selectedID = store.selected?.id
        ZStack(alignment: .leading) {
            if store.notes.count > 1 {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        GlassEffectContainer(spacing: 12) {
                            HStack(spacing: TabBar.spacing) {
                                ForEach(store.notes) { note in
                                    chip(for: note, isSelected: note.id == selectedID)
                                }
                            }
                            .coordinateSpace(.named("tabs"))
                            // The grabbed tab is drawn here, detached from the row, so the row's animations
                            // can never move it: it simply follows the pointer.
                            .overlay(alignment: .topLeading) { liftedChip(selectedID: selectedID) }
                            .padding(.horizontal, 2)
                            .padding(.vertical, 4)
                            // Keyboard shortcuts change the selection too; the glass morph follows every change.
                            .animation(.bouncy(duration: 0.38, extraBounce: 0.04), value: store.selectedID)
                        }
                    }
                    .scrollClipDisabled()
                    .onChange(of: store.selectedID) { _, id in
                        withAnimation(.snappy) { proxy.scrollTo(id) }
                    }
                }
                .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .animation(.snappy(duration: 0.3), value: store.notes.count > 1)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(WindowDragArea())
        .environment(\.controlActiveState, .key)
    }

    private func chip(for note: Note, isSelected: Bool) -> some View {
        let isDragging = draggingID == note.id
        return TabChip(note: note, isSelected: isSelected && !isDragging, namespace: selection,
                       onSelect: { withAnimation(.bouncy(duration: 0.35)) { store.select(note) } },
                       onClose: { withAnimation(.snappy(duration: 0.25)) { onClose(note) } })
            .id(note.id)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("tabs")) } action: { layout.frames[note.id] = $0 }
            // While dragged, the in-row chip only reserves the slot the tab will land in.
            .opacity(isDragging ? 0 : 1)
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named("tabs"))
                    .onChanged { value in dragChanged(note, value) }
                    .onEnded { _ in dragEnded(note) }
            )
    }

    @ViewBuilder private func liftedChip(selectedID: UUID?) -> some View {
        if let id = draggingID, let note = store.notes.first(where: { $0.id == id }) {
            LiftedChip(model: drag) {
                TabChip(note: note, isSelected: id == selectedID, namespace: selection, onSelect: {}, onClose: {})
            }
        }
    }

    /// Left edge of the slot at `index` in the current order, computed from tab widths (not from animated
    /// frames), so it is exact the moment the order changes.
    private func slotMinX(of index: Int) -> CGFloat {
        store.notes.prefix(index).reduce(0) { $0 + (layout.frames[$1.id]?.width ?? 0) + TabBar.spacing }
    }

    private func dragChanged(_ note: Note, _ value: DragGesture.Value) {
        guard let from = store.notes.firstIndex(where: { $0.id == note.id }) else { return }
        if draggingID != note.id {
            drag.token += 1
            drag.grabX = value.startLocation.x - slotMinX(of: from)
            drag.pointerX = value.location.x
            draggingID = note.id
            withAnimation(.snappy(duration: 0.2)) { drag.lifted = true }
        }
        drag.pointerX = value.location.x

        // Where would the others' centres be with the dragged tab taken out of the row?
        let center = drag.pointerX - drag.grabX + (layout.frames[note.id]?.width ?? 0) / 2
        var x: CGFloat = 0
        var mids: [CGFloat] = []
        for other in store.notes where other.id != note.id {
            let w = layout.frames[other.id]?.width ?? 0
            mids.append(x + w / 2)
            x += w + TabBar.spacing
        }
        // A small dead zone around each boundary so the order can't flip back and forth.
        let hysteresis: CGFloat = 8
        let movingRight = mids.filter { $0 < center - hysteresis }.count
        let movingLeft = mids.filter { $0 < center + hysteresis }.count
        let to = movingRight > from ? movingRight : (movingLeft < from ? movingLeft : from)
        if to != from {
            withAnimation(.snappy(duration: 0.25)) { store.move(from: from, to: to) }
        }
    }

    private func dragEnded(_ note: Note) {
        guard let index = store.notes.firstIndex(where: { $0.id == note.id }) else {
            draggingID = nil
            return
        }
        // Glide into the slot, then hand the tab back to the row (unless another drag has started meanwhile).
        let token = drag.token
        withAnimation(.snappy(duration: 0.22)) {
            drag.pointerX = slotMinX(of: index) + drag.grabX
            drag.lifted = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            guard drag.token == token else { return }
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { draggingID = nil }
        }
        layout.frames = layout.frames.filter { id, _ in store.notes.contains { $0.id == id } }
    }
}

private final class TabLayout {
    var frames: [UUID: CGRect] = [:]
}

private final class DragModel: ObservableObject {
    @Published var pointerX: CGFloat = 0
    @Published var lifted = false
    var grabX: CGFloat = 0   // pointer x inside the tab when the drag began
    var token = 0            // identifies the current drag
}

private struct LiftedChip<Content: View>: View {
    @ObservedObject var model: DragModel
    @ViewBuilder var content: Content

    var body: some View {
        content
            .scaleEffect(model.lifted ? 1.06 : 1)
            .shadow(color: .black.opacity(model.lifted ? 0.22 : 0), radius: 10, y: 4)
            .offset(x: model.pointerX - model.grabX)
            .allowsHitTesting(false)
    }
}

/// Neumorphic lift: light from the top-left, soft shade to the bottom-right.
private struct RaisedShadow: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .shadow(color: .white.opacity(scheme == .dark ? 0.06 : 0.7), radius: 3, x: -2, y: -2)
            .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.18), radius: 4, x: 2, y: 3)
    }
}

private struct TabChip: View {
    @ObservedObject var note: Note
    let isSelected: Bool
    let namespace: Namespace.ID
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(note.title.isEmpty ? "Untitled" : note.title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .frame(maxWidth: 150, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            if hovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Circle())
                }
                .buttonStyle(HoverCircleStyle())
                .transition(.opacity.combined(with: .scale(scale: 0.5)))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, hovering ? 6 : 12)
        .frame(height: 28)
        .modifier(SelectionBackground(isSelected: isSelected, namespace: namespace))
        .contentShape(Capsule())
        .onTapGesture(perform: onSelect)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }
}

/// The selected tab sits on a raised Liquid Glass capsule that morphs from tab to tab.
private struct SelectionBackground: ViewModifier {
    let isSelected: Bool
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if isSelected {
            content
                .glassEffect(.regular.tint(Color.primary.opacity(0.1)), in: .capsule)
                .glassEffectID("selection", in: namespace)
                .modifier(RaisedShadow())
        } else {
            content
        }
    }
}

private struct HoverCircleStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.08 : 0)))
            .onHover { hovering = $0 }
    }
}

/// Lets the empty part of the tab bar drag the borderless window.
private struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { return }
            window?.performDrag(with: event)
        }
        override var mouseDownCanMoveWindow: Bool { true }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
