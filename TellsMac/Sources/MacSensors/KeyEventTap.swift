import CoreGraphics
import Foundation
import Synchronization

/// What the tap callback reads from one key event: the type and the autorepeat flag. Nothing else (DEC-12).
struct KeyEvent: Sendable, Equatable {
    let isDown: Bool
    let isAutorepeat: Bool
}

/// A source of key events. The real one is a listen-only event tap. Tests use a fake.
protocol KeyEventSource: Sendable {
    /// Returns false if the system refuses the tap.
    func start(handler: @escaping @Sendable (KeyEvent) -> Void) -> Bool
    func stop()
}

/// A listen-only `CGEvent` tap on key down and key up. It runs on its own thread, not the main thread.
/// The callback never reads the key code, the characters or the modifier flags (hard rule 2).
final class SystemKeyEventSource: KeyEventSource {
    fileprivate final class Context: @unchecked Sendable {
        let handler: @Sendable (KeyEvent) -> Void
        var port: CFMachPort?
        init(handler: @escaping @Sendable (KeyEvent) -> Void) { self.handler = handler }
    }

    private struct LoopHolder: @unchecked Sendable {
        let runLoop: CFRunLoop
        init(_ runLoop: CFRunLoop) { self.runLoop = runLoop }
    }

    private struct Running: @unchecked Sendable {
        let context: Context
        let runLoop: CFRunLoop
        let port: CFMachPort
    }

    private let running = Mutex<Running?>(nil)

    func start(handler: @escaping @Sendable (KeyEvent) -> Void) -> Bool {
        stop()
        let context = Context(handler: handler)
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) // no flagsChanged
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(mask), callback: keyTapCallback,
            userInfo: Unmanaged.passUnretained(context).toOpaque()
        ) else { return false }
        context.port = port

        let ready = DispatchSemaphore(value: 0)
        let loopBox = Mutex<LoopHolder?>(nil)
        let thread = Thread {
            let runLoop = CFRunLoopGetCurrent()
            let source = CFMachPortCreateRunLoopSource(nil, port, 0)
            CFRunLoopAddSource(runLoop, source, .commonModes)
            loopBox.withLock { $0 = LoopHolder(runLoop!) }
            ready.signal()
            CFRunLoopRun()
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        thread.name = "tells.keyboard.tap"
        thread.start()
        ready.wait()
        guard let runLoop = loopBox.withLock({ $0 })?.runLoop else { return false }
        CGEvent.tapEnable(tap: port, enable: true)
        running.withLock { $0 = Running(context: context, runLoop: runLoop, port: port) }
        return true
    }

    func stop() {
        let old = running.withLock { current -> Running? in
            defer { current = nil }
            return current
        }
        guard let old else { return }
        CGEvent.tapEnable(tap: old.port, enable: false)
        CFMachPortInvalidate(old.port)
        CFRunLoopStop(old.runLoop)
    }
}

/// C callback of the tap. It reads only the event type and the autorepeat flag.
private func keyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                            userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let context = Unmanaged<SystemKeyEventSource.Context>.fromOpaque(userInfo).takeUnretainedValue()
    switch type {
    case .keyDown:
        let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        context.handler(KeyEvent(isDown: true, isAutorepeat: repeated))
    case .keyUp:
        context.handler(KeyEvent(isDown: false, isAutorepeat: false))
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let port = context.port { CGEvent.tapEnable(tap: port, enable: true) }
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}
