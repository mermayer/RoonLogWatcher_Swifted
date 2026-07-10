import Foundation

struct RoonLogTimestampParser {
    func parse(_ line: String, relativeTo referenceDate: Date) -> Date? {
        let prefix = Array(line.utf8.prefix(160))
        guard let values = Self.timestampComponents(in: prefix) else { return nil }

        let calendar = Calendar.current
        let referenceYear = calendar.component(.year, from: referenceDate)
        let candidates = (-1...1).compactMap { offset -> Date? in
            var components = DateComponents()
            components.calendar = calendar
            components.timeZone = calendar.timeZone
            components.year = referenceYear + offset
            components.month = values.month
            components.day = values.day
            components.hour = values.hour
            components.minute = values.minute
            components.second = values.second
            return calendar.date(from: components)
        }

        return candidates.min {
            abs($0.timeIntervalSince(referenceDate)) < abs($1.timeIntervalSince(referenceDate))
        }
    }

    private static func timestampComponents(in bytes: [UInt8]) -> (month: Int, day: Int, hour: Int, minute: Int, second: Int)? {
        guard bytes.count >= 14 else { return nil }

        for start in 0...(bytes.count - 14) {
            guard bytes[start + 2] == 0x2F,
                  Self.isDigit(bytes[start]),
                  Self.isDigit(bytes[start + 1]),
                  Self.isDigit(bytes[start + 3]),
                  Self.isDigit(bytes[start + 4])
            else { continue }

            var timeStart = start + 5
            guard timeStart < bytes.count, bytes[timeStart] == 0x20 || bytes[timeStart] == 0x09 else { continue }
            while timeStart < bytes.count, bytes[timeStart] == 0x20 || bytes[timeStart] == 0x09 {
                timeStart += 1
            }
            guard timeStart + 7 < bytes.count,
                  bytes[timeStart + 2] == 0x3A,
                  bytes[timeStart + 5] == 0x3A,
                  Self.isDigit(bytes[timeStart]),
                  Self.isDigit(bytes[timeStart + 1]),
                  Self.isDigit(bytes[timeStart + 3]),
                  Self.isDigit(bytes[timeStart + 4]),
                  Self.isDigit(bytes[timeStart + 6]),
                  Self.isDigit(bytes[timeStart + 7])
            else { continue }

            let month = Self.twoDigitValue(bytes[start], bytes[start + 1])
            let day = Self.twoDigitValue(bytes[start + 3], bytes[start + 4])
            let hour = Self.twoDigitValue(bytes[timeStart], bytes[timeStart + 1])
            let minute = Self.twoDigitValue(bytes[timeStart + 3], bytes[timeStart + 4])
            let second = Self.twoDigitValue(bytes[timeStart + 6], bytes[timeStart + 7])
            guard (1...12).contains(month),
                  (1...31).contains(day),
                  (0...23).contains(hour),
                  (0...59).contains(minute),
                  (0...59).contains(second)
            else { continue }
            return (month, day, hour, minute, second)
        }
        return nil
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }

    private static func twoDigitValue(_ first: UInt8, _ second: UInt8) -> Int {
        Int(first - 0x30) * 10 + Int(second - 0x30)
    }
}
