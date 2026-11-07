import AppKit
@preconcurrency import ApplicationServices
import JavaScriptCore

struct OnscreenWindow: Sendable {
    let windowID: CGWindowID
    let processID: pid_t
    let frame: CGRect
}

private enum PointerPhase: Sendable { case down, drag, up }
private struct PointerStart: Sendable {
    let processID: pid_t
    let frame: CGRect
}

private struct ScanOutcome: Sendable {
    var code = "watching"
    var suppressDock = false
    var adjusted = 0
    var policyVersion = "unloaded"
    var traces: [WindowAdjustmentTrace] = []
    var manualWindows = 0
    var managedWindows = 0
    var nativeFullscreen = false
    var manualWindowDetails: [WindowManualPlacement] = []
    var retryAfter: TimeInterval? = nil
}

@MainActor
private final class WindowHelperController: NSObject, NSApplicationDelegate {
    private let worker = WindowAccess()
    private let directoryEvents = DirectoryEvents()
    private let windowEvents = WindowEvents()
    private var healthTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var screenObserver: NSObjectProtocol?
    private var packet: DockWindowPacket?
    private var lastPacketData: Data?
    private var processedCommands = Set<String>()
    private var lastSession = ""
    private var lastAlive = Date.timeIntervalSinceReferenceDate
    private var lastStatusWrite: TimeInterval = 0
    private var lastStatusFingerprint = ""
    private var outcome = ScanOutcome()
    private var lastTrusted = false
    private var observing = false
    private var stopping = false
    private var pointerMonitor: Any?
    private var pointerActive = false
    private var settleUntil = Date.distantPast
    private var inputTail: Task<Void, Never>?
    private var lastQueuedDrag = Date.distantPast
    private var scanTask: Task<Void, Never>?
    private var scheduledRevision = 0
    private var scanning = false
    private var pendingScan = false
    private var retryBudget = 0
    private var scanCount = 0
    private var lastScanReason = "startup"
    private var transitionTasks: [Task<Void, Never>] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? DockWindowPaths.prepareDirectory()
        windowEvents.onChange = { [weak self] reason in self?.requestScan(reason: reason) }
        directoryEvents.start(at: DockWindowPaths.directory) { [weak self] in self?.receivePacket() }
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.observePointer(event) }
        }
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didWakeNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.workspaceChanged() }
            })
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.workspaceChanged() } }
        let timer = Timer(timeInterval: DockWindowPaths.heartbeatInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.healthCheck() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
        receivePacket()
        healthCheck()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopping = true
        healthTimer?.invalidate()
        scanTask?.cancel()
        transitionTasks.forEach { $0.cancel() }
        directoryEvents.stop()
        windowEvents.stop()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
    }

    private func refreshObservation() {
        let wanted = packet?.geometry != nil && AXIsProcessTrusted()
        if wanted {
            windowEvents.refresh(NSWorkspace.shared.runningApplications)
        } else if observing {
            windowEvents.stop()
        }
        observing = wanted
    }

    private func workspaceChanged() {
        guard !stopping else { return }
        refreshObservation()
        requestScan(reason: "workspace")
        // Launch and native Space transitions can publish their final AX state late.
        // These are bounded follow-ups to an event, never an idle scan loop.
        transitionTasks.forEach { $0.cancel() }
        transitionTasks = [0.4, 1.0].map { delay in
            Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard let self, !self.stopping else { return }
                self.refreshObservation()
                self.requestScan(reason: "workspaceSettled")
            }
        }
    }

    private func observePointer(_ event: NSEvent) {
        guard packet?.enabled == true, packet?.geometry != nil, AXIsProcessTrusted() else { return }
        let phase: PointerPhase
        switch event.type {
        case .leftMouseDown: phase = .down; pointerActive = true
        case .leftMouseDragged:
            guard Date().timeIntervalSince(lastQueuedDrag) >= 0.04 else { return }
            lastQueuedDrag = Date(); phase = .drag
        case .leftMouseUp: phase = .up; pointerActive = false; settleUntil = Date().addingTimeInterval(0.3)
        default: return
        }
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let point = event.cgEvent?.location ?? CGPoint(x: NSEvent.mouseLocation.x, y: primaryTop - NSEvent.mouseLocation.y)
        let allowed = Set(NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.bundleIdentifier != DockWindowPaths.dockBundleID
        }.map(\.processIdentifier))
        var start: PointerStart?
        if phase == .down {
            let windows = onscreenWindows(regularPIDs: allowed)
            let targetID = CGWindowID(truncatingIfNeeded: event.cgEvent?.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent) ?? 0)
            let selected = windows.first(where: { targetID != 0 && $0.windowID == targetID })
                ?? windows.first(where: { $0.frame.insetBy(dx: -8, dy: -8).contains(point) })
            start = selected.map { PointerStart(processID: $0.processID, frame: $0.frame) }
            outcome.code = "userInteracting"
            writeStatus(force: false)
        }
        let previous = inputTail, worker = self.worker
        inputTail = Task { await previous?.value; await worker.pointer(phase, point: point, primaryTop: primaryTop, allowed: allowed, start: start) }
        if phase == .up { requestScan(reason: "pointerReleased", after: 0.35) }
    }

    private func loadPacket() -> (DockWindowPacket, Data)? {
        guard let data = try? Data(contentsOf: DockWindowPaths.geometry), data.count <= 65_536,
              let packet = try? JSONDecoder().decode(DockWindowPacket.self, from: data),
              packet.schemaVersion == 1, Date.timeIntervalSinceReferenceDate - packet.timestamp < DockWindowPaths.freshnessInterval,
              let application = NSRunningApplication(processIdentifier: packet.processID), !application.isTerminated,
              application.bundleIdentifier == DockWindowPaths.dockBundleID else { return nil }
        if let geometry = packet.geometry {
            guard geometry.screen.isValid, geometry.available.isValid, geometry.dock.isValid,
                  geometry.available.cgRect.intersects(geometry.screen.cgRect),
                  geometry.dock.cgRect.intersects(geometry.screen.cgRect) else { return nil }
        }
        return (packet, data)
    }

    private func receivePacket() {
        guard !stopping else { return }
        guard let (next, data) = loadPacket() else {
            packet = nil
            outcome = ScanOutcome(code: "dockStopped")
            refreshObservation()
            writeStatus(force: false)
            return
        }
        lastAlive = Date.timeIntervalSinceReferenceDate
        guard data != lastPacketData else { return }
        lastPacketData = data
        let previous = packet
        packet = next
        if lastSession != next.session {
            lastSession = next.session
            processedCommands.removeAll()
        }
        processedCommands.formIntersection(Set(next.commands.map(\.id)))
        for command in next.commands where command.action == .authorize && !processedCommands.contains(command.id)
            && Date.timeIntervalSinceReferenceDate - command.timestamp < 3 {
            processedCommands.insert(command.id)
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        let trusted = AXIsProcessTrusted()
        if trusted != lastTrusted || (previous?.geometry == nil) != (next.geometry == nil) {
            lastTrusted = trusted
            refreshObservation()
        }
        guard trusted else {
            outcome = ScanOutcome(code: "permissionRequired")
            writeStatus(force: false)
            return
        }
        // Heartbeat timestamps keep the connection alive without requesting a scan.
        let changed = previous?.session != next.session || previous?.geometry != next.geometry
            || previous?.enabled != next.enabled || previous?.dockResizing != next.dockResizing
        let newCommand = next.commands.contains { !processedCommands.contains($0.id) }
        if next.geometry == nil && !newCommand {
            outcome = ScanOutcome(code: "disabled")
            writeStatus(force: false)
            return
        }
        if changed || newCommand { requestScan(reason: newCommand ? "command" : "dockGeometry", after: 0.02) }
    }

    private func healthCheck() {
        receivePacket()
        guard !stopping else { return }
        if Date.timeIntervalSinceReferenceDate - lastAlive > 30 { NSApplication.shared.terminate(nil); return }
        let trusted = AXIsProcessTrusted()
        if trusted != lastTrusted {
            lastTrusted = trusted
            refreshObservation()
            if trusted { requestScan(reason: "permissionGranted") }
            else { outcome = ScanOutcome(code: "permissionRequired") }
        }
        if pointerActive, NSEvent.pressedMouseButtons & 1 == 0 {
            pointerActive = false
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            let point = CGPoint(x: NSEvent.mouseLocation.x, y: top - NSEvent.mouseLocation.y)
            let previous = inputTail, worker = self.worker
            inputTail = Task { await previous?.value; await worker.pointer(.up, point: point, primaryTop: top, allowed: []) }
            settleUntil = Date().addingTimeInterval(0.3)
            requestScan(reason: "pointerRecovery", after: 0.35)
        }
        writeStatus(force: false)
    }

    private func requestScan(reason: String, after delay: TimeInterval = 0.12, retry: Bool = false) {
        guard !stopping, let packet, AXIsProcessTrusted(),
              packet.geometry != nil || packet.commands.contains(where: { !processedCommands.contains($0.id) }) else { return }
        if retry {
            guard retryBudget > 0 else { return }
            retryBudget -= 1
        } else {
            retryBudget = 4
        }
        pendingScan = true
        lastScanReason = reason
        scanTask?.cancel()
        scheduledRevision += 1
        let revision = scheduledRevision
        scanTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0.01, delay))) } catch { return }
            guard let self, !self.stopping, self.scheduledRevision == revision else { return }
            self.scanTask = nil
            self.performScan()
        }
    }

    private func performScan() {
        guard pendingScan, let packet, !scanning else { return }
        guard packet.dockResizing != true, !pointerActive else { return }
        if Date() < settleUntil {
            requestScan(reason: "pointerSettled", after: settleUntil.timeIntervalSinceNow + 0.02, retry: true)
            return
        }
        pendingScan = false
        let now = Date.timeIntervalSinceReferenceDate
        let commands = packet.commands.filter { now - $0.timestamp < 3 && !processedCommands.contains($0.id) }
        for command in commands { processedCommands.insert(command.id) }
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let regularPIDs = Set(NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.bundleIdentifier != DockWindowPaths.dockBundleID
        }.map(\.processIdentifier))
        let windows = onscreenWindows(regularPIDs: regularPIDs)
        scanning = true
        scanCount += 1
        let inputTail = self.inputTail
        Task { [weak self] in
            guard let self else { return }
            await inputTail?.value
            let mayMove: @MainActor @Sendable () -> Bool = { [weak self] in
                guard let self, let current = self.packet, !self.stopping else { return false }
                let sameArea = current.geometry?.screen == packet.geometry?.screen
                    && current.geometry?.available == packet.geometry?.available
                    && abs((current.geometry?.dock.cgRect.maxY ?? 0) - (packet.geometry?.dock.cgRect.maxY ?? 0)) < 1
                return current.session == packet.session && sameArea && current.enabled == packet.enabled
                    && current.dockResizing != true && !self.pointerActive && Date() >= self.settleUntil
                    && Date.timeIntervalSinceReferenceDate - current.timestamp < DockWindowPaths.freshnessInterval
                    && NSEvent.pressedMouseButtons & 1 == 0
            }
            let updated = await worker.scan(packet: packet, windows: windows, primaryTop: primaryTop,
                frontmost: frontmost, commands: commands, mayMove: mayMove)
            self.scanning = false
            guard !self.stopping else { return }
            if self.packet?.session == packet.session, self.packet?.dockResizing != true,
               !self.pointerActive, Date() >= self.settleUntil {
                self.outcome = updated
                self.writeStatus(force: true)
            }
            if self.pendingScan { self.requestScan(reason: self.lastScanReason, after: 0.06, retry: true) }
            else if let delay = updated.retryAfter { self.requestScan(reason: "layoutSettled", after: delay, retry: true) }
        }
    }

    private func onscreenWindows(regularPIDs: Set<pid_t>) -> [OnscreenWindow] {
        guard let values = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        return values.compactMap { value in
            guard (value[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (value[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let pid = (value[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  regularPIDs.contains(pid), let bounds = value[kCGWindowBounds as String] as? [String: CGFloat],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), frame.width >= 80, frame.height >= 80 else { return nil }
            return OnscreenWindow(windowID: (value[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0, processID: pid, frame: frame)
        }
    }

    private func writeStatus(force: Bool) {
        let now = Date.timeIntervalSinceReferenceDate
        let fingerprint = "\(packet?.session ?? lastSession)|\(AXIsProcessTrusted())|\(outcome.code)|\(outcome.suppressDock)|\(outcome.policyVersion)"
        guard force || fingerprint != lastStatusFingerprint || now - lastStatusWrite >= DockWindowPaths.heartbeatInterval else { return }
        var status = DockWindowStatus(schemaVersion: 1, session: packet?.session ?? lastSession,
            timestamp: now, trusted: AXIsProcessTrusted(), code: outcome.code,
            suppressDock: outcome.suppressDock, adjustedWindows: outcome.adjusted, policyVersion: outcome.policyVersion)
        status.diagnostics = outcome.traces
        status.manualWindows = outcome.manualWindows
        status.managedWindows = outcome.managedWindows
        status.nativeFullscreen = outcome.nativeFullscreen
        status.manualWindowDetails = outcome.manualWindowDetails
        status.monitoringMode = "events"
        status.scanCount = scanCount
        status.observedApplications = windowEvents.applicationCount
        status.observedWindows = windowEvents.windowCount
        status.lastScanReason = lastScanReason
        try? DockWindowPaths.write(status, to: DockWindowPaths.status)
        lastStatusWrite = now
        lastStatusFingerprint = fingerprint
    }
}

private actor WindowAccess {
    private struct Window {
        let element: AXUIElement
        let frame: CGRect
        let minimized: Bool
        let fullScreen: Bool
        let standard: Bool
    }

    private struct Record {
        let processID: pid_t
        let element: AXUIElement
        var intent = WindowIntent()
        var geometry: DockWindowGeometry?
        var stableSince: TimeInterval
        var seenAt: TimeInterval
        var blocked = false
        var attempts = 0
        var retryAt: TimeInterval = 0
    }

    private struct Gesture {
        let processID: pid_t
        let element: AXUIElement
        let initial: CGRect
        let startPoint: CGPoint
        var dragged = false
        var changed = false
    }
    private var gesture: Gesture?
    private var pendingManual: (gesture: Gesture, pointerTravel: CGFloat)?
    private var interactionEpoch = 0

    func pointer(_ phase: PointerPhase, point: CGPoint, primaryTop: CGFloat, allowed: Set<pid_t>, start: PointerStart? = nil) {
        switch phase {
        case .down:
            interactionEpoch += 1
            gesture = nil
            let system = AXUIElementCreateSystemWide()
            var hit: AXUIElement?
            var element: AXUIElement?
            if AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let hit {
                let role = attribute(kAXRoleAttribute, on: hit) as? String
                element = role == kAXWindowRole ? hit : attribute(kAXWindowAttribute, on: hit).flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? unsafeBitCast($0, to: AXUIElement.self) : nil }
            }
            var pid: pid_t = 0
            if let found = element { _ = AXUIElementGetPid(found, &pid) }
            if element == nil || !allowed.contains(pid) || (start != nil && start?.processID != pid) {
                guard let start else { return }
                pid = start.processID
                let candidates = records.filter { $0.processID == pid && $0.intent.observed.map { near($0, fromAX(start.frame, primaryTop: primaryTop), tolerance: 3) } == true }
                if candidates.count == 1 { element = candidates[0].element }
                else if let focused = focusedWindow(pid: pid), candidates.isEmpty || candidates.contains(where: { CFEqual($0.element, focused.element) }) { element = focused.element }
                else { return }
            }
            guard let element, let window = snapshot(element), allowed.contains(pid) else { return }
            gesture = Gesture(processID: pid, element: element, initial: start?.frame ?? window.frame, startPoint: point)
        case .drag:
            guard var current = gesture else { return }
            current.dragged = true
            if !current.changed, let window = snapshot(current.element) { current.changed = !near(window.frame, current.initial) }
            gesture = current
        case .up:
            interactionEpoch += 1
            guard let current = gesture else { return }
            gesture = nil
            let travel = hypot(point.x - current.startPoint.x, point.y - current.startPoint.y)
            pendingManual = (current, travel)
            markManual(current, pointerTravel: travel, primaryTop: primaryTop)
        }
    }

    private func markManual(_ current: Gesture, pointerTravel: CGFloat, primaryTop: CGFloat) {
        guard let window = snapshot(current.element), WindowIntent.isManualDrag(initial: current.initial, final: window.frame,
            dragged: current.dragged, changedDuringDrag: current.changed, pointerTravel: pointerTravel) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var record = records.first { $0.processID == current.processID && CFEqual($0.element, current.element) }
            ?? Record(processID: current.processID, element: current.element, stableSince: now, seenAt: now)
        record.intent.userDragged(to: fromAX(window.frame, primaryTop: primaryTop))
        record.blocked = false; record.attempts = 0; record.seenAt = now
        save(record)
    }

    private var records: [Record] = []
    private var context: JSContext?
    private var policyDate: Date?
    private var policyVersion = "unloaded"
    private var recentTraces: [WindowAdjustmentTrace] = []
    private struct PlanKey: Hashable {
        let window: WindowRect
        let screen: WindowRect
        let available: WindowRect
        let dockTop: CGFloat
    }
    private struct CachedPlan { let rect: CGRect? }
    private var plans: [PlanKey: CachedPlan] = [:]

    private struct Applied {
        let success: Bool
        let deferred: Bool
        let reason: String
    }

    func scan(packet: DockWindowPacket, windows: [OnscreenWindow], primaryTop: CGFloat,
              frontmost: pid_t?, commands: [DockWindowCommand],
              mayMove: @MainActor @Sendable () -> Bool) async -> ScanOutcome {
        var outcome = ScanOutcome()
        outcome.traces = recentTraces
        guard loadPolicy() else { return ScanOutcome(code: "layoutScriptUnavailable") }
        outcome.policyVersion = policyVersion
        // Read again after the mouse-up settling period, before classification.
        // The target application's final AX frame can arrive after mouse-up.
        if let pending = pendingManual {
            pendingManual = nil
            markManual(pending.gesture, pointerTravel: pending.pointerTravel, primaryTop: primaryTop)
        }
        for command in commands {
            if command.action == .restore, let pid = command.processID {
                if await mayMove() { restoreMinimizedWindow(pid: pid) }
            } else if command.action == .maximize, let pid = frontmost,
                      command.processID == nil || command.processID == pid, let geometry = packet.geometry,
                      let focused = focusedWindow(pid: pid), !focused.fullScreen,
                      let safe = safeArea(geometry), await mayMove() {
                let target = toAX(safe, primaryTop: primaryTop)
                if await apply(target, to: focused, mayMove: mayMove).success {
                    outcome.adjusted += 1
                    let now = ProcessInfo.processInfo.systemUptime
                    var record = Record(processID: pid, element: focused.element, geometry: geometry, stableSince: now, seenAt: now)
                    record.intent.applied(source: geometry.available.cgRect, target: fromAX(target, primaryTop: primaryTop), actual: fromAX(target, primaryTop: primaryTop))
                    save(record)
                }
            }
        }
        // Fullscreen visibility is independent of the automatic-resize switch.
        if packet.geometry != nil, frontmost.map({ focusedWindow(pid: $0)?.fullScreen == true }) == true {
            outcome.code = "fullScreen"
            outcome.suppressDock = true
            outcome.nativeFullscreen = true
            return outcome
        }
        guard packet.enabled, let geometry = packet.geometry else {
            outcome.code = "disabled"
            return outcome
        }

        let now = ProcessInfo.processInfo.systemUptime
        records.removeAll { now - $0.seenAt > 86400 }
        let pids = Set(windows.map(\.processID))
        for pid in pids {
            let visible = windows.filter { $0.processID == pid }
            for window in applicationWindows(pid: pid) where window.standard && !window.minimized && !window.fullScreen {
                guard visible.contains(where: { near($0.frame, window.frame, tolerance: 3) }) else { continue }
                let cocoa = fromAX(window.frame, primaryTop: primaryTop)
                var record = records.first { $0.processID == pid && CFEqual($0.element, window.element) }
                    ?? Record(processID: pid, element: window.element, stableSince: now, seenAt: now)
                let previous = record.intent.observed
                let native = nativeSource(cocoa, geometry: geometry)
                let source = record.intent.resolve(frame: cocoa, nativeSource: native)
                record.seenAt = now
                guard let source else {
                    record.blocked = false; record.attempts = 0
                    save(record); continue
                }
                guard let planned = adjustment(source, geometry: geometry) else { save(record); continue }
                let target = toAX(planned, primaryTop: primaryTop)
                if near(window.frame, target) {
                    record.intent.applied(source: source, target: planned, actual: cocoa)
                    record.geometry = geometry; record.blocked = false; record.attempts = 0
                    save(record); continue
                }
                if record.geometry != geometry {
                    record.blocked = false; record.attempts = 0; record.retryAt = 0
                }
                if let previous, !near(previous, cocoa) { record.stableSince = now }
                if record.blocked {
                    if intersectsDock(cocoa, geometry: geometry) { outcome.suppressDock = true; outcome.code = "windowSizeConstrained" }
                    save(record); continue
                }
                record.geometry = geometry
                guard now - record.stableSince >= 0.10, now >= record.retryAt else {
                    outcome.retryAfter = 0.12
                    save(record); continue
                }
                guard await mayMove() else { save(record); continue }
                let epoch = interactionEpoch
                let applied = await apply(target, to: window, mayMove: mayMove)
                guard epoch == interactionEpoch else { continue }
                if let latest = snapshot(window.element) {
                    let actual = fromAX(latest.frame, primaryTop: primaryTop)
                    record.intent.applied(source: source, target: planned, actual: actual)
                    if !applied.deferred { record.attempts += 1 }
                    record.retryAt = ProcessInfo.processInfo.systemUptime + 0.18
                    record.blocked = !near(latest.frame, target) && !applied.deferred && record.attempts >= 3
                    if !applied.success && !record.blocked { outcome.retryAfter = 0.2 }
                    if record.blocked && intersectsDock(actual, geometry: geometry) { outcome.suppressDock = true; outcome.code = "windowSizeConstrained" }
                    recentTraces.append(WindowAdjustmentTrace(processID: pid, source: WindowRect(source), target: WindowRect(planned), actual: WindowRect(actual), result: applied.reason))
                    recentTraces = Array(recentTraces.suffix(8))
                }
                save(record)
                if applied.success { outcome.adjusted += 1 }
                else if !outcome.suppressDock { outcome.code = "adjustmentPending" }
            }
        }
        outcome.manualWindows = records.filter { $0.intent.manuallyPlaced }.count
        outcome.managedWindows = records.filter { $0.intent.source != nil && !$0.intent.manuallyPlaced }.count
        outcome.manualWindowDetails = records.filter { $0.intent.manuallyPlaced }.compactMap { record in
            record.intent.observed.map { WindowManualPlacement(processID: record.processID, frame: WindowRect($0)) }
        }
        if outcome.adjusted > 0 && !outcome.suppressDock { outcome.code = "adjusted" }
        outcome.traces = recentTraces
        return outcome
    }

    private func save(_ record: Record) {
        if let index = records.firstIndex(where: { $0.processID == record.processID && CFEqual($0.element, record.element) }) {
            records[index] = record
        } else { records.append(record) }
    }

    private func loadPolicy() -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: DockWindowPaths.policy.path),
              let modified = attributes[.modificationDate] as? Date else { return false }
        if modified == policyDate, context != nil { return true }
        guard let data = try? Data(contentsOf: DockWindowPaths.policy), data.count < 262_144,
              let script = String(data: data, encoding: .utf8), let context = JSContext() else { return false }
        context.evaluateScript(script, withSourceURL: DockWindowPaths.policy)
        guard context.exception == nil, let layout = context.objectForKeyedSubscript("DockLayout"),
              layout.hasProperty("adjust"), layout.hasProperty("classify"), let version = layout.objectForKeyedSubscript("version")?.toString() else { return false }
        self.context = context
        policyDate = modified
        policyVersion = version
        plans.removeAll()
        return true
    }

    private func object<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func safeArea(_ geometry: DockWindowGeometry) -> CGRect? {
        guard let input = object(geometry), let value = context?.objectForKeyedSubscript("DockLayout")?
                .invokeMethod("safeArea", withArguments: [input])?.toDictionary() else { return nil }
        return rect(value)
    }

    private func nativeSource(_ window: CGRect, geometry: DockWindowGeometry) -> CGRect? {
        guard let input = object(WindowRect(window)), let area = object(geometry),
              let value = context?.objectForKeyedSubscript("DockLayout")?.invokeMethod("classify", withArguments: [input, area]),
              !value.isNull, !value.isUndefined,
              let source = value.objectForKeyedSubscript("source")?.toDictionary() else { return nil }
        return rect(source)
    }

    private func adjustment(_ window: CGRect, geometry: DockWindowGeometry) -> CGRect? {
        let key = PlanKey(window: WindowRect(window), screen: geometry.screen,
                          available: geometry.available, dockTop: geometry.dock.cgRect.maxY)
        if let plan = plans[key] { return plan.rect }
        let result = computeAdjustment(window, geometry: geometry)
        if plans.count > 512 { plans.removeAll(keepingCapacity: true) }
        plans[key] = CachedPlan(rect: result)
        return result
    }

    private func computeAdjustment(_ window: CGRect, geometry: DockWindowGeometry) -> CGRect? {
        guard let input = object(WindowRect(window)), let geometryObject = object(geometry),
              let result = context?.objectForKeyedSubscript("DockLayout")?
                .invokeMethod("adjust", withArguments: [input, geometryObject]), !result.isNull, !result.isUndefined,
              let value = result.objectForKeyedSubscript("rect")?.toDictionary(), let target = rect(value),
              let safe = safeArea(geometry), target.minY >= safe.minY - 1,
              target.maxY <= safe.maxY + 1, abs(target.minX - window.minX) <= 1,
              abs(target.width - window.width) <= 1 else { return nil }
        return target
    }

    private func rect(_ value: [AnyHashable: Any]) -> CGRect? {
        guard let x = value["x"] as? Double, let y = value["y"] as? Double,
              let width = value["width"] as? Double, let height = value["height"] as? Double,
              [x, y, width, height].allSatisfy(\.isFinite), width >= 80, height >= 80 else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func intersectsDock(_ window: CGRect, geometry: DockWindowGeometry) -> Bool {
        window.intersects(geometry.dock.cgRect)
    }

    private func fromAX(_ frame: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryTop - frame.maxY, width: frame.width, height: frame.height)
    }

    private func toAX(_ frame: CGRect, primaryTop: CGFloat) -> CGRect { fromAX(frame, primaryTop: primaryTop) }

    private func near(_ first: CGRect, _ second: CGRect, tolerance: CGFloat = 1) -> Bool {
        abs(first.minX - second.minX) <= tolerance && abs(first.minY - second.minY) <= tolerance
            && abs(first.width - second.width) <= tolerance && abs(first.height - second.height) <= tolerance
    }

    private func appElement(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        return app
    }

    private func applicationWindows(pid: pid_t) -> [Window] {
        let app = appElement(pid)
        guard let values = attribute(kAXWindowsAttribute, on: app) as? [AXUIElement] else { return [] }
        return values.compactMap(snapshot)
    }

    private func focusedWindow(pid: pid_t) -> Window? {
        let app = appElement(pid)
        for name in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let value = attribute(name, on: app), CFGetTypeID(value) == AXUIElementGetTypeID(),
               let window = snapshot(value as! AXUIElement) { return window }
        }
        return nil
    }

    private func snapshot(_ element: AXUIElement) -> Window? {
        AXUIElementSetMessagingTimeout(element, 0.15)
        var position = CGPoint.zero, size = CGSize.zero
        guard let origin = attribute(kAXPositionAttribute, on: element), CFGetTypeID(origin) == AXValueGetTypeID(),
              let dimensions = attribute(kAXSizeAttribute, on: element), CFGetTypeID(dimensions) == AXValueGetTypeID(),
              AXValueGetValue(origin as! AXValue, .cgPoint, &position),
              AXValueGetValue(dimensions as! AXValue, .cgSize, &size) else { return nil }
        let subrole = attribute(kAXSubroleAttribute, on: element) as? String
        let role = attribute(kAXRoleAttribute, on: element) as? String
        return Window(element: element, frame: CGRect(origin: position, size: size),
                      minimized: attribute(kAXMinimizedAttribute, on: element) as? Bool == true,
                      fullScreen: attribute("AXFullScreen", on: element) as? Bool == true,
                      standard: (role == nil || role == kAXWindowRole) && (subrole == nil || subrole == kAXStandardWindowSubrole))
    }

    private func apply(_ target: CGRect, to original: Window, mayMove: @MainActor @Sendable () -> Bool) async -> Applied {
        guard !original.fullScreen, !original.minimized, target.width >= 80, target.height >= 80,
              let current = snapshot(original.element), near(current.frame, original.frame), await mayMove() else {
            return Applied(success: false, deferred: true, reason: "deferredBeforeResize")
        }
        if abs(current.frame.width - target.width) > 1 || abs(current.frame.height - target.height) > 1 {
            var size = target.size
            guard settable(kAXSizeAttribute, on: original.element), let value = AXValueCreate(.cgSize, &size) else {
                return Applied(success: false, deferred: false, reason: "sizeNotSettable")
            }
            let error = AXUIElementSetAttributeValue(original.element, kAXSizeAttribute as CFString, value)
            guard error == .success else { return Applied(success: false, deferred: false, reason: "sizeWrite.\(error.rawValue)") }
            for _ in 0..<20 {
                guard await mayMove(), let updated = snapshot(original.element), !updated.fullScreen, !updated.minimized else {
                    return Applied(success: false, deferred: true, reason: "windowChangedDuringResize")
                }
                if abs(updated.frame.width - target.width) <= 1 && abs(updated.frame.height - target.height) <= 1 { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        guard let resized = snapshot(original.element), !resized.fullScreen, !resized.minimized else {
            return Applied(success: false, deferred: true, reason: "windowChangedAfterResize")
        }
        guard abs(resized.frame.width - target.width) <= 1, abs(resized.frame.height - target.height) <= 1 else {
            return Applied(success: false, deferred: false, reason: "sizeConstrained")
        }
        guard await mayMove() else { return Applied(success: false, deferred: true, reason: "deferredAfterResize") }
        if abs(resized.frame.minX - target.minX) > 1 || abs(resized.frame.minY - target.minY) > 1 {
            var position = target.origin
            guard settable(kAXPositionAttribute, on: original.element), let value = AXValueCreate(.cgPoint, &position) else {
                return Applied(success: false, deferred: false, reason: "positionNotSettable")
            }
            let error = AXUIElementSetAttributeValue(original.element, kAXPositionAttribute as CFString, value)
            guard error == .success else { return Applied(success: false, deferred: false, reason: "positionWrite.\(error.rawValue)") }
            for _ in 0..<12 {
                guard await mayMove() else { return Applied(success: false, deferred: true, reason: "userInteraction") }
                if let moved = snapshot(original.element), near(moved.frame, target) { return Applied(success: true, deferred: false, reason: "adjusted") }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        let success = snapshot(original.element).map { near($0.frame, target) } == true
        return Applied(success: success, deferred: !success, reason: success ? "adjusted" : "positionPending")
    }

    private func restoreMinimizedWindow(pid: pid_t) {
        let windows = applicationWindows(pid: pid)
        guard !windows.isEmpty, windows.allSatisfy(\.minimized), let window = windows.first else { return }
        AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
    }

    private func settable(_ name: String, on element: AXUIElement) -> Bool {
        var value = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &value) == .success && value.boolValue
    }

    private func attribute(_ name: String, on element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}

@main
@MainActor
private struct RunWindowHelper {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = WindowHelperController()
        app.delegate = controller
        withExtendedLifetime(controller) { app.run() }
    }
}
