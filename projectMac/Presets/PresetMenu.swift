import AppKit

/// The top-level "Presets" menu, built in AppKit because SwiftUI menus can't hold a text
/// field: next/previous/random, a search field whose matches appear right under it, and
/// "Browse" with one submenu per preset directory. The ~10k presets are only turned into
/// menu items when their directory submenu opens.
@MainActor
final class PresetMenu: NSObject, NSMenuDelegate, NSSearchFieldDelegate {
    private struct Entry { let index: Int; let category: String; let name: String }

    private let coordinator: AppCoordinator
    /// SwiftUI's own "Presets" submenu (it holds next/previous/random). A top-level item
    /// that SwiftUI owns never vanishes from the menu bar when it rebuilds its menus, which
    /// an item we insert ourselves does, so we only append to its submenu.
    private var host: NSMenu?
    private let searchField = NSSearchField()
    private let searchItem = NSMenuItem()
    private let separators = [NSMenuItem.separator(), NSMenuItem.separator()]
    private let browseItem = NSMenuItem(title: "Browse", action: nil, keyEquivalent: "")
    private var resultItems: [NSMenuItem] = []
    private var presets: [Entry] = []
    private var byCategory: [String: [Entry]] = [:]
    private let maxResults = 15
    private var observers: [NSObjectProtocol] = []
    private var mainMenuObservation: NSKeyValueObservation?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        super.init()
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 32))
        searchField.frame = NSRect(x: 10, y: 4, width: 260, height: 24)
        searchField.autoresizingMask = [.width]
        searchField.placeholderString = "Search presets"
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        box.addSubview(searchField)
        searchItem.view = box
        browseItem.submenu = NSMenu(title: "Browse")
    }

    /// Starts keeping the search/browse items in SwiftUI's Presets menu. SwiftUI rebuilds its
    /// menus on app state changes and may drop what we appended, so re-attach whenever the
    /// main menu changes or the menu bar is about to be used.
    func install() {
        guard observers.isEmpty else { return attach() }
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.attach() }
            },
            nc.addObserver(forName: NSMenu.didChangeItemNotification, object: nil, queue: .main) { [weak self] n in
                let changed = (n.object as AnyObject?).map(ObjectIdentifier.init)
                MainActor.assumeIsolated {
                    guard let changed, let self else { return }
                    if changed == self.host.map(ObjectIdentifier.init) || changed == NSApp.mainMenu.map(ObjectIdentifier.init) { self.attach() }
                }
            },
        ]
        mainMenuObservation = NSApp.observe(\.mainMenu) { [weak self] _, _ in
            DispatchQueue.main.async { self?.attach() }
        }
        attach()
        // SwiftUI may not have built its menus yet; the notifications above catch most
        // changes, these catch a menu that was still empty when we first looked.
        for delay in [0.25, 1, 3] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.attach() } }
    }

    private func attach() {
        guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == "Presets" })?.submenu else { return }
        host = menu
        if menu.delegate !== self { menu.delegate = self }
        let mine = [separators[0], searchItem, separators[1], browseItem]
        guard !mine.allSatisfy({ $0.menu === menu }) else { return }
        for it in mine { it.menu?.removeItem(it) }
        resultItems.forEach { $0.menu?.removeItem($0) }
        resultItems = []
        mine.forEach(menu.addItem)
    }

    @objc private func go(_ sender: NSMenuItem) { coordinator.goToPreset(sender.tag) }

    // MARK: - Data

    /// Re-read on every open: shuffling reorders the playlist, which changes the indices.
    private func reload() {
        let root = (Bundle.main.resourceURL?.appendingPathComponent("Presets").path ?? "") + "/"
        presets = coordinator.presetPaths().enumerated().map { i, path in
            let dir = (path as NSString).deletingLastPathComponent
            let category = dir.hasPrefix(root) ? String(dir.dropFirst(root.count)) : dir
            return Entry(index: i, category: category.isEmpty ? "Other" : category,
                         name: (path as NSString).lastPathComponent)
        }
        byCategory = Dictionary(grouping: presets, by: \.category)
        let submenu = browseItem.submenu!
        submenu.removeAllItems()
        for category in byCategory.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            let it = NSMenuItem(title: category, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: category) // title doubles as the lookup key in menuNeedsUpdate
            sub.delegate = self
            it.submenu = sub
            submenu.addItem(it)
        }
    }

    private func presetItem(_ e: Entry, title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: #selector(go(_:)), keyEquivalent: "")
        it.target = self
        it.tag = e.index
        it.state = e.name == coordinator.renderStats.presetName ? .on : .off
        return it
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === host {
            reload()
        } else if menu.numberOfItems == 0 {
            for e in (byCategory[menu.title] ?? []).sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                menu.addItem(presetItem(e, title: e.name))
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === host else { return }
        DispatchQueue.main.async { self.searchField.window?.makeFirstResponder(self.searchField) }
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === host else { return }
        searchField.stringValue = ""
        showResults()
    }

    // MARK: - Search

    func controlTextDidChange(_ obj: Notification) { showResults() }

    /// Return jumps to the best (first) match.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        if let first = resultItems.first, first.action != nil {
            go(first)
            host?.cancelTracking()
        }
        return true
    }

    private func showResults() {
        guard let menu = host else { return }
        resultItems.forEach(menu.removeItem)
        resultItems = []
        let terms = searchField.stringValue.split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let hits = presets.filter { e in terms.allSatisfy { e.name.range(of: $0, options: opts) != nil } }
        var at = menu.index(of: searchItem) + 1
        func add(_ it: NSMenuItem) { menu.insertItem(it, at: at); at += 1; resultItems.append(it) }
        for e in hits.prefix(maxResults) {
            let it = presetItem(e, title: e.name)
            it.toolTip = e.category
            add(it)
        }
        if hits.isEmpty {
            add(disabled("No matches"))
        } else if hits.count > maxResults {
            add(disabled("\(hits.count - maxResults) more — keep typing"))
        }
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }
}
