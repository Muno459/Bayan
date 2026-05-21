import Foundation

/// Lightweight debug logger. No-op in release builds so 60+ verbose audio /
/// network prints don't ship in TestFlight or App Store binaries.
@inlinable
func dlog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}
