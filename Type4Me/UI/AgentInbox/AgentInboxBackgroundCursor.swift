import AppKit
import Darwin

/// Temporarily lets this process set resize cursors without activating MyType.
@MainActor
final class AgentInboxBackgroundCursor {
    private typealias MainConnection = @convention(c) () -> UInt32
    private typealias CopyProperty = @convention(c) (
        UInt32, UInt32, CFString, UnsafeMutablePointer<Unmanaged<CFTypeRef>?>
    ) -> Int32
    private typealias SetProperty = @convention(c) (UInt32, UInt32, CFString, CFTypeRef) -> Int32

    private struct API {
        let connection: MainConnection
        let copy: CopyProperty
        let set: SetProperty
    }

    // This WindowServer property is also used by Ice. Resolve it at runtime so an
    // OS update can disable the cursor enhancement without preventing app launch.
    private static let api: API? = {
        guard let library = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL
        ) else {
            DebugFileLogger.log("agent inbox background cursor unavailable: SkyLight not loaded")
            return nil
        }
        guard let connection = dlsym(library, "CGSMainConnectionID"),
              let copy = dlsym(library, "CGSCopyConnectionProperty"),
              let set = dlsym(library, "CGSSetConnectionProperty") else {
            dlclose(library)
            DebugFileLogger.log("agent inbox background cursor unavailable: missing connection API")
            return nil
        }
        // Keep the library loaded for the lifetime of these function pointers.
        return API(connection: unsafeBitCast(connection, to: MainConnection.self),
                   copy: unsafeBitCast(copy, to: CopyProperty.self),
                   set: unsafeBitCast(set, to: SetProperty.self))
    }()
    private static let property = "SetsCursorInBackground" as CFString
    private var originalValue: CFTypeRef?
    private var connectionID: UInt32?
    private var unavailable = false

    /// Enables background cursor updates only for a hovered resize border.
    ///
    /// Returns:
    ///   Whether the property is enabled; failure preserves ordinary AppKit resizing.
    @discardableResult
    func begin() -> Bool {
        guard connectionID == nil else { return true }
        guard !unavailable, let api = Self.api else { return false }
        let connection = api.connection()
        var previous: Unmanaged<CFTypeRef>?
        let readResult = api.copy(connection, connection, Self.property, &previous)
        let value = previous?.takeRetainedValue()
        guard readResult == 0, value.map({ CFGetTypeID($0) == CFBooleanGetTypeID() }) ?? true else {
            unavailable = true
            DebugFileLogger.log("agent inbox background cursor unavailable: property read=\(readResult)")
            return false
        }
        let writeResult = api.set(connection, connection, Self.property, kCFBooleanTrue)
        guard writeResult == 0 else {
            unavailable = true
            DebugFileLogger.log("agent inbox background cursor unavailable: property write=\(writeResult)")
            return false
        }
        // An unset property is the default foreground-only policy.
        originalValue = value ?? kCFBooleanFalse
        connectionID = connection
        return true
    }

    /// Restores this process's original cursor policy when hover or presentation ends.
    func end() {
        guard let connectionID, let originalValue, let api = Self.api else { return }
        let result = api.set(connectionID, connectionID, Self.property, originalValue)
        if result != 0 {
            unavailable = true
            DebugFileLogger.log("agent inbox background cursor restore failed: code=\(result)")
        }
        self.connectionID = nil
        self.originalValue = nil
    }
}
