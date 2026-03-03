import Foundation
import AppKit

// MARK: - Trie Node

final class KeyNode {
    var children: [String: KeyNode] = [:]
    var command: Command?          // set only on terminal nodes
    var needsChar: Bool = false    // node triggers a char-awaiting command

    init() {}
}

// MARK: - KeyTrie

/// Trie-based key sequence parser.
///
/// Usage:
///   1. Build from a binding table once.
///   2. Call `handleKey(event:)` on every `keyDown` event.
///   3. Inspect returned commands and act on them.
final class KeyTrie {
    private let root = KeyNode()

    // State
    private var pendingNodes: [KeyNode] = []
    private var numPrefix: String = ""
    private var awaitingChar: Bool = false
    private var awaitingCharCommand: ((Character) -> Command)?
    private var resetTimer: Timer?

    // MARK: Build

    func build(from bindings: [(keys: [String], command: Command)]) {
        for binding in bindings {
            var node = root
            for token in binding.keys {
                if node.children[token] == nil {
                    node.children[token] = KeyNode()
                }
                node = node.children[token]!
            }
            node.command = binding.command
        }
    }

    // MARK: Event Handling

    /// Process a key event.
    /// Returns nil if the event was not consumed (caller may beep/pass through).
    /// Returns [] if consumed but no command yet (digit prefix, trie prefix, awaiting char).
    /// Returns [cmd…] when one or more commands are ready to execute.
    func handleKey(event: NSEvent) -> [Command]? {
        let token = Self.token(from: event)

        // Awaiting a character argument (e.g. after `m`, `` ` ``, `h`)
        if awaitingChar, let ch = event.characters?.first, ch.isLetter || ch.isNumber {
            awaitingChar = false
            let factory = awaitingCharCommand
            awaitingCharCommand = nil
            resetTimer?.invalidate()
            resetTimer = nil
            pendingNodes = []
            if let factory = factory {
                return [factory(ch)]
            }
            return []
        }

        // Digit accumulation (only when no trie sequence in progress)
        if pendingNodes.isEmpty,
           let ch = event.characters?.first,
           ch.isNumber,
           !isTriePrefix(token) {
            numPrefix.append(ch)
            scheduleReset()
            return []
        }

        // Advance trie
        let candidates: [KeyNode] = pendingNodes.isEmpty ? [root] : pendingNodes
        var nextNodes: [KeyNode] = []
        for node in candidates {
            if let child = node.children[token] {
                nextNodes.append(child)
            }
        }

        if nextNodes.isEmpty {
            // No match — reset and try from root
            reset()
            // Try single-key match from root
            if let child = root.children[token] {
                if let cmd = child.command {
                    return finalize(cmd)
                }
                pendingNodes = [child]
                scheduleReset()
                return []   // consumed: started a new trie sequence
            }
            return nil      // not consumed: unknown key, let caller beep
        }

        // Check for terminal matches
        var commands: [Command] = []
        var continueNodes: [KeyNode] = []
        for node in nextNodes {
            if let cmd = node.command {
                commands.append(applyPrefix(cmd))
                if !node.children.isEmpty {
                    // Could still be a prefix for longer sequences
                }
            } else {
                continueNodes.append(node)
            }
        }

        // Prefer longer sequences: if there are children that could extend, keep waiting
        let hasExtensions = nextNodes.contains { !$0.children.isEmpty }

        if !commands.isEmpty && !hasExtensions {
            reset()
            return handleNeedsChar(commands)
        }

        if !commands.isEmpty && hasExtensions {
            // Ambiguous: take the match but allow extension
            pendingNodes = continueNodes
            reset()
            return handleNeedsChar(commands)
        }

        pendingNodes = nextNodes
        scheduleReset()
        return []
    }

    // MARK: - Private

    private func isTriePrefix(_ token: String) -> Bool {
        return root.children[token] != nil
    }

    private func finalize(_ cmd: Command) -> [Command] {
        reset()
        return handleNeedsChar([applyPrefix(cmd)])
    }

    private func applyPrefix(_ cmd: Command) -> Command {
        defer { numPrefix = "" }
        guard !numPrefix.isEmpty, let n = Int(numPrefix) else { return cmd }
        switch cmd {
        case .gotoBeginning where n > 0: return .gotoPage(n - 1)
        case .scrollDown(let d):         return .scrollDown(d * CGFloat(n))
        case .scrollUp(let d):           return .scrollUp(d * CGFloat(n))
        case .nextPage:                  return .gotoPage(n - 1)
        default:                         return cmd
        }
    }

    private func handleNeedsChar(_ commands: [Command]) -> [Command] {
        var result: [Command] = []
        for cmd in commands {
            switch cmd {
            case .setMark:
                awaitingChar = true
                awaitingCharCommand = { .setMark($0) }
                scheduleReset()
            case .gotoMark:
                awaitingChar = true
                awaitingCharCommand = { .gotoMark($0) }
                scheduleReset()
            case .addHighlight:
                awaitingChar = true
                awaitingCharCommand = { .addHighlight($0) }
                scheduleReset()
            default:
                result.append(cmd)
            }
        }
        return result
    }

    private func scheduleReset() {
        resetTimer?.invalidate()
        resetTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            self?.reset()
        }
    }

    private func reset() {
        pendingNodes = []
        numPrefix = ""
        awaitingChar = false
        awaitingCharCommand = nil
        resetTimer?.invalidate()
        resetTimer = nil
    }

    // MARK: - Token conversion

    /// Converts an NSEvent to a canonical string token.
    static func token(from event: NSEvent) -> String {
        let mods = event.modifierFlags
        let hasCtrl  = mods.contains(.control)
        let hasShift = mods.contains(.shift)
        let hasOpt   = mods.contains(.option)
        let hasCmd   = mods.contains(.command)

        // Special keys (macOS virtual key codes)
        switch event.keyCode {
        case 36:  return hasShift ? "<S-return>" : "<return>"
        case 48:  return "<tab>"
        case 49:  return hasShift ? "<S-space>" : "<space>"
        case 51:  return hasShift ? "<S-backspace>" : "<backspace>"
        case 53:  return "<esc>"
        case 122: return "<f1>"
        case 120: return "<f2>"
        case 99:  return "<f3>"
        case 118: return "<f4>"
        case 96:  return "<f5>"
        case 97:  return "<f6>"
        case 98:  return "<f7>"
        case 100: return "<f8>"
        case 101: return "<f9>"
        case 109: return "<f10>"
        case 103: return "<f11>"
        case 111: return "<f12>"
        case 123: return hasShift ? "<S-left>"  : "<left>"
        case 124: return hasShift ? "<S-right>" : "<right>"
        case 125: return hasShift ? "<S-down>"  : "<down>"
        case 126: return hasShift ? "<S-up>"    : "<up>"
        default: break
        }

        guard let chars = event.characters, !chars.isEmpty else { return "" }

        // Normalize to lowercase for comparison purposes
        let lower = chars.lowercased()

        if hasCtrl {
            return "<C-\(lower)>"
        }
        if hasOpt && !hasShift {
            return "<A-\(lower)>"
        }
        if hasCmd {
            return "<D-\(lower)>"
        }
        // Uppercase letters are represented as-is (shift is implicit)
        return chars
    }
}
