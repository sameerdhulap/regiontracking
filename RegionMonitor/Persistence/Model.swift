//
//  Model.swift
//  RegionMonitor
//
//  Managed object subclasses. The Core Data model itself is built in code
//  (see CoreDataStack.makeModel) so there's no binary .xcdatamodeld to
//  merge-conflict on, and the schema stays reviewable in a diff.
//

import CoreData
import Foundation

// MARK: - Event types

enum EventType: String, CaseIterable, Identifiable {
    case appLaunch          = "app.launch"
    case appRelaunchByOS    = "app.relaunch.location"
    case appState           = "app.state"
    case authChange         = "auth.change"
    case monitoringStart    = "region.monitoring.start"
    case monitoringStop     = "region.monitoring.stop"
    case monitoringFailed   = "region.monitoring.failed"
    case regionEnter        = "region.enter"
    case regionExit         = "region.exit"
    case regionState        = "region.state"
    case location           = "location.update"
    case visit              = "location.visit"
    case error              = "error"
    case note               = "note"

    var id: String { rawValue }

    /// SF Symbol used in the log list.
    var symbol: String {
        switch self {
        case .regionEnter:                  return "arrow.down.right.circle.fill"
        case .regionExit:                   return "arrow.up.left.circle.fill"
        case .regionState:                  return "questionmark.circle.fill"
        case .location:                     return "location.fill"
        case .visit:                        return "mappin.and.ellipse"
        case .authChange:                   return "lock.shield.fill"
        case .appLaunch, .appRelaunchByOS:  return "power"
        case .appState:                     return "rectangle.on.rectangle"
        case .monitoringStart:              return "dot.radiowaves.left.and.right"
        case .monitoringStop:               return "xmark.circle"
        case .monitoringFailed, .error:     return "exclamationmark.triangle.fill"
        case .note:                         return "text.bubble"
        }
    }
}

// MARK: - LogEvent

@objc(LogEvent)
public final class LogEvent: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var timestamp: Date
    @NSManaged public var type: String
    @NSManaged public var hasCoordinate: Bool
    @NSManaged public var latitude: Double
    @NSManaged public var longitude: Double
    @NSManaged public var horizontalAccuracy: Double
    @NSManaged public var verticalAccuracy: Double
    @NSManaged public var altitude: Double
    @NSManaged public var speed: Double
    @NSManaged public var speedAccuracy: Double
    @NSManaged public var course: Double
    @NSManaged public var locationTimestamp: Date?
    @NSManaged public var regionIdentifier: String?
    @NSManaged public var appState: String?
    @NSManaged public var battery: Float
    @NSManaged public var detail: String?

    @nonobjc public class func fetchRequest() -> NSFetchRequest<LogEvent> {
        NSFetchRequest<LogEvent>(entityName: "LogEvent")
    }

    var eventType: EventType { EventType(rawValue: type) ?? .note }
}

/// `List`/`ForEach` need a stable identity; the `id` attribute is non-optional
/// in the model, so conformance is just a declaration.
extension LogEvent: Identifiable {}

// MARK: - MonitoredRegionMO

@objc(MonitoredRegionMO)
public final class MonitoredRegionMO: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var identifier: String
    @NSManaged public var latitude: Double
    @NSManaged public var longitude: Double
    @NSManaged public var radius: Double
    @NSManaged public var notifyOnEntry: Bool
    @NSManaged public var notifyOnExit: Bool
    @NSManaged public var isActive: Bool
    @NSManaged public var createdAt: Date

    @nonobjc public class func fetchRequest() -> NSFetchRequest<MonitoredRegionMO> {
        NSFetchRequest<MonitoredRegionMO>(entityName: "MonitoredRegionMO")
    }
}

extension MonitoredRegionMO: Identifiable {}
