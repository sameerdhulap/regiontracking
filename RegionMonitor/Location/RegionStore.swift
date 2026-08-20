//
//  RegionStore.swift
//  RegionMonitor
//

import CoreData
import CoreLocation
import Foundation

/// Plain-value copy of a stored region so it can cross queue boundaries
/// without dragging a managed object along.
struct RegionSnapshot: Identifiable, Hashable {
    let id: UUID
    let identifier: String
    let coordinate: CLLocationCoordinate2D
    let radius: CLLocationDistance
    let notifyOnEntry: Bool
    let notifyOnExit: Bool
    let isActive: Bool
    let createdAt: Date

    static func == (lhs: RegionSnapshot, rhs: RegionSnapshot) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

final class RegionStore {

    static let shared = RegionStore()
    private init() {}

    private let stack = CoreDataStack.shared

    func fetchActive(completion: @escaping ([RegionSnapshot]) -> Void) {
        let context = stack.writeContext
        context.perform {
            let request: NSFetchRequest<MonitoredRegionMO> = MonitoredRegionMO.fetchRequest()
            request.predicate = NSPredicate(format: "isActive == YES")
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]

            let results = (try? context.fetch(request)) ?? []
            let snapshots = results.map { mo in
                RegionSnapshot(id: mo.id,
                               identifier: mo.identifier,
                               coordinate: CLLocationCoordinate2D(latitude: mo.latitude, longitude: mo.longitude),
                               radius: mo.radius,
                               notifyOnEntry: mo.notifyOnEntry,
                               notifyOnExit: mo.notifyOnExit,
                               isActive: mo.isActive,
                               createdAt: mo.createdAt)
            }
            // Hop to main: the caller drives CLLocationManager from here,
            // and that class expects a thread with an active run loop.
            DispatchQueue.main.async { completion(snapshots) }
        }
    }

    @discardableResult
    func add(identifier: String,
             coordinate: CLLocationCoordinate2D,
             radius: CLLocationDistance,
             notifyOnEntry: Bool = true,
             notifyOnExit: Bool = true) -> Bool {

        guard CLLocationCoordinate2DIsValid(coordinate), radius > 0 else { return false }

        let context = stack.writeContext
        context.perform {
            let mo = MonitoredRegionMO(context: context)
            mo.id = UUID()
            mo.identifier = identifier
            mo.latitude = coordinate.latitude
            mo.longitude = coordinate.longitude
            mo.radius = radius
            mo.notifyOnEntry = notifyOnEntry
            mo.notifyOnExit = notifyOnExit
            mo.isActive = true
            mo.createdAt = Date()

            do {
                try context.save()
            } catch {
                NSLog("[RegionMonitor] Failed to save region: \(error)")
                return
            }

            DispatchQueue.main.async { LocationService.shared.syncRegions() }
        }
        return true
    }

    func delete(id: UUID, identifier: String) {
        LocationService.shared.stopMonitoring(identifier: identifier)

        let context = stack.writeContext
        context.perform {
            let request: NSFetchRequest<MonitoredRegionMO> = MonitoredRegionMO.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            if let mo = try? context.fetch(request).first {
                context.delete(mo)
                try? context.save()
            }
        }
    }

    func setActive(_ active: Bool, id: UUID) {
        let context = stack.writeContext
        context.perform {
            let request: NSFetchRequest<MonitoredRegionMO> = MonitoredRegionMO.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            if let mo = try? context.fetch(request).first {
                mo.isActive = active
                try? context.save()
            }
            DispatchQueue.main.async { LocationService.shared.syncRegions() }
        }
    }
}
