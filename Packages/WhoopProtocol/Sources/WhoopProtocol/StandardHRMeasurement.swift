/// Structural completeness of the standard BLE Heart Rate Measurement (0x2A37).
public enum StandardHRMeasurement {
    /// Require the flag-selected HR and energy fields and whole declared R-R words.
    /// Reserved flag bits, empty R-R fields and undeclared trailing bytes retain existing compatibility.
    /// Kotlin twin: `StandardHrMeasurement.hasCompleteFields`.
    public static func hasCompleteFields(_ data: [UInt8]) -> Bool {
        guard let flags = data.first else { return false }
        let prefixBytes = 1 + (flags & 0x01 != 0 ? 2 : 1) + (flags & 0x08 != 0 ? 2 : 0)
        guard data.count >= prefixBytes else { return false }
        return flags & 0x10 == 0 || (data.count - prefixBytes) % 2 == 0
    }
}
