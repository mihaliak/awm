import AppKit
import ApplicationServices

@MainActor
final class FocusObserver {
    private var observer: AXObserver?
    private var application: AXUIElement?
    private(set) var pid: pid_t?
    var onChange: (() -> Void)?

    func watch(_ pid: pid_t?) {
        guard self.pid != pid else { return }
        stop()
        guard let pid else { return }
        var value: AXObserver?
        let status = AXObserverCreate(pid, { _, _, _, context in
            guard let context else { return }
            let owner = Unmanaged<FocusObserver>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { owner.onChange?() }
        }, &value)
        guard status == .success, let value else { return }
        let application = AXUIElementCreateApplication(pid)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(value, application, kAXFocusedWindowChangedNotification as CFString,
                                        context) == .success else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(value), .commonModes)
        self.application = application
        observer = value
        self.pid = pid
    }

    func stop() {
        if let observer, let application {
            AXObserverRemoveNotification(observer, application, kAXFocusedWindowChangedNotification as CFString)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        application = nil
        pid = nil
    }
}
