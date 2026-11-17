// ALL private-API access lives here. Symbols are resolved lazily via dlopen/dlsym (linking SkyLight
// directly fails on this machine). Every function degrades to nil/false when a symbol is missing.
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

enum SkyLight {
    private typealias MainConnFn = @convention(c) () -> Int32
    private typealias CopyDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias SetFrontFn = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32) -> Int32
    private typealias PostEventFn = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt8>) -> Int32
    private typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias GetPSNFn = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32

    private static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func sym<T>(_ name: String, _ type: T.Type) -> T? {
        guard let h = handle ?? dlopen(nil, RTLD_LAZY), let p = dlsym(h, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    private static let mainConn = sym("CGSMainConnectionID", MainConnFn.self)
    private static let copyDisplaySpaces = sym("CGSCopyManagedDisplaySpaces", CopyDisplaySpacesFn.self)
    private static let copySpacesForWindows = sym("CGSCopySpacesForWindows", CopySpacesForWindowsFn.self)
    private static let setFront = sym("_SLPSSetFrontProcessWithOptions", SetFrontFn.self)
    private static let postEvent = sym("SLPSPostEventRecordTo", PostEventFn.self)
    private static let getPSN = sym("GetProcessForPID", GetPSNFn.self)
        ?? { // lives in ApplicationServices (HIServices); resolve from the global namespace
            guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "GetProcessForPID") else { return nil }
            return unsafeBitCast(p, to: GetPSNFn.self)
        }()
    private static let axGetWindow: AXGetWindowFn? = {
        guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(p, to: AXGetWindowFn.self)
    }()

    static var windowFocusAvailable: Bool {
        setFront != nil && postEvent != nil && getPSN != nil && mainConn != nil
    }

    // MARK: spaces

    /// space id -> 1-based desktop index (per display), 0 = full-screen app; from CGSCopyManagedDisplaySpaces.
    static func spaceIndexMap() -> [Int: Int]? {
        guard let mainConn, let copyDisplaySpaces else { return nil }
        guard let displays = copyDisplaySpaces(mainConn())?.takeRetainedValue() as? [[String: Any]] else { return nil }
        var map: [Int: Int] = [:]
        for d in displays {
            guard let spaces = d["Spaces"] as? [[String: Any]] else { continue }
            var idx = 0
            for s in spaces {
                let id = (s["ManagedSpaceID"] as? NSNumber)?.intValue ?? (s["id64"] as? NSNumber)?.intValue
                guard let id else { continue }
                // type 4 = an app in full screen: not a numbered desktop, reported as 0
                if let t = (s["type"] as? NSNumber)?.intValue, t != 0 { map[id] = 0; continue }
                idx += 1
                map[id] = idx
            }
        }
        return map.isEmpty ? nil : map
    }

    /// First space id the window lives on.
    static func spaceID(forWindow wid: CGWindowID) -> Int? {
        spaces(forWindow: wid)?.first
    }

    /// All space ids of the window; [] = on no desktop at all (an ordered-out helper window, or a hidden app's
    /// window); nil = the private API is unavailable.
    static func spaces(forWindow wid: CGWindowID) -> [Int]? {
        guard let mainConn, let copySpacesForWindows else { return nil }
        let arr = copySpacesForWindows(mainConn(), 0x7, [NSNumber(value: wid)] as CFArray)?.takeRetainedValue()
        return ((arr as? [NSNumber]) ?? []).map(\.intValue)
    }

    // MARK: focus

    /// Make the process frontmost (switches Space) and make the window key.
    @discardableResult
    static func focusWindow(pid: pid_t, windowID wid: CGWindowID) -> Bool {
        guard let setFront, let postEvent, let getPSN else { return false }
        var psn = [UInt32](repeating: 0, count: 2)
        let ok: Bool = psn.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return false }
            guard getPSN(pid, base) == 0 else { return false }
            if setFront(base, wid, 0x200) != 0 { return false }
            for b in [UInt8(0x01), 0x02] {
                var bytes = [UInt8](repeating: 0, count: 0x100)
                bytes[0x04] = 0xf8
                bytes[0x08] = b
                bytes[0x3a] = 0x10
                var w = wid.littleEndian
                withUnsafeBytes(of: &w) { for i in 0..<4 { bytes[0x3c + i] = $0[i] } }
                // far-off point so the synthetic event does not hit anything
                var far = Double(-1_000_000).bitPattern.littleEndian
                withUnsafeBytes(of: &far) { for i in 0..<8 { bytes[0x20 + i] = $0[i]; bytes[0x28 + i] = $0[i] } }
                _ = bytes.withUnsafeMutableBufferPointer { postEvent(base, $0.baseAddress!) }
            }
            return true
        }
        return ok
    }

    // MARK: AX

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let axGetWindow else { return nil }
        var wid: CGWindowID = 0
        return axGetWindow(element, &wid) == .success && wid != 0 ? wid : nil
    }

    private typealias AXRemoteFn = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    private static let axRemote: AXRemoteFn? = {
        guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementCreateWithRemoteToken") else { return nil }
        return unsafeBitCast(p, to: AXRemoteFn.self)
    }()

    static var remoteElementsAvailable: Bool { axRemote != nil && axGetWindow != nil }

    /// AX element number `elementID` of app `pid`. Unlike kAXWindowsAttribute (current desktop only), this reaches
    /// windows on every desktop. Token layout (same as AltTab): pid(4) · 0(4) · 'coco'(4) · element id(8).
    static func remoteElement(pid: pid_t, elementID: UInt64) -> AXUIElement? {
        guard let axRemote else { return nil }
        var bytes = [UInt8](repeating: 0, count: 20)
        withUnsafeBytes(of: pid.littleEndian) { for i in 0..<4 { bytes[i] = $0[i] } }
        withUnsafeBytes(of: Int32(0x636f636f).littleEndian) { for i in 0..<4 { bytes[8 + i] = $0[i] } }
        withUnsafeBytes(of: elementID.littleEndian) { for i in 0..<8 { bytes[12 + i] = $0[i] } }
        return axRemote(Data(bytes) as CFData)?.takeRetainedValue()
    }
}
