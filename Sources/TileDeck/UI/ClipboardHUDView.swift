import SwiftUI

struct ClipboardHUDView: View {
    @ObservedObject var model: ClipboardHUDModel
    @ObservedObject private var store = ClipboardStore.shared
    let close: () -> Void

    @FocusState private var searchFocused: Bool

    var body: some View {
        let items = model.visible
        VStack(spacing: 0) {
            searchBar
            filterBar
            Divider().opacity(0.5)
            if items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard").font(.system(size: 26)).foregroundStyle(.tertiary)
                    Text(store.items.isEmpty ? "Chưa có gì trong lịch sử clipboard" : "Không tìm thấy mục nào")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                ClipboardRow(item: item, index: index, isSelected: index == model.selection, model: model)
                                    .id(item.id)
                                    .onTapGesture { ClipboardHUD.shared.paste(item) }
                                    .onHover { if $0 { model.selection = index } }
                            }
                        }
                        .padding(10)
                    }
                    .onChange(of: model.selection) { _, selection in
                        guard items.indices.contains(selection) else { return }
                        proxy.scrollTo(items[selection].id)
                    }
                }
            }
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 440, height: 540)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.1)))
        .onAppear { searchFocused = true }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Tìm kiếm clipboard… (1–9 để dán nhanh)", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($searchFocused)
            Button(action: close) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(ClipboardHUDModel.Filter.allCases) { filter in
                    Button {
                        model.filter = filter
                    } label: {
                        Label(filter.title, systemImage: filter.icon)
                            .labelStyle(TightLabelStyle(tint: model.filter == filter ? .white : .secondary))
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .foregroundStyle(model.filter == filter ? Color.white : Color.primary.opacity(0.8))
                            .background(model.filter == filter ? Color.accentColor : Color.primary.opacity(0.07), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            KeyHint(key: "↵", label: "Dán")
            KeyHint(key: "1–9", label: "Nhanh")
            KeyHint(key: "⌥P", label: "Ghim")
            KeyHint(key: "⌥⌫", label: "Xóa")
            KeyHint(key: "⎋", label: "Đóng")
            Spacer()
            Text("\(store.items.count) mục").font(.system(size: 10)).foregroundStyle(.secondary)
            Button("Xóa hết") { store.clearAll() }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.red)
                .help("Xóa mọi mục chưa ghim")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct ClipboardRow: View {
    let item: ClipboardItem
    let index: Int
    let isSelected: Bool
    @ObservedObject var model: ClipboardHUDModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(index < 9 ? "\(index + 1)" : "")
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .frame(width: 18, height: 18)
                .background(isSelected ? Color.accentColor : Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Text(item.sourceApp ?? "Không rõ").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.accentColor)
                    Text("• \(Self.relative(item.date))").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    if item.isPinned || isSelected {
                        Button { model.store.togglePin(item.id) } label: {
                            Image(systemName: item.isPinned ? "pin.fill" : "pin").font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(item.isPinned ? Color.orange : Color.secondary)
                    }
                    if isSelected {
                        Button { model.store.delete(item.id) } label: {
                            Image(systemName: "trash").font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                    }
                }
                content
            }
        }
        .padding(8)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(isSelected ? Color.accentColor.opacity(0.5) : .clear))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .text:
            Text(item.text ?? "")
                .font(.system(size: 11.5))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .link:
            Label(item.text ?? "", systemImage: "link")
                .font(.system(size: 11.5))
                .foregroundStyle(.blue)
                .lineLimit(2)
        case .color:
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(hex: item.text ?? "") ?? .clear)
                    .frame(width: 26, height: 18)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.primary.opacity(0.2)))
                Text(item.text ?? "").font(.system(size: 11.5, design: .monospaced))
            }
        case .file:
            let paths = item.filePaths ?? []
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: paths.first ?? "/"))
                    .resizable().frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(paths.first.map { ($0 as NSString).lastPathComponent } ?? "").font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                    Text(paths.count > 1 ? "\(paths.count) tệp" : (paths.first.map { ($0 as NSString).deletingLastPathComponent } ?? ""))
                        .font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        case .image:
            HStack(spacing: 10) {
                if let thumbnail = model.thumbnail(for: item) {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 160, maxHeight: 90)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ảnh (\(item.imageWidth ?? 0) × \(item.imageHeight ?? 0)px)").font(.system(size: 11.5, weight: .semibold))
                    Text("Định dạng ảnh clipboard").font(.system(size: 9.5)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private static func relative(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        switch seconds {
        case ..<60: return "vừa xong"
        case ..<3600: return "\(seconds / 60)p trước"
        case ..<86400: return "\(seconds / 3600)g trước"
        default: return "\(seconds / 86400) ngày trước"
        }
    }
}

struct KeyHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            KeyCap(key)
            Text(label).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
        }
        .fixedSize()
    }
}

struct KeyCap: View {
    let key: String

    init(_ key: String) {
        self.key = key
    }

    var body: some View {
        Text(key)
            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.primary.opacity(0.12)))
    }
}

extension Color {
    /// #RGB, #RRGGBB or #RRGGBBAA.
    init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard digits.hasPrefix("#") else { return nil }
        digits.removeFirst()
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
        let hasAlpha = digits.count == 8
        let red = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let green = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let blue = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let alpha = hasAlpha ? Double(value & 0xFF) / 255 : 1
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}
