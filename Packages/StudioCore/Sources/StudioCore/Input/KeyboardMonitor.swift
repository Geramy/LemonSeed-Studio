import Foundation
import Observation
import GameController
#if canImport(UIKit)
import UIKit
#endif

/// Whether a hardware keyboard (USB, Bluetooth, Magic Keyboard, Smart
/// Keyboard) is attached, and whether the on-screen keyboard is showing.
///
/// Hardware detection uses GameController's `GCKeyboard.coalesced` and its
/// connect/disconnect notifications. The on-screen keyboard is tracked
/// through UIKit's keyboard frame notifications.
@MainActor
@Observable
public final class KeyboardMonitor {
    public static let shared = KeyboardMonitor()

    /// A hardware keyboard is attached.
    public private(set) var hasHardwareKeyboard: Bool
    /// The on-screen keyboard is on screen (docked, floating or split).
    public private(set) var isSoftwareKeyboardVisible = false
    /// Its height when docked (0 when floating or hidden).
    public private(set) var softwareKeyboardHeight: CGFloat = 0
    /// The focused text view brings its own accessory row (SwiftTerm's, or
    /// a view using `ProgrammerKeyBar.makeInputAccessoryView`), so the
    /// shell's floating key bar should stay hidden.
    public private(set) var responderHasAccessory = false

    /// Forces the hardware state (tests and automation); nil follows the device.
    public var override: Bool? {
        didSet { update() }
    }

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// The full on-screen keyboard appeared, so nothing is attached even if
    /// GameController still lists a keyboard (the simulator lists the
    /// Mac's keyboard while "Connect Hardware Keyboard" is off). Cleared
    /// when GameController reports a new connection.
    @ObservationIgnored private var sawOnScreenKeyboard = false
    @ObservationIgnored private var simulatorPoll: Timer?

    /// In the simulator GameController always lists the Mac's keyboard, so
    /// simulator builds read the simulator's own "Connect Hardware Keyboard"
    /// setting for this device. nil on devices, or when the setting is unset.
    static func simulatorSetting() -> Bool? {
        #if targetEnvironment(simulator)
        let environment = ProcessInfo.processInfo.environment
        guard let home = environment["SIMULATOR_HOST_HOME"], let udid = environment["SIMULATOR_UDID"] else { return nil }
        let url = URL(fileURLWithPath: home).appendingPathComponent("Library/Preferences/com.apple.iphonesimulator.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let devices = plist["DevicePreferences"] as? [String: Any],
              let device = devices[udid] as? [String: Any] else { return nil }
        return device["ConnectHardwareKeyboard"] as? Bool
        #else
        return nil
        #endif
    }

    public init(override: Bool? = nil) {
        self.override = override
        self.hasHardwareKeyboard = override ?? Self.simulatorSetting() ?? (GCKeyboard.coalesced != nil)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sawOnScreenKeyboard = false
                self?.update()
            }
        })
        observers.append(center.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        })
        #if targetEnvironment(simulator)
        // The simulator's I/O › Keyboard › Connect Hardware Keyboard can
        // change at any time without a GameController notification.
        simulatorPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        #endif
        #if canImport(UIKit)
        observers.append(center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
            let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
            MainActor.assumeIsolated { self?.keyboardFrameChanged(frame) }
        })
        observers.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyboardFrameChanged(.zero) }
        })
        // The did-notifications are authoritative: reloading an accessory
        // view sends will-hide and will-show in quick succession.
        for name in [UIResponder.keyboardDidShowNotification, UIResponder.keyboardDidChangeFrameNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
                MainActor.assumeIsolated { self?.keyboardFrameChanged(frame) }
            })
        }
        observers.append(center.addObserver(forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyboardFrameChanged(.zero) }
        })
        #endif
    }

    private func update() {
        let detected = override ?? Self.simulatorSetting() ?? (GCKeyboard.coalesced != nil && !sawOnScreenKeyboard)
        if hasHardwareKeyboard != detected { hasHardwareKeyboard = detected }
    }

    #if canImport(UIKit)
    /// The first responder, or the view that owns it (Runestone-based
    /// editors make an inner input view first responder while the text view
    /// carries the accessory), supplies an inputAccessoryView.
    static func focusedViewHasAccessory() -> Bool {
        var responder = UIResponder.currentFirstResponder
        for _ in 0..<4 {
            guard let current = responder else { return false }
            if current.inputAccessoryView != nil { return true }
            responder = current.next
        }
        return false
    }

    private func keyboardFrameChanged(_ frame: CGRect) {
        // With a hardware keyboard the "keyboard" is only the shortcuts bar;
        // count it as visible only when it is a real keyboard's height.
        let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first?.bounds
            ?? CGRect(x: 0, y: 0, width: 1024, height: 1366)
        let onScreen = frame.intersection(screen)
        let visible = !onScreen.isNull && onScreen.height > 120
        isSoftwareKeyboardVisible = visible
        if visible, !sawOnScreenKeyboard {
            sawOnScreenKeyboard = true
            update()
        }
        responderHasAccessory = visible && Self.focusedViewHasAccessory()
        softwareKeyboardHeight = visible && onScreen.maxY >= screen.maxY - 1 ? onScreen.height : 0
    }
    #endif
}
