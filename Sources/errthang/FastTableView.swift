import SwiftUI
import AppKit
import ErrthangCore

struct FastTableView: NSViewRepresentable {
    var items: SearchResults
    var itemsVersion: UUID
    @Binding var selection: Set<SearchResultItem.ID>
    @Binding var sortDescriptors: [NSSortDescriptor]

    // Actions
    var onRevealInFinder: (Set<String>) -> Void
    var onCopyPath: (Set<String>) -> Void
    var onCopyName: (Set<String>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let tableView = NSTableView()
        tableView.headerView = NSTableHeaderView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.style = .fullWidth
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        // Register columns
        let columns = [
            ("Name", "name", 300.0),
            ("Path", "path", 300.0),
            ("Size", "size", 80.0),
            ("Date Modified", "dateForSorting", 150.0)
        ]

        for (title, key, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = title
            column.width = width
            column.minWidth = 50
            column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true)
            tableView.addTableColumn(column)
        }

        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.doubleAction = #selector(Coordinator.onDoubleClick(_:))
        tableView.target = context.coordinator

        // Context Menu
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Reveal in Finder", action: #selector(Coordinator.revealInFinder), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Copy Path", action: #selector(Coordinator.copyPath), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Copy Name", action: #selector(Coordinator.copyName), keyEquivalent: ""))
        tableView.menu = menu

        // Initial Sort State
        tableView.sortDescriptors = sortDescriptors

        scrollView.documentView = tableView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tableView = nsView.documentView as? NSTableView else { return }

        let coordinator = context.coordinator

        // Update data source
        // Check if we need to reload based on version UUID
        if coordinator.lastVersion != itemsVersion {
            coordinator.items = items
            coordinator.lastVersion = itemsVersion
            tableView.reloadData()
        }

        // Sync sort descriptors
        if tableView.sortDescriptors != sortDescriptors {
            tableView.sortDescriptors = sortDescriptors
        }

        // Sync selection from SwiftUI to NSView if needed (bi-directional is tricky, usually we assume View -> State)
        // Here we just let the delegate update the binding.
        // If we wanted programmatic selection update:
        // let selectedIndices = IndexSet(items.enumerated().filter { selection.contains($0.element.id) }.map { $0.offset })
        // if tableView.selectedRowIndexes != selectedIndices {
        //    tableView.selectRowIndexes(selectedIndices, byExtendingSelection: false)
        // }
    }

    @MainActor
    class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: FastTableView
        var items: SearchResults = SearchResults(items: [])
        var lastVersion: UUID?

        init(_ parent: FastTableView) {
            self.parent = parent
        }

        // MARK: - DataSource

        func numberOfRows(in tableView: NSTableView) -> Int {
            return items.count
        }

        // MARK: - Delegate

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let columnId = tableColumn?.identifier.rawValue, row < items.count else { return nil }
            let item = items[row]

            let cellIdentifier = NSUserInterfaceItemIdentifier(columnId)
            var view = tableView.makeView(withIdentifier: cellIdentifier, owner: nil) as? NSTableCellView

            if view == nil {
                view = NSTableCellView()
                view?.identifier = cellIdentifier

                let textField = NSTextField()
                textField.isEditable = false
                textField.isBordered = false
                textField.backgroundColor = .clear
                textField.translatesAutoresizingMaskIntoConstraints = false
                textField.lineBreakMode = .byTruncatingTail

                view?.addSubview(textField)
                view?.textField = textField

                // Add icon for Name column
                if columnId == "name" {
                    let imageView = NSImageView()
                    imageView.translatesAutoresizingMaskIntoConstraints = false
                    view?.addSubview(imageView)
                    view?.imageView = imageView

                    NSLayoutConstraint.activate([
                        imageView.leadingAnchor.constraint(equalTo: view!.leadingAnchor, constant: 2),
                        imageView.centerYAnchor.constraint(equalTo: view!.centerYAnchor),
                        imageView.widthAnchor.constraint(equalToConstant: 16),
                        imageView.heightAnchor.constraint(equalToConstant: 16),

                        textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
                        textField.trailingAnchor.constraint(equalTo: view!.trailingAnchor, constant: -2),
                        textField.centerYAnchor.constraint(equalTo: view!.centerYAnchor)
                    ])
                } else {
                    NSLayoutConstraint.activate([
                        textField.leadingAnchor.constraint(equalTo: view!.leadingAnchor, constant: 2),
                        textField.trailingAnchor.constraint(equalTo: view!.trailingAnchor, constant: -2),
                        textField.centerYAnchor.constraint(equalTo: view!.centerYAnchor)
                    ])
                }
            }

            // Configure Cell
            switch columnId {
            case "name":
                view?.textField?.stringValue = item.name
                let iconName = item.isDirectory ? "folder" : "doc"
                view?.imageView?.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
                view?.textField?.textColor = .labelColor
            case "path":
                view?.textField?.stringValue = item.path
                view?.textField?.lineBreakMode = .byTruncatingMiddle
                view?.textField?.textColor = .secondaryLabelColor
            case "size":
                view?.textField?.stringValue = Formatters.byteCountFormatter.string(fromByteCount: item.size)
                view?.textField?.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                view?.textField?.textColor = .labelColor
            case "dateForSorting": // mapped from key
                view?.textField?.stringValue = item.modificationDate?.formatted(date: .numeric, time: .shortened) ?? "-"
                view?.textField?.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                view?.textField?.textColor = .labelColor
            default:
                break
            }

            return view
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView = notification.object as? NSTableView else { return }
            let selectedRowIndexes = tableView.selectedRowIndexes

            var newSelection = Set<SearchResultItem.ID>()
            selectedRowIndexes.forEach { index in
                if index < items.count {
                    newSelection.insert(items[index].id)
                }
            }

            DispatchQueue.main.async {
                self.parent.selection = newSelection
            }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            let descriptors = tableView.sortDescriptors
            DispatchQueue.main.async {
                self.parent.sortDescriptors = descriptors
            }
        }

        // MARK: - Actions

        @objc func onDoubleClick(_ sender: Any) {
            guard let tableView = sender as? NSTableView else { return }
            let clickedRow = tableView.clickedRow
            if clickedRow >= 0 && clickedRow < items.count {
                let item = items[clickedRow]
                parent.onRevealInFinder([item.path])
            }
        }

        @objc func revealInFinder() {
             parent.onRevealInFinder(getSelectedPaths())
        }

        @objc func copyPath() {
             parent.onCopyPath(getSelectedPaths())
        }

        @objc func copyName() {
             parent.onCopyName(getSelectedPaths())
        }

        private func getSelectedPaths() -> Set<String> {
             return parent.selection
        }
    }
}
