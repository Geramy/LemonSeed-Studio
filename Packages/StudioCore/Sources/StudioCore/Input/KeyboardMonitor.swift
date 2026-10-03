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

    public init(override: Bool? = nil) {
        self.override = override
        self.hasHardwareKeyboard = override ?? (GCKeyboard.coalesced != nil)
        let center = NotificationCenter.default
        for name in [Notification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            })
        }
        #if canImport(UIKit)
        observers.append(center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
            let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
            MainActor.assumeIsolated { self?.keyboardFrameChanged(frame) }
        })
        observers.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyboardFrameChanged(.zero) }
        })
        observers.append(center.addObserver(forName: UIResponder.keyboardDidShowNotification, object: nil, queue: .main) { [weak self] note in
            let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
            MainActor.assumeIsolated { self?.keyboardFrameChanged(frame) }
        })
        #endif
    }

    private func update() {
        hasHardwareKeyboard = override ?? (GCKeyboard.coalesced != nil)
    }

    #if canImport(UIKit)
    private func keyboardFrameChanged(_ frame: CGRect) {
        // With a hardware keyboard the "keyboard" is only the shortcuts bar;
        // count it as visible only when it is a real keyboard's height.
        let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first?.bounds
            ?? CGRect(x: 0, y: 0, width: 1024, height: 1366)
        let onScreen = frame.intersection(screen)
        let visible = !onScreen.isNull && onScreen.height > 120
        isSoftwareKeyboardVisible = visible
        responderHasAccessory = visible && UIResponder.currentFirstResponder?.inputAccessoryView != nil
        softwareKeyboardHeight = visible && onScreen.maxY >= screen.maxY - 1 ? onScreen.height : 0
    }
    #endif
}
