import AppKit
@preconcurrency import ApplicationServices

/// AX delivers changes on the main run loop; no window list is read while idle.
@MainActor
final class WindowEvents {
    private struct Subscription {
        let observer: AXObserver
        let application: AXUIElement
        var windows: [AXUIElement] = []
    }
    private var subscriptions: [pid_t: Subscription] = [:]
    var onChange: ((String) -> Void)?
    var applicationCount: Int { subscriptions.count }
    var windowCount: Int { subscriptions.values.reduce(0) { $0 + $1.windows.count } }
    private let applicationNames = [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
                                    kAXMainWindowChangedNotification]
    private let windowNames = [kAXWindowMovedNotification, kAXWindowResizedNotification,
                               kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
                               kAXUIElementDestroyedNotification]

    func refresh(_ applications: [NSRunningApplication]) {
        let pids = Set(applications.filter {
            !$0.isTerminated && $0.activationPolicy == .regular && $0.bundleIdentifier != DockWindowPaths.dockBundleID
        }.map(\.processIdentifier))
        for pid in Array(subscriptions.keys) where !pids.contains(pid) { remove(pid) }
        guard AXIsProcessTrusted() else { stop(); return }
        for pid in pids {
            if subscriptions[pid] == nil {
                var observer: AXObserver?
                let callback: AXObserverCallback = { _, element, name, context in
                    guard let context else { return }
                    MainActor.assumeIsolated {
                        let owner = Unmanaged<WindowEvents>.fromOpaque(context).takeUnretainedValue()
                        owner.received(element: element, name: name as String)
                    }
                }
                guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { continue }
                let application = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(application, 0.15)
                let context = Unmanaged.passUnretained(self).toOpaque()
                for name in applicationNames {
                    _ = AXObserverAddNotification(observer, application, name as CFString, context)
                }
                subscriptions[pid] = Subscription(observer: observer, application: application)
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
            refreshWindows(pid)
        }
    }

    func stop() {
        for pid in Array(subscriptions.keys) { remove(pid) }
    }

    private func received(element: AXUIElement, name: String) {
        if applicationNames.contains(name) || name == kAXUIElementDestroyedNotification {
            var pid: pid_t = 0
            if AXUIElementGetPid(element, &pid) != .success {
                pid = subscriptions.first { $0.value.windows.contains(where: { CFEqual($0, element) }) }?.key ?? 0
            }
            if pid != 0 { refreshWindows(pid) }
        }
        onChange?(name)
    }

    private func refreshWindows(_ pid: pid_t) {
        guard var subscription = subscriptions[pid] else { return }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(subscription.application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        for old in subscription.windows where !windows.contains(where: { CFEqual($0, old) }) {
            for name in windowNames { _ = AXObserverRemoveNotification(subscription.observer, old, name as CFString) }
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        for window in windows where !subscription.windows.contains(where: { CFEqual($0, window) }) {
            AXUIElementSetMessagingTimeout(window, 0.15)
            for name in windowNames {
                _ = AXObserverAddNotification(subscription.observer, window, name as CFString, context)
            }
        }
        subscription.windows = windows
        subscriptions[pid] = subscription
    }

    private func remove(_ pid: pid_t) {
        guard let subscription = subscriptions.removeValue(forKey: pid) else { return }
        for window in subscription.windows {
            for name in windowNames { _ = AXObserverRemoveNotification(subscription.observer, window, name as CFString) }
        }
        for name in applicationNames {
            _ = AXObserverRemoveNotification(subscription.observer, subscription.application, name as CFString)
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(subscription.observer), .commonModes)
    }
}
