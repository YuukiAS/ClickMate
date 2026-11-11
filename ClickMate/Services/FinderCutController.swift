import ApplicationServices
import AppKit
@preconcurrency import CoreGraphics

@MainActor
final class FinderCutController {
    private static let finderBundleIdentifier = "com.apple.finder"
    private static let generatedEventMarker: Int64 = 0x434D_4355_54

    private var cutShortcut = KeyboardShortcut.finderCutDefault
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var pasteboardTimer: Timer?
    private var cutSession = FinderCutSession()
    private var pendingCopy: DispatchWorkItem?

    var isRunning: Bool {
        eventTap != nil
    }

    func start(shortcut: KeyboardShortcut) -> Bool {
        stop()
        guard QuickFeaturePermissions.hasAccessibilityAccess else {
            return false
        }

        cutShortcut = shortcut
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        self.eventTap = eventTap
        eventTapSource = source
        startPasteboardMonitoring()
        return true
    }

    func stop() {
        pasteboardTimer?.invalidate()
        pasteboardTimer = nil
        clearCutSession()

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            if let eventTapSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
            }
        }
        eventTapSource = nil
        eventTap = nil
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }
        let controller = Unmanaged<FinderCutController>.fromOpaque(userInfo).takeUnretainedValue()
        return MainActor.assumeIsolated {
            controller.handleEvent(type: type, event: event)
        }
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown,
              event.getIntegerValueField(.eventSourceUserData) != Self.generatedEventMarker
        else {
            return Unmanaged.passUnretained(event)
        }

        let shortcut = KeyboardShortcut(event: event)
        if shortcut == .commandC {
            clearCutSession()
            return Unmanaged.passUnretained(event)
        }

        if shortcut == .commandV,
           hasValidCutSession,
           isFinderReadyForFileCommand {
            postKey(keyCode: KeyboardShortcut.commandV.keyCode, modifiers: [.maskCommand, .maskAlternate])
            observeMoveCompletion()
            return nil
        }

        guard shortcut == cutShortcut,
              isFinderReadyForFileCommand
        else {
            return Unmanaged.passUnretained(event)
        }

        beginCut()
        return nil
    }

    private var isFinderReadyForFileCommand: Bool {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.finderBundleIdentifier else {
            return false
        }
        guard let isTextInput = isFocusedElementTextInput() else {
            return false
        }
        return !isTextInput
    }

    private var hasValidCutSession: Bool {
        cutSession.canMove(pasteboardChangeCount: NSPasteboard.general.changeCount)
    }

    func cutFinderSelection(_ urls: [URL]) {
        guard isRunning, !urls.isEmpty, urls.allSatisfy(\.isFileURL),
              isFinderReadyForFileCommand
        else { return }
        beginCut(expectedURLs: urls)
    }

    private func beginCut(expectedURLs: [URL]? = nil) {
        clearCutSession()
        let originalChangeCount = NSPasteboard.general.changeCount
        postKey(keyCode: KeyboardShortcut.commandC.keyCode, modifiers: .maskCommand)

        let copy = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingCopy = nil
            let pasteboard = NSPasteboard.general
            guard pasteboard.changeCount != originalChangeCount else {
                HUDPresenter.shared.show(message: L10n.string("quickFeatures.cutNoSelection"))
                return
            }
            let urls = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL] ?? []
            guard self.cutSession.recordCopy(
                urls: urls, expectedURLs: expectedURLs, pasteboardChangeCount: pasteboard.changeCount
            ) else {
                HUDPresenter.shared.show(message: L10n.string("quickFeatures.cutNoSelection"))
                return
            }
            HUDPresenter.shared.show(
                message: L10n.string("quickFeatures.cutActivated", urls.count)
            )
        }
        pendingCopy = copy
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: copy)
    }

    private func postKey(keyCode: CGKeyCode, modifiers: CGEventFlags) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            return
        }

        for event in [keyDown, keyUp] {
            event.flags = modifiers
            event.setIntegerValueField(.eventSourceUserData, value: Self.generatedEventMarker)
            event.post(tap: .cghidEventTap)
        }
    }

    private func startPasteboardMonitoring() {
        pasteboardTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cutSession.observePasteboard(changeCount: NSPasteboard.general.changeCount)
            }
        }
    }

    private func observeMoveCompletion() {
        let movedSession = cutSession
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.cutSession == movedSession else { return }
            if NSPasteboard.general.changeCount != movedSession.pasteboardChangeCount
                || movedSession.urls.allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }) {
                self.clearCutSession()
            }
        }
    }

    private func clearCutSession() {
        pendingCopy?.cancel()
        pendingCopy = nil
        cutSession.cancel()
    }

    private func isFocusedElementTextInput() -> Bool? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
              let focusedValue
        else {
            return nil
        }

        let focusedElement = focusedValue as! AXUIElement
        guard let role = accessibilityString(attribute: kAXRoleAttribute, element: focusedElement) else {
            return nil
        }
        let subrole = accessibilityString(attribute: kAXSubroleAttribute, element: focusedElement)
        return role == kAXTextFieldRole as String
            || role == kAXTextAreaRole as String
            || role == kAXComboBoxRole as String
            || subrole == kAXSearchFieldSubrole as String
    }

    private func accessibilityString(attribute: String, element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }
}

private extension KeyboardShortcut {
    static let commandC = KeyboardShortcut(keyCode: 8, modifiers: .command)
    static let commandV = KeyboardShortcut(keyCode: 9, modifiers: .command)

    init(event: CGEvent) {
        keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        modifiers = Modifiers(eventFlags: event.flags)
    }
}

private extension KeyboardShortcut.Modifiers {
    init(eventFlags: CGEventFlags) {
        var modifiers: KeyboardShortcut.Modifiers = []
        if eventFlags.contains(.maskCommand) { modifiers.insert(.command) }
        if eventFlags.contains(.maskControl) { modifiers.insert(.control) }
        if eventFlags.contains(.maskAlternate) { modifiers.insert(.option) }
        if eventFlags.contains(.maskShift) { modifiers.insert(.shift) }
        self = modifiers
    }
}
