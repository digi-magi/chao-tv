import UIKit

/// Lets the house agent see and press what is on screen without screenshots.
///
/// `snapshot()` walks the visible windows' accessibility tree (what VoiceOver
/// would read) and reports each labelled element with its frame, whether it is
/// a button, and which one has focus. `activate(label:)` presses an element by
/// its label, so the agent can hit any button without steering focus to it.
@MainActor
enum ChaoScreen {
    private struct Node {
        let object: NSObject
        let label: String
        let value: String?
        let frame: CGRect
        let isButton: Bool
        let isSelected: Bool
    }

    private static var windows: [UIWindow] {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .filter { !$0.isHidden && $0.alpha > 0.01 }
    }

    private static func focusedObject() -> NSObject? {
        for window in windows {
            if let item = UIFocusSystem.focusSystem(for: window)?.focusedItem as? NSObject {
                return item
            }
        }
        return nil
    }

    private static func label(of object: NSObject) -> String? {
        let raw = object.accessibilityLabel ?? (object as? UILabel)?.text
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private static func collect(limit: Int) -> [Node] {
        var nodes: [Node] = []
        var seen = Set<ObjectIdentifier>()
        let screen = UIScreen.main.bounds

        func visit(_ object: NSObject, depth: Int) {
            guard depth < 80, nodes.count < limit, seen.insert(ObjectIdentifier(object)).inserted else { return }
            if let view = object as? UIView, view.isHidden || view.alpha < 0.01 { return }
            if object.isAccessibilityElement, let text = label(of: object) {
                let frame = object.accessibilityFrame
                if frame.intersects(screen), frame.width > 1, frame.height > 1 {
                    let traits = object.accessibilityTraits
                    nodes.append(Node(object: object, label: text, value: object.accessibilityValue,
                                      frame: frame, isButton: traits.contains(.button),
                                      isSelected: traits.contains(.selected)))
                }
            }
            if let elements = object.accessibilityElements as? [NSObject] {
                for element in elements { visit(element, depth: depth + 1) }
            } else {
                let count = object.accessibilityElementCount()
                if count != NSNotFound, count > 0 {
                    for index in 0..<min(count, 400) {
                        if let element = object.accessibilityElement(at: index) as? NSObject {
                            visit(element, depth: depth + 1)
                        }
                    }
                }
            }
            if let view = object as? UIView {
                for sub in view.subviews { visit(sub, depth: depth + 1) }
            }
        }

        for window in windows { visit(window, depth: 0) }
        return nodes
    }

    /// What is on screen: focused element plus labelled elements, top-left first.
    static func snapshot(limit: Int = 150) -> [String: Any] {
        let nodes = collect(limit: limit)
        let focused = focusedObject()
        var focusedLabel: String? = focused.flatMap { label(of: $0) }
        var rows: [[String: Any]] = []
        let sorted = nodes.sorted {
            abs($0.frame.minY - $1.frame.minY) > 8 ? $0.frame.minY < $1.frame.minY : $0.frame.minX < $1.frame.minX
        }
        for node in sorted {
            var row: [String: Any] = [
                "label": node.label,
                "x": Int(node.frame.midX), "y": Int(node.frame.midY)
            ]
            if node.isButton { row["button"] = true }
            if node.isSelected { row["selected"] = true }
            if let value = node.value, !value.isEmpty { row["value"] = value }
            if let focused, node.object === focused || isAncestor(focused, of: node.object) {
                row["focused"] = true
                if focusedLabel == nil { focusedLabel = node.label }
            }
            rows.append(row)
        }
        var result: [String: Any] = ["elements": rows, "count": rows.count]
        if let focusedLabel { result["focused"] = focusedLabel }
        if let focused { result["focusedType"] = String(describing: type(of: focused)) }
        return result
    }

    private static func isAncestor(_ candidate: NSObject, of object: NSObject) -> Bool {
        guard let ancestor = candidate as? UIView else { return false }
        var current: UIView? = (object as? UIView)?.superview
        while let view = current {
            if view === ancestor { return true }
            current = view.superview
        }
        return false
    }

    /// Presses the `index`th visible element whose label matches (exact match
    /// first, then case-insensitive contains). Returns the pressed label.
    static func activate(label wanted: String, index: Int = 0) -> String? {
        let nodes = collect(limit: 400)
        let needle = wanted.lowercased()
        let exact = nodes.filter { $0.label.lowercased() == needle }
        let loose = nodes.filter { $0.label.lowercased().contains(needle) }
        let matches = (exact.isEmpty ? loose : exact).sorted { $0.isButton && !$1.isButton }
        guard index < matches.count else { return nil }
        let node = matches[index]
        if node.object.accessibilityActivate() { return node.label }
        if let control = node.object as? UIControl {
            control.sendActions(for: .primaryActionTriggered)
            return node.label
        }
        return nil
    }
}
