import Foundation

struct GestureModifiers: OptionSet, Equatable {
    let rawValue: Int

    static let control = GestureModifiers(rawValue: 1 << 0)
    static let option = GestureModifiers(rawValue: 1 << 1)
    static let function = GestureModifiers(rawValue: 1 << 2)
}

enum HotkeyAction: Equatable {
    case pushToTalkBegan
    case pushToTalkEnded
    case dictationBegan
    case dictationEnded
    case typedInputRequested
    case openChatRequested
    case dismissPanels
}

struct HotkeyInterpreter {
    private enum HoldMode { case pushToTalk, dictation }

    private var previous: GestureModifiers = []
    private var activeHold: HoldMode?
    private var controlDownAt: TimeInterval?
    private var lastControlTapAt: TimeInterval?
    private var controlTapWasModified = false

    let doubleTapInterval: TimeInterval
    let maximumTapDuration: TimeInterval

    init(doubleTapInterval: TimeInterval = 0.42, maximumTapDuration: TimeInterval = 0.30) {
        self.doubleTapInterval = doubleTapInterval
        self.maximumTapDuration = maximumTapDuration
    }

    mutating func consume(_ modifiers: GestureModifiers, at time: TimeInterval) -> [HotkeyAction] {
        var actions: [HotkeyAction] = []
        let pttDown = modifiers.contains([.control, .option]) && !modifiers.contains(.function)
        let dictationDown = modifiers.contains([.control, .function]) && !modifiers.contains(.option)

        if activeHold == .pushToTalk, !pttDown {
            activeHold = nil
            actions.append(.pushToTalkEnded)
        } else if activeHold == .dictation, !dictationDown {
            activeHold = nil
            actions.append(.dictationEnded)
        }

        if activeHold == nil, pttDown {
            activeHold = .pushToTalk
            controlTapWasModified = true
            actions.append(.pushToTalkBegan)
        } else if activeHold == nil, dictationDown {
            activeHold = .dictation
            controlTapWasModified = true
            actions.append(.dictationBegan)
        }

        let controlWasDown = previous.contains(.control)
        let controlIsDown = modifiers.contains(.control)
        if !controlWasDown, controlIsDown {
            controlDownAt = time
            controlTapWasModified = modifiers.contains(.option) || modifiers.contains(.function)
        }
        if controlIsDown, modifiers.contains(.option) || modifiers.contains(.function) {
            controlTapWasModified = true
        }
        if controlWasDown, !controlIsDown {
            let duration = time - (controlDownAt ?? time)
            if !controlTapWasModified, duration <= maximumTapDuration {
                if let last = lastControlTapAt, time - last <= doubleTapInterval {
                    actions.append(.typedInputRequested)
                    lastControlTapAt = nil
                } else {
                    lastControlTapAt = time
                }
            } else {
                lastControlTapAt = nil
            }
            controlDownAt = nil
            controlTapWasModified = false
        }

        previous = modifiers
        return actions
    }
}
