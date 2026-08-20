//
//  LogListView.swift
//  RegionMonitor
//

import CoreData
import SwiftUI

struct LogListView: View {

    @EnvironmentObject private var location: LocationService
    @Environment(\.managedObjectContext) private var context

    @State private var selectedTypes: Set<EventType> = []
    @State private var showingClearConfirm = false

    var body: some View {
        NavigationStack {
            LogListContent(predicate: predicate)
                .navigationTitle("Log")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { filterMenu }
                    ToolbarItem(placement: .topBarTrailing) { actionMenu }
                }
                .safeAreaInset(edge: .bottom) { statusBar }
                .confirmationDialog("Delete every log entry?",
                                    isPresented: $showingClearConfirm,
                                    titleVisibility: .visible) {
                    Button("Delete all", role: .destructive) { LogWriter.shared.deleteAll() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Export first if you still need this data — it can't be recovered.")
                }
        }
    }

    private var predicate: NSPredicate? {
        guard !selectedTypes.isEmpty else { return nil }
        return NSPredicate(format: "type IN %@", selectedTypes.map(\.rawValue))
    }

    private var filterMenu: some View {
        Menu {
            Button("Show everything") { selectedTypes = [] }
            Divider()
            ForEach(EventType.allCases) { type in
                Button {
                    if selectedTypes.contains(type) { selectedTypes.remove(type) }
                    else { selectedTypes.insert(type) }
                } label: {
                    Label(type.rawValue, systemImage: selectedTypes.contains(type) ? "checkmark" : type.symbol)
                }
            }
        } label: {
            Image(systemName: selectedTypes.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
    }

    private var actionMenu: some View {
        Menu {
            Button { location.requestOneShotLocation() } label: {
                Label("Request a fix now", systemImage: "location")
            }
            Button { location.requestStateForAll() } label: {
                Label("Check region states", systemImage: "questionmark.circle")
            }
            Button { LogWriter.shared.log(.note, location: location.lastLocation, detail: "Manual marker") } label: {
                Label("Drop a marker", systemImage: "text.bubble")
            }
            Divider()
            Button { LogWriter.shared.prune(olderThan: 7) } label: {
                Label("Prune older than 7 days", systemImage: "clock.arrow.circlepath")
            }
            Button(role: .destructive) { showingClearConfirm = true } label: {
                Label("Delete all", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    private var statusBar: some View {
        HStack(spacing: 16) {
            Label(location.authorizationStatus.label, systemImage: "lock.shield")
            Label("\(location.monitoredIdentifiers.count)/\(LocationService.maxMonitoredRegions)", systemImage: "mappin.circle")
            Spacer()
            Text("Stream fixes")
            Toggle("Stream fixes", isOn: Binding(get: { location.isStreamingContinuousUpdates },
                                                 set: { location.setContinuousUpdates($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .font(.caption)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}

/// Split out so the @FetchRequest can be rebuilt whenever the filter changes.
private struct LogListContent: View {

    @FetchRequest private var events: FetchedResults<LogEvent>

    init(predicate: NSPredicate?) {
        let request: NSFetchRequest<LogEvent> = LogEvent.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        request.predicate = predicate
        request.fetchBatchSize = 50
        _events = FetchRequest(fetchRequest: request, animation: .default)
    }

    var body: some View {
        Group {
            if events.isEmpty {
                ContentUnavailableView("No entries yet",
                                       systemImage: "list.bullet.rectangle",
                                       description: Text("Add a region, then move across its boundary. Events land here even when the app is closed."))
            } else {
                List(events) { LogRow(event: $0) }
                    .listStyle(.plain)
            }
        }
    }
}

private struct LogRow: View {

    let event: LogEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: event.eventType.symbol)
                    .foregroundStyle(tint)
                Text(event.type)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(DateFormatter.logDisplay.string(from: event.timestamp))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let region = event.regionIdentifier {
                Text(region)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if event.hasCoordinate {
                Text(String(format: "%.6f, %.6f  ±%.0fm",
                            event.latitude, event.longitude, event.horizontalAccuracy))
                    .font(.caption.monospaced())
            }

            if let detail = event.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }

            if let state = event.appState {
                Text(state)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }
        }
        .padding(.vertical, 2)
    }

    private var tint: Color {
        switch event.eventType {
        case .regionEnter:                  return .green
        case .regionExit:                   return .orange
        case .error, .monitoringFailed:     return .red
        case .authChange:                   return .purple
        case .appLaunch, .appRelaunchByOS:  return .blue
        default:                            return .secondary
        }
    }
}
