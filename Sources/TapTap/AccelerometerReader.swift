import CoreFoundation
import Darwin
import IOKit
import IOKit.hid

struct MotionSample {
    let timestamp: UInt64
    let x: Double
    let y: Double
    let z: Double
}

final class AccelerometerReader {
    var onSample: ((MotionSample) -> Void)?
    var onStatus: ((String) -> Void)?

    private var manager: IOHIDManager?
    private var reportBuffer = [UInt8](repeating: 0, count: 256)
    private var devices = [IOHIDDevice]()

    deinit { stop() }

    func start() {
        wakeDrivers()
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        let matching: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: 0xFF00,
            kIOHIDDeviceUsageKey as String: 3
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceMatchingCallback(manager, deviceMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, deviceRemoved, context)
        IOHIDManagerRegisterInputReportWithTimeStampCallback(manager, reportReceived, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        onStatus?(result == kIOReturnSuccess ? "Sensor manager opened; waiting for reports" : "Sensor manager open failed: \(result)")
    }

    func stop() {
        guard let manager else { return }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        for device in devices { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        devices.removeAll()
    }

    private func accept(_ device: IOHIDDevice) -> Bool {
        let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String
        return transport?.localizedCaseInsensitiveContains("SPU") ?? false
    }

    fileprivate func handleDevice(_ device: IOHIDDevice) {
        guard accept(device) else {
            onStatus?("Rejected vendor HID candidate")
            return
        }
        devices.append(device)
        IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        let size = IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 22
        if size > reportBuffer.count { reportBuffer = [UInt8](repeating: 0, count: size) }
        onStatus?("Accelerometer candidate connected")
    }

    private func wakeDrivers() {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("AppleSPUHIDDriver") else { return }
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            IORegistryEntrySetCFProperty(service, "ReportInterval" as CFString, 8000 as CFNumber)
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    fileprivate func removeDevice(_ device: IOHIDDevice) {
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        devices.removeAll { Unmanaged.passUnretained($0).toOpaque() == Unmanaged.passUnretained(device).toOpaque() }
    }

    fileprivate func receive(sender: UnsafeMutableRawPointer?, report: UnsafePointer<UInt8>, length: Int, timestamp: UInt64) {
        guard let sender, devices.contains(where: { Unmanaged.passUnretained($0).toOpaque() == sender }) else { return }
        guard length >= 18 else { return }
        let x = decode(report, offset: 6)
        let y = decode(report, offset: 10)
        let z = decode(report, offset: 14)
        onSample?(MotionSample(timestamp: timestamp, x: x, y: y, z: z))
    }

    private func decode(_ report: UnsafePointer<UInt8>, offset: Int) -> Double {
        let raw = UInt32(report[offset])
            | UInt32(report[offset + 1]) << 8
            | UInt32(report[offset + 2]) << 16
            | UInt32(report[offset + 3]) << 24
        return Double(Int32(bitPattern: raw)) / 65536.0
    }

    fileprivate func nanoseconds(_ ticks: UInt64) -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return ticks.multipliedReportingOverflow(by: UInt64(info.numer)).partialValue / UInt64(info.denom)
    }
}

private func deviceMatched(_ context: UnsafeMutableRawPointer?, _ result: IOReturn, _ sender: UnsafeMutableRawPointer?, _ device: IOHIDDevice) {
    guard let context else { return }
    Unmanaged<AccelerometerReader>.fromOpaque(context).takeUnretainedValue().handleDevice(device)
}

private func deviceRemoved(_ context: UnsafeMutableRawPointer?, _ result: IOReturn, _ sender: UnsafeMutableRawPointer?, _ device: IOHIDDevice) {
    guard let context else { return }
    Unmanaged<AccelerometerReader>.fromOpaque(context).takeUnretainedValue().removeDevice(device)
}

private func reportReceived(_ context: UnsafeMutableRawPointer?, _ result: IOReturn, _ sender: UnsafeMutableRawPointer?, _ type: IOHIDReportType, _ reportID: UInt32, _ report: UnsafeMutablePointer<UInt8>, _ reportLength: CFIndex, _ timestamp: UInt64) {
    guard let context else { return }
    let reader = Unmanaged<AccelerometerReader>.fromOpaque(context).takeUnretainedValue()
    reader.receive(sender: sender, report: UnsafePointer(report), length: reportLength, timestamp: reader.nanoseconds(timestamp))
}
