import Foundation
import os.log

// MARK: - PinStore

/// Device-local pins: items the user wants at the top of whatever list they are looking at.
///
/// Pinning is deliberately *not* synced. Drive has no `is_pinned` column and no endpoint that
/// could carry one, and the web app has no pin concept at all, so there is nothing to be
/// compatible with — see `agent_docs/plans/feat-epic-12-organization.md` §1.1. Favorites
/// (`NoteItem.isStarred`) is the cross-device mechanism; a pin is a per-device convenience and
/// the UI says so.
///
/// Only ids are stored, in `UserDefaults`, so a pin costs nothing and survives a reinstall of the
/// offline cache. An id whose item has been deleted is inert: `sorted(_:)` only ever reorders
/// items it is given.
@MainActor
final class PinStore: ObservableObject {

    // MARK: - Published State

    /// Pinned item ids, most recently pinned first.
    @Published private(set) var pinnedIDs: [String] = []

    // MARK: - Private

    static let defaultsKey = "nn.pinnedItemIDs"

    private let defaults: UserDefaults

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NeutrinoNotes",
                                category: "PinStore")

    // MARK: - Init

    /// - Parameter defaults: `nil` uses `.standard`. Tests pass a throwaway suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.pinnedIDs = defaults.stringArray(forKey: Self.defaultsKey) ?? []
    }

    // MARK: - Queries

    func isPinned(_ itemID: String) -> Bool {
        pinnedIDs.contains(itemID)
    }

    var pinnedCount: Int { pinnedIDs.count }

    // MARK: - Mutations

    func togglePin(_ itemID: String) {
        isPinned(itemID) ? unpin(itemID) : pin(itemID)
    }

    func pin(_ itemID: String) {
        guard !isPinned(itemID) else { return }
        pinnedIDs.insert(itemID, at: 0)
        save()
        logger.debug("pin: id=\(itemID, privacy: .public)")
    }

    func unpin(_ itemID: String) {
        guard isPinned(itemID) else { return }
        pinnedIDs.removeAll { $0 == itemID }
        save()
        logger.debug("unpin: id=\(itemID, privacy: .public)")
    }

    func unpinAll() {
        guard !pinnedIDs.isEmpty else { return }
        logger.debug("unpinAll: clearing \(self.pinnedIDs.count) pin(s)")
        pinnedIDs = []
        save()
    }

    // MARK: - Ordering

    /// Floats pinned items to the top, newest pin first, and leaves everything else in the order
    /// it was given — the server's ordering is the app's ordering for unpinned items.
    func sorted(_ items: [NoteItem]) -> [NoteItem] {
        guard !pinnedIDs.isEmpty else { return items }
        let rank = Dictionary(uniqueKeysWithValues: pinnedIDs.enumerated().map { ($1, $0) })
        let pinned = items.filter { rank[$0.id] != nil }
            .sorted { (rank[$0.id] ?? 0) < (rank[$1.id] ?? 0) }
        guard !pinned.isEmpty else { return items }
        return pinned + items.filter { rank[$0.id] == nil }
    }

    // MARK: - Persistence

    private func save() {
        defaults.set(pinnedIDs, forKey: Self.defaultsKey)
    }
}
