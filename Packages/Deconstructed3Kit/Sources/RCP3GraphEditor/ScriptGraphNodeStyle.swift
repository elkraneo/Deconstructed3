import SwiftUI

/// Visual styling for a script-graph node's role — our own clean-room palette
/// (not derived from any external metadata). Keeps the *data* role
/// (`ScriptGraphNodeRole`, in the contract) free of UI types while giving the node
/// view a consistent tint + icon per category.
extension ScriptGraphNodeRole {
    /// The accent color for this role (header icon, accent bar, handle hint).
    var tint: Color {
        switch self {
        case .event: .orange
        case .action: .blue
        case .value: .green
        case .logic: .purple
        case .flow: .teal
        case .other: .gray
        }
    }

    /// An SF Symbol that reads as this role's category.
    var symbol: String {
        switch self {
        case .event: "bolt.fill"
        case .action: "square.and.arrow.down.fill"
        case .value: "number"
        case .logic: "function"
        case .flow: "arrow.triangle.branch"
        case .other: "circle"
        }
    }

    /// A short, human label for the category (used in legends/tooltips).
    var displayName: String {
        switch self {
        case .event: "Event"
        case .action: "Action"
        case .value: "Value"
        case .logic: "Logic"
        case .flow: "Flow"
        case .other: "Node"
        }
    }
}
