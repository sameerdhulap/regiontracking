//
//  CoreDataStack.swift
//  RegionMonitor
//

import CoreData
import Foundation

final class CoreDataStack {

    static let shared = CoreDataStack()

    let container: NSPersistentContainer

    /// A single serial private-queue context used for *all* writes. Using one
    /// context (rather than a fresh one per write) keeps log ordering stable
    /// and avoids spinning up queues during the ~10s the OS gives us when it
    /// relaunches the app in the background for a region event.
    let writeContext: NSManagedObjectContext

    var viewContext: NSManagedObjectContext { container.viewContext }

    private(set) var loadError: Error?

    private init() {
        container = NSPersistentContainer(name: "RegionMonitor",
                                          managedObjectModel: CoreDataStack.makeModel())

        if let description = container.persistentStoreDescriptions.first {
            // Critical for background relaunches: the default protection class can
            // make the store unreadable while the device is locked, which silently
            // drops exactly the events you most want to capture.
            description.setOption(FileProtectionType.completeUntilFirstUserAuthentication as NSObject,
                                  forKey: NSPersistentStoreFileProtectionKey)
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
        }

        writeContext = container.newBackgroundContext()

        // No `self` capture here — the closure runs synchronously for a local
        // store, but Swift won't let us touch self before `writeContext` is set.
        var storeError: Error?
        container.loadPersistentStores { _, error in
            storeError = error
        }
        loadError = storeError
        if let storeError {
            NSLog("[RegionMonitor] Core Data store failed to load: \(storeError)")
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        writeContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        writeContext.automaticallyMergesChangesFromParent = true
    }

    var storeURL: URL? {
        container.persistentStoreDescriptions.first?.url
    }

    // MARK: - Programmatic model

    private static func makeModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        // --- LogEvent -----------------------------------------------------
        let event = NSEntityDescription()
        event.name = "LogEvent"
        event.managedObjectClassName = NSStringFromClass(LogEvent.self)

        let timestamp = attribute("timestamp", .dateAttributeType, optional: false)
        let type      = attribute("type", .stringAttributeType, optional: false, defaultValue: EventType.note.rawValue)

        event.properties = [
            attribute("id", .UUIDAttributeType, optional: false),
            timestamp,
            type,
            attribute("hasCoordinate", .booleanAttributeType, optional: false, defaultValue: false),
            attribute("latitude", .doubleAttributeType, optional: false, defaultValue: 0.0),
            attribute("longitude", .doubleAttributeType, optional: false, defaultValue: 0.0),
            attribute("horizontalAccuracy", .doubleAttributeType, optional: false, defaultValue: -1.0),
            attribute("verticalAccuracy", .doubleAttributeType, optional: false, defaultValue: -1.0),
            attribute("altitude", .doubleAttributeType, optional: false, defaultValue: 0.0),
            attribute("speed", .doubleAttributeType, optional: false, defaultValue: -1.0),
            attribute("speedAccuracy", .doubleAttributeType, optional: false, defaultValue: -1.0),
            attribute("course", .doubleAttributeType, optional: false, defaultValue: -1.0),
            attribute("locationTimestamp", .dateAttributeType),
            attribute("regionIdentifier", .stringAttributeType),
            attribute("appState", .stringAttributeType),
            attribute("battery", .floatAttributeType, optional: false, defaultValue: Float(-1)),
            attribute("detail", .stringAttributeType)
        ]

        // The log list always sorts by timestamp descending, and export filters
        // on type — index both so a 100k-row store still scrolls smoothly.
        event.indexes = [
            NSFetchIndexDescription(name: "byTimestamp", elements: [
                NSFetchIndexElementDescription(property: timestamp, collationType: .binary)
            ]),
            NSFetchIndexDescription(name: "byType", elements: [
                NSFetchIndexElementDescription(property: type, collationType: .binary)
            ])
        ]

        // --- MonitoredRegionMO --------------------------------------------
        let region = NSEntityDescription()
        region.name = "MonitoredRegionMO"
        region.managedObjectClassName = NSStringFromClass(MonitoredRegionMO.self)
        region.properties = [
            attribute("id", .UUIDAttributeType, optional: false),
            attribute("identifier", .stringAttributeType, optional: false),
            attribute("latitude", .doubleAttributeType, optional: false, defaultValue: 0.0),
            attribute("longitude", .doubleAttributeType, optional: false, defaultValue: 0.0),
            attribute("radius", .doubleAttributeType, optional: false, defaultValue: 100.0),
            attribute("notifyOnEntry", .booleanAttributeType, optional: false, defaultValue: true),
            attribute("notifyOnExit", .booleanAttributeType, optional: false, defaultValue: true),
            attribute("isActive", .booleanAttributeType, optional: false, defaultValue: true),
            attribute("createdAt", .dateAttributeType, optional: false)
        ]

        model.entities = [event, region]
        return model
    }

    private static func attribute(_ name: String,
                                  _ type: NSAttributeType,
                                  optional: Bool = true,
                                  defaultValue: Any? = nil) -> NSAttributeDescription {
        let a = NSAttributeDescription()
        a.name = name
        a.attributeType = type
        a.isOptional = optional
        a.defaultValue = defaultValue
        return a
    }
}
