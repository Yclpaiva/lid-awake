import Foundation

func expect(_ value: Bool, _ message: String) {
    guard value else { fatalError(message) }
}

let start = Date(timeIntervalSince1970: 0)
let defaults = Settings(minBattery: 20, maxHours: 4, stopWhenHot: true)
func reading(battery: Int? = 80, onBattery: Bool = true,
             thermal: ProcessInfo.ThermalState = .nominal, hours: Double = 0) -> Reading {
    Reading(batteryPercent: battery, onBattery: onBattery, thermal: thermal,
            now: start.addingTimeInterval(hours * 3600))
}

expect(stopReason(reading(), settings: defaults, enabledAt: start) == nil, "Healthy state keeps running")
expect(stopReason(reading(battery: 19), settings: defaults, enabledAt: start) == .battery(19), "Low battery stops")
expect(stopReason(reading(battery: 20), settings: defaults, enabledAt: start) == nil, "Threshold itself is still allowed")
expect(stopReason(reading(battery: 5, onBattery: false), settings: defaults, enabledAt: start) == nil,
       "Charging never stops for battery")
expect(stopReason(reading(battery: nil), settings: defaults, enabledAt: start) == nil, "Unknown battery does not stop")
expect(stopReason(reading(hours: 3.99), settings: defaults, enabledAt: start) == nil, "Before the time limit")
expect(stopReason(reading(hours: 4), settings: defaults, enabledAt: start) == .timeLimit, "Time limit stops")
expect(stopReason(reading(thermal: .serious), settings: defaults, enabledAt: start) == nil, "Serious heat is tolerated")
expect(stopReason(reading(battery: 5, thermal: .critical), settings: defaults, enabledAt: start) == .heat,
       "Critical heat wins over battery")

let unlimited = Settings(minBattery: nil, maxHours: nil, stopWhenHot: false)
expect(stopReason(reading(battery: 1, thermal: .critical, hours: 100), settings: unlimited, enabledAt: start) == nil,
       "Disabled limits never stop")
expect(deadline(enabledAt: start, settings: unlimited) == nil, "No deadline without a time limit")
print("Stop policy: battery, charging, time limit, heat and disabled limits passed")

// Every key used in the app needs a translation with the same format specifiers.
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let source = try String(contentsOf: root.appendingPathComponent("Sources/main.swift"), encoding: .utf8)
let keyPattern = try NSRegularExpression(pattern: #"\btf?\("((?:[^"\\]|\\.)*)""#)
let keys = Set(keyPattern.matches(in: source, range: NSRange(source.startIndex..., in: source)).map {
    String(source[Range($0.range(at: 1), in: source)!]).replacingOccurrences(of: #"\""#, with: "\"")
})
let specifier = try NSRegularExpression(pattern: "%(?:%|@|ld|d|f)")
func specifiers(_ text: String) -> [String] {
    specifier.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { String(text[Range($0.range, in: text)!]) }
}
expect(!keys.isEmpty, "No localized keys found in Sources/main.swift")
for language in ["en", "pt-BR"] {
    let url = root.appendingPathComponent("Resources/\(language).lproj/Localizable.strings")
    guard let table = NSDictionary(contentsOf: url) as? [String: String] else { fatalError("Cannot read \(url.path)") }
    for key in keys {
        guard let value = table[key] else { fatalError("\(language): missing translation for \"\(key)\"") }
        expect(specifiers(value) == specifiers(key), "\(language): format specifiers differ for \"\(key)\"")
    }
    expect(Set(table.keys) == keys, "\(language): unused translations \(Set(table.keys).subtracting(keys))")
}
print("Localization: \(keys.count) keys translated in en and pt-BR")
