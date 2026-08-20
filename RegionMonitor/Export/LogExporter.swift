//
//  LogExporter.swift
//  RegionMonitor
//
//  Streams the Core Data log out to CSV / JSON / GeoJSON on disk. Files land
//  in Documents so they're also reachable over USB in Finder and in the Files
//  app (see UIFileSharingEnabled in the README) — handy when the device has
//  been out in the field with no network.
//

import CoreData
import Foundation

enum ExportFormat: String, CaseIterable, Identifiable {
    case csv, json, geojson

    var id: String { rawValue }
    var fileExtension: String { self == .geojson ? "geojson" : rawValue }
    var displayName: String {
        switch self {
        case .csv:     return "CSV"
        case .json:    return "JSON"
        case .geojson: return "GeoJSON"
        }
    }
}

struct ExportResult {
    let url: URL
    let rowCount: Int
    let byteCount: Int
}

enum ExportError: LocalizedError {
    case noEvents
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noEvents: return "There are no log entries to export yet."
        case .writeFailed(let reason): return "Couldn't write the export file: \(reason)"
        }
    }
}

final class LogExporter {

    static let shared = LogExporter()
    private init() {}

    private let batchSize = 500

    private lazy var isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    static var exportDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Export

    func export(format: ExportFormat,
                from startDate: Date? = nil,
                to endDate: Date? = nil,
                types: Set<EventType>? = nil,
                completion: @escaping (Result<ExportResult, Error>) -> Void) {

        let context = CoreDataStack.shared.writeContext

        context.perform {
            let request: NSFetchRequest<LogEvent> = LogEvent.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
            request.fetchBatchSize = self.batchSize
            request.predicate = self.makePredicate(start: startDate, end: endDate, types: types)

            do {
                let events = try context.fetch(request)
                guard !events.isEmpty else {
                    DispatchQueue.main.async { completion(.failure(ExportError.noEvents)) }
                    return
                }

                let body: String
                switch format {
                case .csv:     body = self.makeCSV(events)
                case .json:    body = self.makeJSON(events)
                case .geojson: body = self.makeGeoJSON(events)
                }

                let stamp = DateFormatter.fileStamp.string(from: Date())
                let url = Self.exportDirectory
                    .appendingPathComponent("region-monitor-\(stamp).\(format.fileExtension)")

                try body.write(to: url, atomically: true, encoding: .utf8)
                // Exports need to survive a locked device too, otherwise
                // AirDropping them later can fail.
                try? FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: url.path
                )

                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
                let result = ExportResult(url: url, rowCount: events.count, byteCount: size)

                DispatchQueue.main.async { completion(.success(result)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(ExportError.writeFailed(error.localizedDescription))) }
            }
        }
    }

    func existingExports() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: Self.exportDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []

        return urls.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
    }

    func deleteExport(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Predicate

    private func makePredicate(start: Date?, end: Date?, types: Set<EventType>?) -> NSPredicate? {
        var parts: [NSPredicate] = []
        if let start { parts.append(NSPredicate(format: "timestamp >= %@", start as NSDate)) }
        if let end { parts.append(NSPredicate(format: "timestamp <= %@", end as NSDate)) }
        if let types, !types.isEmpty, types.count != EventType.allCases.count {
            parts.append(NSPredicate(format: "type IN %@", types.map(\.rawValue)))
        }
        guard !parts.isEmpty else { return nil }
        return NSCompoundPredicate(andPredicateWithSubpredicates: parts)
    }

    // MARK: - Serialisers

    private func makeCSV(_ events: [LogEvent]) -> String {
        var out = "timestamp_utc,type,region,latitude,longitude,horizontal_accuracy_m,vertical_accuracy_m,altitude_m,speed_mps,course_deg,fix_timestamp_utc,app_state,battery,detail\n"
        out.reserveCapacity(events.count * 160)

        for e in events {
            let coords = e.hasCoordinate
                ? [fmt(e.latitude, 7), fmt(e.longitude, 7), fmt(e.horizontalAccuracy, 1),
                   fmt(e.verticalAccuracy, 1), fmt(e.altitude, 1), fmt(e.speed, 2), fmt(e.course, 1)]
                : ["", "", "", "", "", "", ""]

            let fields = [
                isoFormatter.string(from: e.timestamp),
                e.type,
                e.regionIdentifier ?? ""
            ] + coords + [
                e.locationTimestamp.map { isoFormatter.string(from: $0) } ?? "",
                e.appState ?? "",
                e.battery >= 0 ? fmt(Double(e.battery), 2) : "",
                e.detail ?? ""
            ]

            out += fields.map(escapeCSV).joined(separator: ",") + "\n"
        }
        return out
    }

    private func makeJSON(_ events: [LogEvent]) -> String {
        var payload: [[String: Any]] = []
        payload.reserveCapacity(events.count)

        for e in events {
            var row: [String: Any] = [
                "timestamp": isoFormatter.string(from: e.timestamp),
                "type": e.type
            ]
            if let r = e.regionIdentifier { row["region"] = r }
            if let s = e.appState { row["appState"] = s }
            if let d = e.detail { row["detail"] = d }
            if e.battery >= 0 { row["battery"] = Double(e.battery) }
            if let t = e.locationTimestamp { row["fixTimestamp"] = isoFormatter.string(from: t) }

            if e.hasCoordinate {
                row["location"] = [
                    "latitude": e.latitude,
                    "longitude": e.longitude,
                    "horizontalAccuracy": e.horizontalAccuracy,
                    "verticalAccuracy": e.verticalAccuracy,
                    "altitude": e.altitude,
                    "speed": e.speed,
                    "course": e.course
                ]
            }
            payload.append(row)
        }

        let envelope: [String: Any] = [
            "exportedAt": isoFormatter.string(from: Date()),
            "device": [
                "model": ProcessInfo.processInfo.operatingSystemVersionString,
                "app": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            ],
            "count": payload.count,
            "events": payload
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: envelope,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    /// GeoJSON drops straight into geojson.io, QGIS or Kepler — usually the
    /// fastest way to eyeball whether a fix actually left the circle.
    private func makeGeoJSON(_ events: [LogEvent]) -> String {
        var features: [[String: Any]] = []

        for e in events where e.hasCoordinate {
            var properties: [String: Any] = [
                "timestamp": isoFormatter.string(from: e.timestamp),
                "type": e.type,
                "horizontalAccuracy": e.horizontalAccuracy
            ]
            if let r = e.regionIdentifier { properties["region"] = r }
            if let s = e.appState { properties["appState"] = s }
            if let d = e.detail { properties["detail"] = d }

            features.append([
                "type": "Feature",
                "geometry": ["type": "Point", "coordinates": [e.longitude, e.latitude]],
                "properties": properties
            ])
        }

        let collection: [String: Any] = ["type": "FeatureCollection", "features": features]
        guard let data = try? JSONSerialization.data(withJSONObject: collection,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"type\":\"FeatureCollection\",\"features\":[]}"
        }
        return string
    }

    // MARK: - Helpers

    private func fmt(_ value: Double, _ places: Int) -> String {
        guard value.isFinite else { return "" }
        return String(format: "%.\(places)f", value)
    }

    private func escapeCSV(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

extension DateFormatter {
    static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static let logDisplay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd MMM HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
