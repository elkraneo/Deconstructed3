import SwiftUI
import SwiftFlow

/// The RCP-styled SwiftUI content for one script-graph node on the SwiftFlow
/// canvas. Pass it as the `FlowCanvas` node-content builder:
///
/// ```swift
/// FlowCanvas(store: store) { node, context in
///     ScriptGraphNodeView(node: node, context: context)
/// }
/// ```
///
/// It renders a card — a role-tinted header (icon + title, with the `tm_*` type as
/// a caption when an author label exists) over two columns of pin labels (inputs
/// leading, outputs trailing) — and overlays SwiftFlow's `FlowNodeHandles`, which
/// draws the actual connectable handles the node declared (so the labels line up
/// with real, wireable handles).
public struct ScriptGraphNodeView: View {
    public let node: FlowNode<ScriptGraphNodePayload>
    public let context: NodeRenderContext

    public init(node: FlowNode<ScriptGraphNodePayload>, context: NodeRenderContext) {
        self.node = node
        self.context = context
    }

    private var payload: ScriptGraphNodePayload { node.data }
    private static var handleInset: CGFloat { FlowHandle.diameter / 2 }

    public var body: some View {
        let inset = Self.handleInset
        ZStack {
            card
                .padding(inset)
            // SwiftFlow draws the connectable handles from `node.handles`.
            FlowNodeHandles(node: node, context: context)
        }
        .frame(width: node.size.width + inset * 2, height: node.size.height + inset * 2)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(payload.role.tint.opacity(0.25))
            pinRows
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            // Role accent bar down the leading edge.
            payload.role.tint
                .frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 1.5))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(borderColor, lineWidth: node.isSelected ? 2 : 1)
        }
        .shadow(color: .black.opacity(node.isSelected ? 0.18 : 0.08),
                radius: node.isSelected ? 8 : 2, y: 1)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: payload.role.symbol)
                .font(.caption)
                .foregroundStyle(payload.role.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(payload.title)
                    .font(.system(.subheadline, weight: .semibold))
                    .lineLimit(1)
                if payload.label != nil {
                    Text(payload.type)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pinRows: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(payload.inputPins) { pin in
                    pinLabel(pin, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 3) {
                ForEach(payload.outputPins) { pin in
                    pinLabel(pin, alignment: .trailing)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pinLabel(_ pin: ScriptGraphNodePayload.Pin, alignment: HorizontalAlignment) -> some View {
        HStack(spacing: 4) {
            if alignment == .leading { pinGlyph(pin) }
            Text(pin.label)
                .font(.caption2)
                .foregroundStyle(pin.isExec ? .primary : .secondary)
                .lineLimit(1)
            // Exposed literal value (e.g. "(Self)", "Transform"), as RCP shows it.
            if let value = pin.valueLabel {
                Text(value)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if alignment == .trailing { pinGlyph(pin) }
        }
    }

    @ViewBuilder
    private func pinGlyph(_ pin: ScriptGraphNodePayload.Pin) -> some View {
        if pin.isExec {
            Image(systemName: "arrowtriangle.right.fill")
                .font(.system(size: 7))
                .foregroundStyle(payload.role.tint)
        } else {
            Circle()
                .fill(payload.role.tint.opacity(0.6))
                .frame(width: 6, height: 6)
        }
    }

    private var borderColor: Color {
        if node.isSelected { return payload.role.tint }
        if node.isHovered { return Color.primary.opacity(0.25) }
        return Color.primary.opacity(0.12)
    }
}

#Preview("Script graph nodes") {
    // Sample payloads spanning a few roles so the styling is visible.
    let drag = ScriptGraphNodePayload(
        id: "n1", type: "tm_gesture_event_drag", label: nil, role: .event,
        pins: [
            .init(id: "exec.out", label: "exec", isInput: false, isExec: true),
            .init(id: "out.scene", label: "sceneTranslation", isInput: false, isExec: false),
        ]
    )
    let set = ScriptGraphNodePayload(
        id: "n2", type: "tm_set_component", label: "Set Transform", role: .action,
        pins: [
            .init(id: "exec.in", label: "exec", isInput: true, isExec: true),
            .init(id: "in.translation", label: "translation", isInput: true, isExec: false),
            .init(id: "in.component_type", label: "component_type", isInput: true, isExec: false),
        ]
    )
    return VStack(spacing: 24) {
        ForEach([drag, set], id: \.id) { payload in
            // Standalone card preview (without the FlowNode wrapper).
            ScriptGraphNodeCardPreview(payload: payload)
        }
    }
    .padding(40)
    .frame(width: 320)
}

/// A lightweight standalone card for previews (no SwiftFlow `FlowNode` needed).
private struct ScriptGraphNodeCardPreview: View {
    let payload: ScriptGraphNodePayload
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: payload.role.symbol).foregroundStyle(payload.role.tint)
                Text(payload.title).font(.subheadline.weight(.semibold))
                Spacer()
            }
            .padding(8)
            Divider()
            HStack(alignment: .top) {
                VStack(alignment: .leading) { ForEach(payload.inputPins) { Text($0.label).font(.caption2) } }
                Spacer()
                VStack(alignment: .trailing) { ForEach(payload.outputPins) { Text($0.label).font(.caption2) } }
            }
            .padding(8)
        }
        .frame(width: 220)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(payload.role.tint.opacity(0.4)) }
    }
}
