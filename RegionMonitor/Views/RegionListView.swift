//
//  RegionListView.swift
//  RegionMonitor
//

import CoreData
import CoreLocation
import SwiftUI

struct RegionListView: View {

    @EnvironmentObject private var location: LocationService

    @FetchRequest(sortDescriptors: [SortDescriptor(\MonitoredRegionMO.createdAt, order: .reverse)])
    private var regions: FetchedResults<MonitoredRegionMO>

    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            Group {
                if regions.isEmpty {
                    ContentUnavailableView("No regions",
                                           systemImage: "mappin.slash",
                                           description: Text("Add a circle around somewhere you'll walk in and out of. Around 100\u{2013}200 m works best; smaller circles fire unreliably."))
                } else {
                    List {
                        Section {
                            ForEach(regions) { region in
                                RegionRow(region: region,
                                          isMonitored: location.monitoredIdentifiers.contains(region.identifier))
                            }
                            .onDelete(perform: delete)
                        } footer: {
                            Text("iOS monitors at most \(LocationService.maxMonitoredRegions) regions per app. Anything beyond that is skipped and noted in the log.")
                        }
                    }
                }
            }
            .navigationTitle("Regions")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAdd = true } label: { Image(systemName: "plus") }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { location.syncRegions() } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .sheet(isPresented: $showingAdd) { AddRegionView() }
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let region = regions[index]
            RegionStore.shared.delete(id: region.id, identifier: region.identifier)
        }
    }
}

private struct RegionRow: View {

    @ObservedObject var region: MonitoredRegionMO
    let isMonitored: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(region.identifier).font(.headline)
                Spacer()
                Circle()
                    .fill(isMonitored ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(isMonitored ? "monitoring" : "idle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(String(format: "%.6f, %.6f  \u{2022}  r = %.0f m",
                        region.latitude, region.longitude, region.radius))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                if region.notifyOnEntry { Tag(text: "entry") }
                if region.notifyOnExit { Tag(text: "exit") }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct Tag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.15), in: Capsule())
    }
}

// MARK: - Add region

struct AddRegionView: View {

    @EnvironmentObject private var location: LocationService
    @Environment(\.dismiss) private var dismiss

    @State private var identifier = ""
    @State private var centre = ""
    @State private var radius: Double = 150
    @State private var notifyOnEntry = true
    @State private var notifyOnExit = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Name, e.g. Home", text: $identifier)
                        .autocorrectionDisabled()
                }

                Section {
                    TextField("19.118344, 72.939373", text: $centre)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                    Button("Use current location") { fillFromCurrentLocation() }
                        .disabled(location.lastLocation == nil)
                } header: {
                    Text("Centre")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Latitude and longitude, comma separated \u{2014} paste it straight from a map app.")
                        if let fix = location.lastLocation {
                            Text(String(format: "Last fix was %.0f s ago, accurate to about %.0f m.",
                                        -fix.timestamp.timeIntervalSinceNow, fix.horizontalAccuracy))
                        } else {
                            Text("No fix yet \u{2014} tap \u{201C}Request a fix now\u{201D} on the Log tab first.")
                        }
                    }
                }

                Section {
                    VStack(alignment: .leading) {
                        Text("Radius: \(Int(radius)) m")
                        Slider(value: $radius, in: 50...2000, step: 10)
                    }
                    Toggle("Notify on entry", isOn: $notifyOnEntry)
                    Toggle("Notify on exit", isOn: $notifyOnExit)
                } footer: {
                    Text("Below roughly 100 m you'll get false crossings on GPS noise alone, especially indoors or in a built-up area.")
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("New region")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { save() }
                }
            }
        }
    }

    /// Parses the form every map app puts on the clipboard \u{2014}
    /// "19.118344457801253, 72.93937313363423". A bare space works as the
    /// separator too, so a pair copied without its comma still lands.
    static func coordinatePair(in text: String) -> (lat: Double, lon: Double)? {
        let parts = text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        guard parts.count == 2,
              let lat = Double(parts[0]),
              let lon = Double(parts[1]) else { return nil }
        return (lat, lon)
    }

    private func fillFromCurrentLocation() {
        guard let fix = location.lastLocation else { return }
        centre = String(format: "%.6f, %.6f", fix.coordinate.latitude, fix.coordinate.longitude)
    }

    private func save() {
        let name = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { error = "Give the region a name."; return }
        guard let pair = Self.coordinatePair(in: centre) else {
            error = "Enter the centre as two numbers separated by a comma, e.g. 19.118344, 72.939373."
            return
        }
        let coordinate = CLLocationCoordinate2D(latitude: pair.lat, longitude: pair.lon)
        guard CLLocationCoordinate2DIsValid(coordinate) else {
            error = "Those coordinates aren't valid."
            return
        }
        guard notifyOnEntry || notifyOnExit else {
            error = "Pick at least one of entry or exit."
            return
        }

        RegionStore.shared.add(identifier: name,
                               coordinate: coordinate,
                               radius: radius,
                               notifyOnEntry: notifyOnEntry,
                               notifyOnExit: notifyOnExit)
        dismiss()
    }
}
