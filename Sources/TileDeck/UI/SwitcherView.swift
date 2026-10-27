import SwiftUI

struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel
    let choose: (Int) -> Void

    private static let cardWidth: CGFloat = 190
    private static let maxColumns = 6

    var body: some View {
        let columns = Array(repeating: GridItem(.fixed(Self.cardWidth), spacing: 8), count: min(model.windows.count, Self.maxColumns))
        VStack(spacing: 10) {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Array(model.windows.enumerated()), id: \.element.id) { index, window in
                    Button {
                        choose(index)
                    } label: {
                        card(window, isSelected: index == model.selection)
                    }
                    .buttonStyle(CardPressStyle())
                    // The mouse picks a window just like Tab does, so the highlight always shows what a click will open.
                    .onHover { inside in
                        if inside { model.selection = index }
                    }
                }
            }
            selectionCaption
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.1)))
        .fixedSize()
    }

    /// The full name of what's selected, since card titles get truncated.
    @ViewBuilder
    private var selectionCaption: some View {
        if let window = model.selectedWindow {
            HStack(spacing: 6) {
                if let icon = window.icon {
                    Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                }
                Text(window.appName).font(.system(size: 12, weight: .bold))
                if window.title != window.appName {
                    Text("—").foregroundStyle(.secondary)
                    Text(window.title).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                }
                if window.isMinimized {
                    Text("Đã thu nhỏ").font(.system(size: 10, weight: .semibold)).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: CGFloat(min(model.windows.count, Self.maxColumns)) * (Self.cardWidth + 8))
        }
    }

    private func card(_ window: SwitcherWindow, isSelected: Bool) -> some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(0.06))
                if let preview = model.previews[window.id] {
                    Image(decorative: preview, scale: 2)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .padding(4)
                } else if let icon = window.icon {
                    Image(nsImage: icon).resizable().frame(width: 56, height: 56)
                }
                if window.isMinimized {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.yellow)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(6)
                }
            }
            .frame(height: 112)

            HStack(spacing: 5) {
                if let icon = window.icon {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                }
                Text(window.title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(7)
        .frame(width: Self.cardWidth)
        .background(isSelected ? Color.accentColor.opacity(0.28) : .clear, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2.5))
        .opacity(isSelected ? 1 : 0.8)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.08), value: isSelected)
    }
}

/// Shrinks the card while the mouse button is held, so a click visibly lands on it.
private struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
