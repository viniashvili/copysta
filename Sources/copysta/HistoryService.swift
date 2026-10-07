import Foundation

final class HistoryService: ObservableObject {
    @Published private(set) var entries: [Entry] = []

    private let store: Store
    private let queue = DispatchQueue(label: "copysta.store", qos: .utility)

    static let maxTextBytes  = 1 * 1024 * 1024   // 1 MiB
    static let maxImageBytes = 20 * 1024 * 1024  // 20 MiB
    static let maxEntries    = 500

    init(store: Store) {
        self.store = store
        reload()
    }

    func add(_ item: ClipItem) {
        switch item.kind {
        case .text:
            let bytes = item.text?.utf8.count ?? 0
            guard bytes > 0, bytes <= Self.maxTextBytes else { return }
        case .image:
            let bytes = item.imageData?.count ?? 0
            guard bytes > 0, bytes <= Self.maxImageBytes else { return }
        }

        let dataDir = store.dataDir
        queue.async { [weak self] in
            guard let self else { return }
            _ = try? self.store.upsert(item, dataDir: dataDir)
            try? self.store.trim(max: Self.maxEntries)
            let fresh = (try? self.store.list(limit: Self.maxEntries)) ?? []
            DispatchQueue.main.async { self.entries = fresh }
        }
    }

    func delete(_ entry: Entry) {
        queue.async { [weak self] in
            guard let self else { return }
            try? self.store.delete(id: entry.id)
            let fresh = (try? self.store.list(limit: Self.maxEntries)) ?? []
            DispatchQueue.main.async { self.entries = fresh }
        }
    }

    func clear() {
        queue.async { [weak self] in
            guard let self else { return }
            try? self.store.clear()
            DispatchQueue.main.async { self.entries = [] }
        }
    }

    private func reload() {
        queue.async { [weak self] in
            guard let self else { return }
            let fresh = (try? self.store.list(limit: Self.maxEntries)) ?? []
            DispatchQueue.main.async { self.entries = fresh }
        }
    }
}
