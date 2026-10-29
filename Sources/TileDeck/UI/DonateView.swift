import AppKit
import SwiftUI

/// The "Ủng hộ" page: a VietQR code any Vietnamese banking app can scan.
/// The image is read only while the page is open.
struct DonateView: View {
    static let accountNumber = "28341082203"

    let close: () -> Void
    @State private var copied = false

    private static var imageURL: URL? { Bundle.main.url(forResource: "Donate", withExtension: "png") }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button(action: close) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("Quay lại")
                Spacer()
                Text("Ủng hộ TileDeck").font(.system(size: 13, weight: .bold))
                Spacer()
                Color.clear.frame(width: 24, height: 24)
            }

            Text("TileDeck miễn phí và mã nguồn mở. Nếu app có ích với bạn, có thể mời mình một ly cà phê. Cảm ơn bạn nhiều!")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let url = Self.imageURL, let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 210)
                    .padding(8)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.1)))
            } else {
                Text("Không tìm thấy ảnh QR trong gói ứng dụng.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.accountNumber, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Đã chép" : "Chép số TK", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                Button {
                    saveImage()
                } label: {
                    Label("Lưu ảnh QR", systemImage: "square.and.arrow.down")
                }
            }
            .controlSize(.small)

            Text("Quét bằng app ngân hàng bất kỳ, số tiền tuỳ bạn.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// Copies the QR to Downloads and shows it in Finder, to send to a phone.
    private func saveImage() {
        guard let source = Self.imageURL,
              let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        let target = downloads.appendingPathComponent("TileDeck-ung-ho.png")
        try? FileManager.default.removeItem(at: target)
        guard (try? FileManager.default.copyItem(at: source, to: target)) != nil else { return }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }
}
