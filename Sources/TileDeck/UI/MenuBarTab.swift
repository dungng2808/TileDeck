import SwiftUI
import UniformTypeIdentifiers

struct MenuBarTab: View {
    @ObservedObject private var manager = MenuBarManager.shared
    @State private var dropTarget: String?

    var body: some View {
        VStack(spacing: 10) {
            Card {
                FeatureHeader(
                    icon: "menubar.rectangle",
                    title: "Sắp xếp & ẩn icon thanh menu",
                    subtitle: "Icon bên trái vạch ⏽ được gom lại, bấm ‹ trên thanh menu để hiện/ẩn",
                    isOn: Binding(get: { manager.isEnabled }, set: { manager.setEnabled($0) }),
                    tint: .blue
                )
                if manager.isEnabled {
                    AlertRow(icon: "timer", tint: .orange, title: "Tự ẩn lại sau 15 giây",
                             isOn: Binding(get: { manager.autoCollapse }, set: { manager.setAutoCollapse($0) }))
                }
            }

            if manager.isEnabled {
                Card {
                    HStack {
                        Text("Icon trên thanh menu").font(.system(size: 11.5, weight: .semibold))
                        if manager.isMoving {
                            ProgressView().controlSize(.mini)
                        }
                        Spacer()
                        Button {
                            manager.refresh()
                        } label: {
                            Label("Quét lại", systemImage: "arrow.clockwise").font(.system(size: 10, weight: .medium))
                        }
                        .controlSize(.small)
                    }
                    Label("Kéo ≡ để đổi thứ tự (trên xuống = trái sang phải). Kéo vào nhóm khác để ẩn/hiện.",
                          systemImage: "hand.draw")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // Same order as the menu bar: hidden icons sit left of the separator.
                    section("Đang ẩn", id: "hidden", items: manager.items.filter(\.isHidden))
                    section("Đang hiện", id: "shown", items: manager.items.filter { !$0.isHidden })
                }
            }
        }
        .onAppear { if manager.isEnabled { manager.beginEditing() } }
        .onDisappear { manager.endEditing() }
        .onChange(of: manager.isEnabled) { _, enabled in if enabled { manager.beginEditing() } }
    }

    private func section(_ title: String, id: String, items: [MenuBarManager.Item]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title) (\(items.count))")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(dropTarget == id ? Color.accentColor : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                .onDrop(of: [.text], delegate: MenuBarDrop(targetID: id, dropTarget: $dropTarget) { item in
                    id == "hidden" ? manager.hide(item) : manager.show(item)
                })
            if items.isEmpty {
                Text("Kéo icon vào đây").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.vertical, 4)
            }
            ForEach(items) { item in
                MenuBarRow(item: item, isDropTarget: dropTarget == "\(item.id)")
                    .onDrag {
                        NSItemProvider(object: "\(item.id)" as NSString)
                    } preview: {
                        MenuBarRow(item: item, isDropTarget: false).frame(width: 300)
                    }
                    .onDrop(of: [.text], delegate: MenuBarDrop(targetID: "\(item.id)", dropTarget: $dropTarget) { dragged in
                        manager.place(dragged, at: item)
                    })
            }
        }
    }
}

/// Reads the dragged icon's window number and hands the matching item to `perform`.
private struct MenuBarDrop: DropDelegate {
    let targetID: String
    @Binding var dropTarget: String?
    let perform: @MainActor (MenuBarManager.Item) -> Void

    func dropEntered(info: DropInfo) { dropTarget = targetID }
    func dropExited(info: DropInfo) { if dropTarget == targetID { dropTarget = nil } }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dropTarget = nil
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        let perform = perform
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String, let id = CGWindowID(text) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let item = MenuBarManager.shared.items.first(where: { $0.id == id }) else { return }
                    perform(item)
                }
            }
        }
        return true
    }
}

private struct MenuBarRow: View {
    let item: MenuBarManager.Item
    let isDropTarget: Bool
    @ObservedObject private var manager = MenuBarManager.shared

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(item.isMovable ? Color.secondary : Color.clear)
                .frame(width: 12)
            icon.frame(width: 18, height: 18)
            Text(item.name).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            if item.isMovable {
                Button {
                    item.isHidden ? manager.show(item) : manager.hide(item)
                } label: {
                    Image(systemName: item.isHidden ? "eye.slash" : "eye")
                        .foregroundStyle(item.isHidden ? Color.secondary : Color.accentColor)
                        .frame(width: 22, height: 18)
                }
                .buttonStyle(.borderless)
                .help(item.isHidden ? "Hiện icon này" : "Ẩn icon này")
                .disabled(manager.isMoving)
            } else {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .frame(width: 22)
                    .help("Icon này giữ ⌘ rồi kéo bằng tay trên thanh menu")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(isDropTarget ? Color.accentColor : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var icon: some View {
        if let symbol = item.symbol {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary.opacity(0.8))
                .frame(width: 18, height: 18)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
        } else if let image = NSRunningApplication(processIdentifier: item.pid)?.icon {
            Image(nsImage: image).resizable()
        } else {
            Image(systemName: "app.dashed").foregroundStyle(.secondary)
        }
    }
}
