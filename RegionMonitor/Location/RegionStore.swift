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

    /// Distance from a fix to this region's centre, alongside that fix's
    /// accuracy. When those two numbers overlap, a transition is inside the
    /// noise floor rather than a real crossing.
    ///
    /// Shared by both monitoring backends so a log from iOS 16 and a log from
    /// iOS 17 read the same and can be compared line for line.
    func distanceDetail(from fix: CLLocation?) -> String? {
        guard let fix else { return nil }
        let centre = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let distance = fix.distance(from: centre)
        return String(format: "distToCentre=%.0fm radius=%.0fm margin=%+.0fm hAcc=%.0fm",
                      distance, radius, distance - radius, fix.horizontalAccuracy)
    }
}

final class RegionStore {

    static let shared = RegionStore()
    private init() {}

    private let stack = CoreDataStack.shared

    func activeSnapshots() async -> [RegionSnapshot] {
        let context = stack.writeContext
        return await context.perform {
            let request: NSFetchRequest<MonitoredRegionMO> = MonitoredRegionMO.fetchRequest()
            request.predicate = NSPredicate(format: "isActive == YES")
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]

            let results = (try? context.fetch(request)) ?? []
            return results.map { mo in
                RegionSnapshot(id: mo.id,
                               identifier: mo.identifier,
                               coordinate: CLLocationCoordinate2D(latitude: mo.latitude, longitude: mo.longitude),
                               radius: mo.radius,
                               notifyOnEntry: mo.notifyOnEntry,
                               notifyOnExit: mo.notifyOnExit,
                               isActive: mo.isActive,
                               createdAt: mo.createdAt)
            }
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
