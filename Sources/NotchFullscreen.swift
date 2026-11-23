import AppKit

// MARK: - SkyLight private-API helpers (graceful, runtime-resolved)
//
// The two private-framework wrappers behind the notch's "float over fullscreen"
// behavior, isolated here so the dlopen/dlsym boundary into SkyLight is one
// auditable unit. Both resolve every symbol at RUNTIME and degrade to a silent
// no-op / "not fullscreen" if a symbol is missing on a future macOS — they never
// crash. macOS 13 safe (no macOS-14 APIs).

// MARK: - FullscreenSpace

/// Moves a panel into a dedicated always-on-top SkyLight "space" so it floats over
/// native-fullscreen apps (`.fullScreenAuxiliary` alone is unreliable there). Symbols are
/// resolved with dlopen/dlsym at RUNTIME; if any are missing on a future macOS,
/// `isAvailable == false` and every method is a silent no-op (never crashes — falls back
/// to the collectionBehavior). Combined with the controller's per-display alpha gating,
/// "float over fullscreen" becomes "reveal with the menu bar in fullscreen".
final class FullscreenSpace {
    static let shared = FullscreenSpace()

    private typealias CGSSpaceID = UInt64
    private typealias F_MainConn = @convention(c) () -> Int32
    private typealias F_SpaceCreate = @convention(c) (Int32, Int32, CFDictionary?) -> CGSSpaceID
    private typealias F_SetLevel = @convention(c) (Int32, CGSSpaceID, Int32) -> Int32
    private typealias F_ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias F_AddRemove = @convention(c) (Int32, CGSSpaceID, CFArray, Int32) -> Int32
    private typealias F_RemoveFrom = @convention(c) (Int32, CFArray, CFArray) -> Int32

    let isAvailable: Bool
    private let connection: Int32
    private let space: CGSSpaceID
    private let addRemove: F_AddRemove?
    private let removeFrom: F_RemoveFrom?
    private static let absoluteLevel: Int32 = Int32.max

    private init() {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
            RTLD_NOW) else {
            connection = 0; space = 0; addRemove = nil; removeFrom = nil; isAvailable = false; return
        }
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard let mainConn = sym("SLSMainConnectionID", F_MainConn.self),
              let create = sym("SLSSpaceCreate", F_SpaceCreate.self),
              let setLevel = sym("SLSSpaceSetAbsoluteLevel", F_SetLevel.self),
              let show = sym("SLSShowSpaces", F_ShowSpaces.self),
              let addRem = sym("SLSSpaceAddWindowsAndRemoveFromSpaces", F_AddRemove.self),
              let remFrom = sym("SLSRemoveWindowsFromSpaces", F_RemoveFrom.self)
        else {
            connection = 0; space = 0; addRemove = nil; removeFrom = nil; isAvailable = false; return
        }
        let conn = mainConn()
        guard conn != 0 else {
            connection = 0; space = 0; addRemove = nil; removeFrom = nil; isAvailable = false; return
        }
        let sid = create(conn, 1, nil)
        guard sid != 0 else {
            connection = 0; space = 0; addRemove = nil; removeFrom = nil; isAvailable = false; return
        }
        _ = setLevel(conn, sid, FullscreenSpace.absoluteLevel)
        _ = show(conn, [NSNumber(value: sid)] as CFArray)
        connection = conn; space = sid; addRemove = addRem; removeFrom = remFrom; isAvailable = true
    }

    func add(_ window: NSWindow) {
        guard isAvailable, window.windowNumber > 0, let addRemove = addRemove else { return }
        _ = addRemove(connection, space, [window.windowNumber] as CFArray, 7)
    }

    func remove(_ window: NSWindow) {
        guard isAvailable, window.windowNumber > 0, let removeFrom = removeFrom else { return }
        _ = removeFrom(connection, [window.windowNumber] as CFArray, [NSNumber(value: space)] as CFArray)
    }
}

// MARK: - FullscreenDetector

/// Per-display native-fullscreen detector via the private SkyLight space database.
/// `SLSCopyManagedDisplaySpaces` returns one dictionary PER display; a display's active
/// space is "fullscreen" iff that space carries a `TileLayoutManager` sub-dict. Symbols
/// are dlsym'd at RUNTIME; if any are missing on a future macOS, `isAvailable == false`
/// and `isFullscreen` returns false — degrading safely rather than crashing.
final class FullscreenDetector {
    static let shared = FullscreenDetector()

    private typealias F_MainConn = @convention(c) () -> Int32
    private typealias F_CopySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

    let isAvailable: Bool
    private let connection: Int32
    private let copySpaces: F_CopySpaces?

    private init() {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
            RTLD_NOW) else {
            connection = 0; copySpaces = nil; isAvailable = false; return
        }
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard let mainConn = sym("SLSMainConnectionID", F_MainConn.self),
              let copy = sym("SLSCopyManagedDisplaySpaces", F_CopySpaces.self)
                      ?? sym("CGSCopyManagedDisplaySpaces", F_CopySpaces.self)
        else {
            connection = 0; copySpaces = nil; isAvailable = false; return
        }
        let conn = mainConn()
        guard conn != 0 else {
            connection = 0; copySpaces = nil; isAvailable = false; return
        }
        connection = conn
        copySpaces = copy
        isAvailable = true
    }

    /// True iff the display with this UUID currently shows a native-fullscreen space.
    func isFullscreen(displayUUID: String) -> Bool {
        guard isAvailable, let copySpaces = copySpaces,
              let displays = copySpaces(connection)?.takeRetainedValue() as? [[String: Any]]
        else { return false }

        for display in displays {
            guard display["Display Identifier"] as? String == displayUUID else { continue }
            guard let current = display["Current Space"] as? [String: Any],
                  let activeID = (current["ManagedSpaceID"] as? NSNumber)?.uint64Value,
                  let spaces = display["Spaces"] as? [[String: Any]]
            else { return false }
            for space in spaces where (space["ManagedSpaceID"] as? NSNumber)?.uint64Value == activeID {
                return space["TileLayoutManager"] != nil
            }
            return false
        }
        return false
    }
}
