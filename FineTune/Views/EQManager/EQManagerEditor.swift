// FineTune/Views/EQManager/EQManagerEditor.swift
import Foundation

/// Draft of the preset shown in the EQ Manager, with its edit mode and undo/redo history.
///
/// Every change goes through `apply` (one history step) or a gesture (`beginGesture`,
/// `updateGesture`, `endGesture`: one step for a whole drag). The history lives until
/// the draft is saved or discarded.
@Observable
@MainActor
final class EQManagerEditor {
    /// The preset as stored on disk (or in the catalog).
    private(set) var original: AutoEQProfile
    /// The preset as shown, including unsaved changes.
    private(set) var draft: AutoEQProfile
    private(set) var isEditing = false

    private var undoStack: [AutoEQProfile] = []
    private var redoStack: [AutoEQProfile] = []
    private var gestureSnapshot: AutoEQProfile?

    init(profile: AutoEQProfile) {
        original = profile
        draft = profile
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var hasChanges: Bool { draft != original }

    func beginEditing() {
        isEditing = true
    }

    /// Apply one change as a single history step. Ignored outside edit mode.
    func apply(_ change: (inout AutoEQProfile) -> Void) {
        guard isEditing else { return }
        var next = draft
        change(&next)
        guard next != draft else { return }
        undoStack.append(draft)
        redoStack.removeAll()
        draft = next
    }

    /// Start a continuous change (a drag on the graph).
    func beginGesture() {
        guard isEditing else { return }
        gestureSnapshot = draft
    }

    /// Update the draft during a gesture, without adding history steps.
    func updateGesture(_ change: (inout AutoEQProfile) -> Void) {
        guard gestureSnapshot != nil else { return }
        change(&draft)
    }

    /// Finish a gesture: the whole gesture becomes one history step.
    func endGesture() {
        if let snapshot = gestureSnapshot, snapshot != draft {
            undoStack.append(snapshot)
            redoStack.removeAll()
        }
        gestureSnapshot = nil
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(draft)
        draft = previous
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(draft)
        draft = next
    }

    /// Drop every unsaved change and leave edit mode.
    func discard() {
        draft = original
        clearHistory()
        isEditing = false
    }

    /// The draft was saved (possibly as a new copy): it becomes the stored version.
    func markSaved(_ saved: AutoEQProfile) {
        original = saved
        draft = saved
        clearHistory()
        isEditing = false
    }

    private func clearHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        gestureSnapshot = nil
    }
}
