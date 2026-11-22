import IOKit.hid
import TellsCore

/// Reads and requests the system permissions of the sensors.
/// A request starts only when the caller calls `request(_:)` (SPEC.md 7).
public protocol PermissionChecking: Sendable {
    func status(of kind: PermissionKind) -> PermissionStatus
    func request(_ kind: PermissionKind)
}

/// Uses the public IOHID calls for Input Monitoring.
public struct SystemPermissions: PermissionChecking {
    public init() {}

    public func status(of kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .inputMonitoring:
            switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
            case kIOHIDAccessTypeGranted: return .granted
            case kIOHIDAccessTypeDenied: return .denied
            default: return .notAsked
            }
        case .microphone, .bluetooth:
            return .notAsked // TODO(P5.1): read the microphone and Bluetooth status
        }
    }

    public func request(_ kind: PermissionKind) {
        switch kind {
        case .inputMonitoring:
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        case .microphone, .bluetooth:
            break // TODO(P5.1): request the microphone and Bluetooth permission
        }
    }
}
