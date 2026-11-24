import AppKit
import Darwin
import Foundation
import os

private let multitouchContactCallback: MTContactCallbackFunction = { device, touches, count, _, _ in
    guard let touches = touches, count > 0 else {
        MultitouchGestureMonitor.shared.processTouches([], device: device)
        return 0
    }

    var activePoints: [CGPoint] = []
    activePoints.reserveCapacity(Int(count))

    for index in 0..<Int(count) {
        let touch = touches[index]
        if touch.state >= 3 && touch.state <= 4 {
            activePoints.append(
                CGPoint(
                    x: CGFloat(touch.normalized.position.x),
                    y: CGFloat(touch.normalized.position.y)
                )
            )
        }
    }

    MultitouchGestureMonitor.shared.processTouches(activePoints, device: device)
    return 0
}

final class MultitouchGestureMonitor {
    static let shared = MultitouchGestureMonitor()

    var onGesture: ((PinchGestureEvent) -> Void)?

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.aryanfulari.Launchly",
        category: "Multitouch"
    )

    private let stateLock = NSLock()
    private var detectors: [Int: PinchDetector] = [:]
    private var sensitivity: Double = LaunchlySettings.Defaults.pinchSensitivity

    private var frameworkHandle: UnsafeMutableRawPointer?
    private var createListFn: MTDeviceCreateListFn?
    private var registerCallbackFn: MTRegisterContactFrameCallbackFn?
    private var unregisterCallbackFn: MTUnregisterContactFrameCallbackFn?
    private var deviceStartFn: MTDeviceStartFn?
    private var deviceStopFn: MTDeviceStopFn?

    private var retainedDeviceList: CFMutableArray?
    private var activeDevices: [MTDeviceRef] = []
    private var wakeObserver: NSObjectProtocol?
    private var isEnabled = false
    private var isStarted = false

    private init() {
        loadFrameworkSymbols()
        observeSystemWake()
    }

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        stop()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled {
            start()
        } else {
            stop()
        }
    }

    func setSensitivity(_ value: Double) {
        let clamped = min(max(0.0, value), 1.0)
        stateLock.lock()
        sensitivity = clamped
        for key in detectors.keys {
            detectors[key]?.applySensitivity(clamped)
        }
        stateLock.unlock()
    }

    func start() {
        stop()

        guard isEnabled else { return }

        guard
            let createListFn,
            let registerCallbackFn,
            let deviceStartFn
        else {
            logger.error("MultitouchSupport symbols unavailable; pinch gesture monitoring disabled.")
            return
        }

        guard let unmanagedList = createListFn() else {
            logger.info("Started 0 multitouch device(s)")
            return
        }

        let cfList = unmanagedList.takeRetainedValue()
        retainedDeviceList = cfList

        let count = CFArrayGetCount(cfList)
        var startedDevices: [MTDeviceRef] = []
        startedDevices.reserveCapacity(count)

        for idx in 0..<count {
            guard let rawPtr = CFArrayGetValueAtIndex(cfList, idx) else { continue }
            let device = UnsafeMutableRawPointer(mutating: rawPtr)
            registerCallbackFn(device, multitouchContactCallback)
            deviceStartFn(device, 0)
            startedDevices.append(device)
        }

        activeDevices = startedDevices
        isStarted = true
        logger.info("Started \(startedDevices.count) multitouch device(s)")
    }

    func stop() {
        if let unregisterCallbackFn, let deviceStopFn {
            for device in activeDevices {
                unregisterCallbackFn(device, multitouchContactCallback)
                deviceStopFn(device)
            }
        }
        activeDevices.removeAll()
        retainedDeviceList = nil
        isStarted = false

        stateLock.lock()
        detectors.removeAll()
        stateLock.unlock()
    }

    func restart() {
        guard isEnabled else { return }
        logger.info("Restarting multitouch devices")
        start()
    }

    fileprivate func processTouches(_ points: [CGPoint], device: MTDeviceRef?) {
        let deviceKey = device.map { Int(bitPattern: $0) } ?? 0

        stateLock.lock()
        var detector = detectors[deviceKey] ?? {
            var d = PinchDetector()
            d.applySensitivity(sensitivity)
            return d
        }()
        let result = detector.process(points)
        detectors[deviceKey] = detector
        stateLock.unlock()

        if let summary = result.ended {
            let firedName = summary.fired?.rawValue ?? "none"
            logger.info("Pinch ended baseline=\(summary.baseline, format: .fixed(precision: 3)) min=\(summary.minSpread, format: .fixed(precision: 3)) max=\(summary.maxSpread, format: .fixed(precision: 3)) fired=\(firedName, privacy: .public)")
        }

        if let triggeredEvent = result.event {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isEnabled else { return }
                self.onGesture?(triggeredEvent)
            }
        }
    }

    // MARK: - Private

    private func loadFrameworkSymbols() {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_NOW) else {
            let errorMessage = dlerror().map { String(cString: $0) } ?? "unknown error"
            logger.error("Failed to dlopen MultitouchSupport: \(errorMessage, privacy: .public)")
            return
        }

        frameworkHandle = handle

        guard
            let createSym = dlsym(handle, "MTDeviceCreateList"),
            let registerSym = dlsym(handle, "MTRegisterContactFrameCallback"),
            let unregisterSym = dlsym(handle, "MTUnregisterContactFrameCallback"),
            let startSym = dlsym(handle, "MTDeviceStart"),
            let stopSym = dlsym(handle, "MTDeviceStop")
        else {
            logger.error("Failed to resolve required MultitouchSupport symbols.")
            return
        }

        createListFn = unsafeBitCast(createSym, to: MTDeviceCreateListFn.self)
        registerCallbackFn = unsafeBitCast(registerSym, to: MTRegisterContactFrameCallbackFn.self)
        unregisterCallbackFn = unsafeBitCast(unregisterSym, to: MTUnregisterContactFrameCallbackFn.self)
        deviceStartFn = unsafeBitCast(startSym, to: MTDeviceStartFn.self)
        deviceStopFn = unsafeBitCast(stopSym, to: MTDeviceStopFn.self)
    }

    private func observeSystemWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isEnabled else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.restart()
            }
        }
    }
}
