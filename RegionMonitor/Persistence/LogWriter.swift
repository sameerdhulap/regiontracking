//
//  LogWriter.swift
//  RegionMonitor
//

import CoreData
import CoreLocation
import UIKit

final class LogWriter {

    static let shared = LogWriter()
    private init() {}

    private let stack = CoreDataStack.shared

    // MARK: - Public API

    func log(_ type: EventType,
             location: CLLocation? = nil,
             regionIdentifier: String? = nil,
             detail: String? = nil) {

        // Snapshot everything now — by the time the private queue drains, the
        // app state or the CLLocation reference could have moved on.
        let now = Date()
        let appState = AppStateTracker.shared.state
        let battery = AppStateTracker.shared.batteryLevel

        NSLog("[RegionMonitor] %@ region=%@ %@",
              type.rawValue, regionIdentifier ?? "-", detail ?? "")

        withBackgroundTaskAssertion { [weak self] finish in
            guard let self else { finish(); return }

            let context = self.stack.writeContext
            context.perform {
                let event = LogEvent(context: context)
                event.id = UUID()
                event.timestamp = now
                event.type = type.rawValue
                event.regionIdentifier = regionIdentifier
                event.appState = appState
                event.battery = battery
                event.detail = detail

                if let location {
                    event.hasCoordinate = true
                    event.latitude = location.coordinate.latitude
                    event.longitude = location.coordinate.longitude
                    event.horizontalAccuracy = location.horizontalAccuracy
                    event.verticalAccuracy = location.verticalAccuracy
                    event.altitude = location.altitude
                    event.speed = location.speed
                    event.speedAccuracy = location.speedAccuracy
                    event.course = location.course
                    event.locationTimestamp = location.timestamp
                } else {
                    event.hasCoordinate = false
                }

                do {
                    if context.hasChanges { try context.save() }
                } catch {
                    NSLog("[RegionMonitor] Failed to persist log event: \(error)")
                }

                finish()
            }
        }
    }

    // MARK: - Maintenance

    /// Deletes everything older than `days`, keeping the store from growing
    /// without bound during a long field trial.
    func prune(olderThan days: Int, completion: ((Int) -> Void)? = nil) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let context = stack.writeContext

        context.perform {
            let request: NSFetchRequest<NSFetchRequestResult> = NSFetchRequest(entityName: "LogEvent")
            request.predicate = NSPredicate(format: "timestamp < %@", cutoff as NSDate)

            let delete = NSBatchDeleteRequest(fetchRequest: request)
            delete.resultType = .resultTypeObjectIDs

            var deleted = 0
            do {
                let result = try context.execute(delete) as? NSBatchDeleteResult
                let ids = result?.result as? [NSManagedObjectID] ?? []
                deleted = ids.count
                // Batch deletes bypass the context, so merge manually or the
                // UI keeps showing rows that no longer exist.
                NSManagedObjectContext.mergeChanges(
                    fromRemoteContextSave: [NSDeletedObjectsKey: ids],
                    into: [self.stack.viewContext, context]
                )
            } catch {
                NSLog("[RegionMonitor] Prune failed: \(error)")
            }

            DispatchQueue.main.async { completion?(deleted) }
        }
    }

    func deleteAll(completion: (() -> Void)? = nil) {
        prune(olderThan: 0) { _ in completion?() }
    }

    func count(completion: @escaping (Int) -> Void) {
        let context = stack.writeContext
        context.perform {
            let request: NSFetchRequest<LogEvent> = LogEvent.fetchRequest()
            let n = (try? context.count(for: request)) ?? 0
            DispatchQueue.main.async { completion(n) }
        }
    }

    // MARK: - Background task assertion

    /// Wraps a write in a background task so a save started from a region
    /// callback isn't cut off when the app gets suspended a moment later.
    private func withBackgroundTaskAssertion(_ work: @escaping (@escaping () -> Void) -> Void) {
        let begin = {
            var taskID = UIBackgroundTaskIdentifier.invalid
            let end = {
                DispatchQueue.main.async {
                    guard taskID != .invalid else { return }
                    UIApplication.shared.endBackgroundTask(taskID)
                    taskID = .invalid
                }
            }
            taskID = UIApplication.shared.beginBackgroundTask(withName: "RegionMonitor.LogWrite") {
                end()
            }
            work(end)
        }

        if Thread.isMainThread {
            begin()
        } else {
            DispatchQueue.main.async(execute: begin)
        }
    }
}
