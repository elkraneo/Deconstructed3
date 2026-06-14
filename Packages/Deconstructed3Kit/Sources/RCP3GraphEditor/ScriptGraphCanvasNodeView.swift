import SwiftUI

// MARK: - SwiftUI Canvas node card
//
// The visual for one script-graph node, laid out to *exactly* match
// `ScriptGraphLayout` so the port dots this view draws sit where
// `model.canvasPortPoint` says they are. The card frame is precisely
// `ScriptGraphLayout.size(payload)`; the canvas places it at the node's
// (zoom-scaled) top-left, and routes edges to the same port points — so what you
// see is what you can wire.
//
// This view is pure presentation: it draws a node and emits a "Delete"
// accessibility action. All interaction (drag, connect, select) is handled by the
// hosting `ScriptGraphCanvasView`, which sits a transparent gesture layer over the
// whole canvas; this card therefore does *not* install its own gestures (they
// would fight the canvas's port hit-testing).

struct ScriptGraphCanvasNodeView: View {
    let payload: ScriptGraphNodePayload
    let isSelected: Bool
    /// Invoked by the VoiceOver "Delete" action.
    let onDelete: () -> Void

    private var role: ScriptGraphNodeRole { payload.role }
    private var size: CGSize { ScriptGraphLayout.size(payload) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            card
            ports
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        // One accessibility element for the whole node.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityValue(Text(accessibilityValue))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: Text("Delete")) { onDelete() }
    }

    // MARK: Card body (header + rows)

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .frame(height: ScriptGraphLayout.headerHeight)
            Divider().overlay(role.tint.opacity(0.25))
            rows
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            // Role accent bar down the leading edge.
            role.tint
                .frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 1.5))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(borderColor, lineWidth: isSelected ? 2 : 1)
        }
        .shadow(
            color: .black.opacity(isSelected ? 0.22 : 0.08),
            radius: isSelected ? 9 : 2, y: 1
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: role.symbol)
                .font(.caption)
                .foregroundStyle(role.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(payload.title)
                    .font(.system(.subheadline, weight: .semibold))
                    .lineLimit(1)
                // Show the raw `tm_*` type as a caption only when an author label
                // is present (else the title already *is* the humanized type).
                if payload.label != nil {
                    Text(payload.type)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One fixed-height row per layout row. Each row hosts its input pin (leading)
    /// and/or output pin (trailing); the pin's label is anchored to the row's
    /// vertical center so it lines up with the port dot.
    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(0..<ScriptGraphLayout.rowCount(payload), id: \.self) { index in
                row(index)
                    .frame(height: ScriptGraphLayout.rowHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func row(_ index: Int) -> some View {
        let input = payload.inputPins[safe: index]
        let output = payload.outputPins[safe: index]
        return HStack(spacing: 6) {
            if let input {
                pinLabel(input, alignment: .leading)
            }
            Spacer(minLength: 4)
            if let output {
                pinLabel(output, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
    }

    private func pinLabel(
        _ pin: ScriptGraphNodePayload.Pin,
        alignment: HorizontalAlignment
    ) -> some View {
        HStack(spacing: 4) {
            Text(pin.label)
                .font(.caption2)
                .foregroundStyle(pin.isExec ? .primary : .secondary)
                .lineLimit(1)
            // Exposed literal value (e.g. "(Self)", "Transform") as RCP shows it.
            if let value = pin.valueLabel {
                Text(value)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(
            maxWidth: .infinity,
            alignment: alignment == .leading ? .leading : .trailing
        )
    }

    // MARK: Port dots
    //
    // Drawn at exactly `ScriptGraphLayout.portOffset(for:in:)` relative to the
    // card's top-left, so they coincide with `model.canvasPortPoint`. Inputs sit on
    // the left edge (x = 0), outputs on the right edge (x = width); we let the dot
    // straddle the edge. Exec pins read as filled triangles; data pins as circles.

    private var ports: some View {
        ZStack(alignment: .topLeading) {
            ForEach(payload.pins) { pin in
                if let offset = ScriptGraphLayout.portOffset(for: pin, in: payload) {
                    portDot(pin)
                        .position(x: offset.x, y: offset.y)
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        // Decorative — the node element already summarizes the pins.
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func portDot(_ pin: ScriptGraphNodePayload.Pin) -> some View {
        let r = ScriptGraphLayout.portRadius
        if pin.isExec {
            Image(systemName: "arrowtriangle.right.fill")
                .font(.system(size: r * 2.4))
                .foregroundStyle(role.tint)
                .background(
                    Circle().fill(.background).frame(width: r * 2.6, height: r * 2.6)
                )
        } else {
            Circle()
                .fill(role.tint)
                .frame(width: r * 2, height: r * 2)
                .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
        }
    }

    // MARK: Styling + accessibility text

    private var borderColor: Color {
        isSelected ? role.tint : Color.primary.opacity(0.14)
    }

    private var accessibilityLabel: String {
        "\(payload.title), \(role.displayName)"
    }

    private var accessibilityValue: String {
        let ins = payload.inputPins.count
        let outs = payload.outputPins.count
        func plural(_ n: Int, _ word: String) -> String {
            "\(n) \(word)\(n == 1 ? "" : "s")"
        }
        return "\(plural(ins, "input")), \(plural(outs, "output"))"
    }
}

extension Array {
    /// Bounds-checked subscript: `nil` instead of a trap when out of range.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
