import AppKit
import Foundation

@MainActor
final class SettingsDraftCoordinator {
    enum ParticipantID: Hashable {
        case modes
        case asrCredentials
        case llmCredentials
    }

    struct Participant {
        let isDirty: () -> Bool
        let save: () -> Bool
        let discard: () -> Void
    }

    private var participants: [ParticipantID: Participant] = [:]

    var hasUnsavedChanges: Bool {
        participants.values.contains { $0.isDirty() }
    }

    func register(
        _ id: ParticipantID,
        isDirty: @escaping () -> Bool,
        save: @escaping () -> Bool,
        discard: @escaping () -> Void
    ) {
        participants[id] = Participant(
            isDirty: isDirty,
            save: save,
            discard: discard
        )
    }

    func unregister(_ id: ParticipantID) {
        participants.removeValue(forKey: id)
    }

    @discardableResult
    func saveAll() -> Bool {
        for participant in participants.values where participant.isDirty() {
            guard participant.save() else { return false }
        }
        return true
    }

    func discardAll() {
        for participant in participants.values where participant.isDirty() {
            participant.discard()
        }
    }
}

@MainActor
final class WeakSettingsWindowBox {
    weak var window: NSWindow?
}
