import SwiftUI

// How both apps show the connection, so the Mac and the iPhone look like one product.
// Compiled into the menu bar app (through BlePingCore) and the iPhone app (ios/project.yml
// points here), like Wire.swift.

public enum LinkState {
    /// Connected to the paired device.
    case connected
    /// Paired, but the other device isn't connected (yet), or Bluetooth is starting.
    case searching
    /// Bluetooth is off, denied or unavailable.
    case problem
    /// Nothing paired yet.
    case notPaired
    /// Pairing is in progress (shown on the Mac).
    case pairing

    public var symbol: String {
        switch self {
        case .connected: return "checkmark.circle.fill"
        case .searching: return "antenna.radiowaves.left.and.right"
        case .problem: return "exclamationmark.triangle.fill"
        case .notPaired: return "link.badge.plus"
        case .pairing: return "link"
        }
    }

    /// nil: the normal text colour.
    public var color: Color? {
        switch self {
        case .connected: return .green
        case .searching: return .orange
        case .problem: return .red
        case .notPaired: return nil
        case .pairing: return .blue
        }
    }
}

/// The status line used by both apps: the state's symbol and colour, then the title.
public struct LinkStateLabel: View {
    let state: LinkState
    let title: String
    let tintsTitle: Bool

    /// - Parameter tintsTitle: colour the words too, not just the symbol. The Mac keeps the
    ///   words in the normal text colour, since coloured text (green especially) is hard to read there.
    public init(_ title: String, state: LinkState, tintsTitle: Bool = true) {
        self.title = title
        self.state = state
        self.tintsTitle = tintsTitle
    }

    public var body: some View {
        Label {
            Text(title)
                .foregroundStyle(tintsTitle ? tint : AnyShapeStyle(.primary))
        } icon: {
            Image(systemName: state.symbol)
                .foregroundStyle(tint)
        }
    }

    private var tint: AnyShapeStyle {
        state.color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary)
    }
}
