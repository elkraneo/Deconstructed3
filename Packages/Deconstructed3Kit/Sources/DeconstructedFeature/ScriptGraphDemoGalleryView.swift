import RCP3Document
import SwiftUI

/// A product-facing browser for composed Script Graph demos. It deliberately uses
/// the same `ScriptGraphExample` values as the toolbar and Project Browser, so a
/// card never drifts from the graph that is actually loaded or serialized.
struct ScriptGraphDemoGalleryView: View {
    let demos: [ScriptGraphExample]
    let onOpen: (ScriptGraphExample) -> Void
    let onCreateAsset: (ScriptGraphExample) -> Void

    @Environment(\.dismiss) private var dismiss

    private let columns = [
        GridItem(.adaptive(minimum: 280, maximum: 380), spacing: 16, alignment: .top)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    introduction
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        ForEach(demos) { demo in
                            DemoCard(
                                demo: demo,
                                onOpen: { onOpen(demo) },
                                onCreateAsset: { onCreateAsset(demo) }
                            )
                        }
                    }
                }
                .padding(24)
            }
            .navigationTitle("Functional Script Graph Demos")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .frame(minWidth: 720, idealWidth: 980, minHeight: 560, idealHeight: 680)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Programs, not isolated nodes")
                .font(.title2.weight(.semibold))
            Text("Each demo composes events, persistent state, data flow, control flow, and visible transform feedback. Open one immediately, or create a real project asset that can be edited and assigned to an entity.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: 760, alignment: .leading)
        }
    }
}

private struct DemoCard: View {
    let demo: ScriptGraphExample
    let onOpen: () -> Void
    let onCreateAsset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Label(demo.name, systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.headline)
                Spacer(minLength: 8)
                Text("\(demo.graph.nodes.count) nodes")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(demo.summary)
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("EXPECTED RESULT")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                Text(demo.certification.expectedOutcome)
                    .font(.callout)
            }

            Text(demo.certification.capabilities.joined(separator: "  •  "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer(minLength: 0)

            HStack {
                Button("Open in Canvas", systemImage: "arrow.right.circle", action: onOpen)
                    .buttonStyle(.borderedProminent)
                Button("Create Asset", systemImage: "doc.badge.plus", action: onCreateAsset)
                    .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.quaternary, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
}
