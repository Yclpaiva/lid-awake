import Foundation

struct Settings {
    /// Stop below this battery percentage while on battery; nil means never.
    var minBattery: Int?
    /// Stop after this many hours on; nil means no limit.
    var maxHours: Int?
    /// Stop when macOS reports critical thermal pressure.
    var stopWhenHot: Bool
}

struct Reading {
    var batteryPercent: Int?
    var onBattery: Bool
    var thermal: ProcessInfo.ThermalState
    var now: Date
}

enum StopReason: Equatable {
    case battery(Int)
    case timeLimit
    case heat
}

func deadline(enabledAt: Date, settings: Settings) -> Date? {
    settings.maxHours.map { enabledAt.addingTimeInterval(TimeInterval($0) * 3600) }
}

/// Decides whether lid-closed awake mode must be turned off now. Heat wins over
/// battery and time because it is the only condition that can hurt the machine.
func stopReason(_ reading: Reading, settings: Settings, enabledAt: Date) -> StopReason? {
    if settings.stopWhenHot && reading.thermal == .critical { return .heat }
    if let min = settings.minBattery, reading.onBattery,
       let percent = reading.batteryPercent, percent < min { return .battery(percent) }
    if let end = deadline(enabledAt: enabledAt, settings: settings), reading.now >= end { return .timeLimit }
    return nil
}
