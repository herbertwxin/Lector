import Foundation

// MARK: - Navigation State

struct NavState: Equatable {
    let url: URL
    let page: Int
    let yOffset: Double
}

// MARK: - Navigation History

/// Fixed-capacity back/forward stack for document navigation.
final class NavHistory {
    private let capacity: Int
    private var stack: [NavState] = []
    private var index: Int = -1   // points at current position

    init(capacity: Int = 100) {
        self.capacity = capacity
    }

    /// Push a new state, discarding any forward history.
    func push(_ state: NavState) {
        // Drop forward history
        if index < stack.count - 1 {
            stack = Array(stack.prefix(index + 1))
        }
        // Drop oldest if over capacity
        if stack.count >= capacity {
            stack.removeFirst()
            index = stack.count - 1
        }
        stack.append(state)
        index = stack.count - 1
    }

    /// Returns the previous state and moves the cursor back.
    func back() -> NavState? {
        guard index > 0 else { return nil }
        index -= 1
        return stack[index]
    }

    /// Returns the next state and moves the cursor forward.
    func forward() -> NavState? {
        guard index < stack.count - 1 else { return nil }
        index += 1
        return stack[index]
    }

    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index < stack.count - 1 }

    var current: NavState? {
        guard index >= 0, index < stack.count else { return nil }
        return stack[index]
    }
}
