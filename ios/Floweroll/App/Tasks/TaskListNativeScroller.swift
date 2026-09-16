import AVFAudio
import AVFoundation
import ContactsUI
import SwiftUI
import UserNotifications


// MARK: - Task hub

@MainActor
final class TaskListNativeScroller {
    enum Target {
        case active
        case history
    }

    private weak var collectionView: UICollectionView?
    private weak var tableView: UITableView?
    private var exactCollectionIndexPaths: [String: IndexPath] = [:]
    private var exactTableIndexPaths: [String: IndexPath] = [:]

    func register(anchor view: UIView, key: String) {
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, let view else { return }
            if let cell = Self.enclosingSuperview(of: UICollectionViewCell.self, from: view),
               let collection = Self.enclosingSuperview(of: UICollectionView.self, from: cell),
               let indexPath = collection.indexPath(for: cell)
            {
                self.collectionView = collection
                self.exactCollectionIndexPaths[key] = indexPath
                return
            }
            if let cell = Self.enclosingSuperview(of: UITableViewCell.self, from: view),
               let table = Self.enclosingSuperview(of: UITableView.self, from: cell),
               let indexPath = table.indexPath(for: cell)
            {
                self.tableView = table
                self.exactTableIndexPaths[key] = indexPath
            }
        }
    }

    @discardableResult
    func scroll(to target: Target, activeRowCount: Int, animated: Bool = true) -> Bool {
        let key = target == .active ? TaskSectionFocus.active.anchorID : TaskSectionFocus.history.anchorID
        if let collectionView {
            let targetPath: IndexPath?
            if let exact = exactCollectionIndexPaths[key] {
                targetPath = exact
            } else if target == .history,
                      let active = exactCollectionIndexPaths[TaskSectionFocus.active.anchorID]
            {
                targetPath = Self.advancedCollectionIndexPath(
                    from: active,
                    rowOffset: max(activeRowCount, 1) + 2,
                    in: collectionView
                )
            } else {
                targetPath = nil
            }
            if let targetPath {
                collectionView.layoutIfNeeded()
                collectionView.scrollToItem(at: targetPath, at: .top, animated: animated)
                return true
            }
        }

        if let tableView {
            let targetPath: IndexPath?
            if let exact = exactTableIndexPaths[key] {
                targetPath = exact
            } else if target == .history,
                      let active = exactTableIndexPaths[TaskSectionFocus.active.anchorID]
            {
                targetPath = Self.advancedTableIndexPath(
                    from: active,
                    rowOffset: max(activeRowCount, 1) + 2,
                    in: tableView
                )
            } else {
                targetPath = nil
            }
            if let targetPath {
                tableView.layoutIfNeeded()
                tableView.scrollToRow(at: targetPath, at: .top, animated: animated)
                return true
            }
        }
        return false
    }

    private static func advancedCollectionIndexPath(
        from start: IndexPath,
        rowOffset: Int,
        in collectionView: UICollectionView
    ) -> IndexPath? {
        var all: [IndexPath] = []
        for section in 0..<collectionView.numberOfSections {
            for item in 0..<collectionView.numberOfItems(inSection: section) {
                all.append(IndexPath(item: item, section: section))
            }
        }
        guard let index = all.firstIndex(of: start) else { return nil }
        let target = index + rowOffset
        return all.indices.contains(target) ? all[target] : nil
    }

    private static func advancedTableIndexPath(
        from start: IndexPath,
        rowOffset: Int,
        in tableView: UITableView
    ) -> IndexPath? {
        var all: [IndexPath] = []
        for section in 0..<tableView.numberOfSections {
            for row in 0..<tableView.numberOfRows(inSection: section) {
                all.append(IndexPath(row: row, section: section))
            }
        }
        guard let index = all.firstIndex(of: start) else { return nil }
        let target = index + rowOffset
        return all.indices.contains(target) ? all[target] : nil
    }

    private static func enclosingSuperview<T: UIView>(of type: T.Type, from view: UIView) -> T? {
        var current: UIView? = view
        while let candidate = current {
            if let match = candidate as? T { return match }
            current = candidate.superview
        }
        return nil
    }
}

struct TaskListNativeScrollAnchor: UIViewRepresentable {
    let key: String
    let scroller: TaskListNativeScroller

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        scroller.register(anchor: view, key: key)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        scroller.register(anchor: uiView, key: key)
    }
}
