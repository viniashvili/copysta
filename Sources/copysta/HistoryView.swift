import SwiftUI
import AppKit

struct HistoryView: View {
    @ObservedObject var service: HistoryService
    @ObservedObject var keyState: PopupKeyState
    let onSelect: (Entry) -> Void

    @Namespace private var selection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if service.entries.isEmpty {
                Text("Nothing copied yet")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                entryScroll
            }
        }
        .background(.clear)
        .animation(.easeInOut(duration: 0.2), value: service.entries.isEmpty)
    }

    // ScrollView + LazyVStack instead of List so that arrow-key events are NOT
    // consumed by an underlying NSTableView and instead reach PopupPanel.keyDown.
    private var entryScroll: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(service.entries.enumerated()), id: \.element.id) { idx, entry in
                        EntryRow(
                            entry: entry,
                            isSelected: idx == keyState.selectedIndex,
                            isFlashing: keyState.isFlashing,
                            selection: selection,
                            onSelect: { onSelect(entry) },
                            onHover: { keyState.selectedIndex = idx },
                            onDelete: { service.delete(entry) }
                        )
                        .id(entry.id)
                        // Removed rows fade and shrink while the rows below slide up.
                        .transition(reduceMotion
                                    ? .opacity
                                    : .asymmetric(insertion: .opacity,
                                                  removal: .opacity.combined(with: .scale(scale: 0.95))))
                    }
                }
                .padding(6)
                .animation(.easeInOut(duration: 0.22), value: service.entries.map(\.id))
                // The highlight glides between rows instead of jumping.
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: keyState.selectedIndex)
                .animation(.easeInOut(duration: 0.07), value: keyState.isFlashing)
            }
            .onChange(of: keyState.selectedIndex, perform: { idx in
                guard idx < service.entries.count else { return }
                proxy.scrollTo(service.entries[idx].id)
            })
            // Deleting the last row would leave the selection pointing past the end.
            .onChange(of: service.entries.count, perform: { count in
                if keyState.selectedIndex >= count {
                    keyState.selectedIndex = max(0, count - 1)
                }
            })
        }
    }
}

// MARK: - EntryRow

private struct EntryRow: View {
    let entry: Entry
    let isSelected: Bool
    let isFlashing: Bool
    let selection: Namespace.ID
    let onSelect: () -> Void
    let onHover: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if entry.kind == .image {
                ImageThumb(path: entry.imagePath)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(entry.timeLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isSelected {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.6))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.black.opacity(0.15)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(red: 0.04, green: 0.39, blue: 0.84))
                    .opacity(isFlashing ? 0.35 : 1)
                    .matchedGeometryEffect(id: "selection", in: selection)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { if $0 { onHover() } }
    }

    private var title: String {
        switch entry.kind {
        case .text:
            return entry.textPreview.isEmpty ? "(empty)" : entry.textPreview
        case .image:
            if let size = ImageThumb.info(for: entry.imagePath)?.pixelSize {
                return "Image · \(Int(size.width)) × \(Int(size.height))"
            }
            return "Image"
        }
    }
}

// MARK: - ImageThumb

private struct ImageThumb: View {
    let path: String?

    final class Info {
        let image: NSImage
        let pixelSize: CGSize
        init(image: NSImage, pixelSize: CGSize) {
            self.image = image
            self.pixelSize = pixelSize
        }
    }

    // Decoding a PNG on every render is wasteful; keep recently shown ones around.
    private static let cache = NSCache<NSString, Info>()

    static func info(for path: String?) -> Info? {
        guard let path else { return nil }
        if let hit = cache.object(forKey: path as NSString) { return hit }
        guard let img = NSImage(contentsOfFile: path) else { return nil }
        let rep = img.representations.first
        let px = CGSize(width: rep?.pixelsWide ?? Int(img.size.width),
                        height: rep?.pixelsHigh ?? Int(img.size.height))
        let info = Info(image: img, pixelSize: px)
        cache.setObject(info, forKey: path as NSString)
        return info
    }

    var body: some View {
        Group {
            if let info = Self.info(for: path) {
                Image(nsImage: info.image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.12), lineWidth: 0.5))
    }
}
