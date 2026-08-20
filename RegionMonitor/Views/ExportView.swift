//
//  ExportView.swift
//  RegionMonitor
//

import SwiftUI
import UniformTypeIdentifiers

struct ExportView: View {

    @State private var format: ExportFormat = .csv
    @State private var useDateRange = false
    @State private var startDate = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    @State private var endDate = Date()

    @State private var isExporting = false
    @State private var lastResult: ExportResult?
    @State private var error: String?
    @State private var files: [URL] = []
    @State private var totalEvents = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Format", selection: $format) {
                        ForEach(ExportFormat.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    Toggle("Limit to a date range", isOn: $useDateRange)
                    if useDateRange {
                        DatePicker("From", selection: $startDate)
                        DatePicker("To", selection: $endDate)
                    }

                    Button {
                        runExport()
                    } label: {
                        HStack {
                            Text("Generate export")
                            Spacer()
                            if isExporting { ProgressView() }
                        }
                    }
                    .disabled(isExporting)
                } header: {
                    Text("New export")
                } footer: {
                    Text("\(totalEvents) entries stored. CSV opens in Numbers or Excel; GeoJSON drops straight into geojson.io or QGIS when you want to see the track against the circle.")
                }

                if let result = lastResult {
                    Section("Latest") {
                        LabeledContent("File", value: result.url.lastPathComponent)
                        LabeledContent("Rows", value: "\(result.rowCount)")
                        LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(result.byteCount), countStyle: .file))
                        ShareLink(item: result.url) {
                            Label("Share or save", systemImage: "square.and.arrow.up")
                        }
                    }
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }

                Section {
                    if files.isEmpty {
                        Text("Nothing exported yet.").foregroundStyle(.secondary)
                    } else {
                        ForEach(files, id: \.self) { url in
                            ShareLink(item: url) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(url.lastPathComponent).font(.subheadline)
                                    Text(sizeString(for: url))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete(perform: deleteFiles)
                    }
                } header: {
                    Text("On device")
                } footer: {
                    Text("These also show up under On My iPhone \u{2192} RegionMonitor in the Files app, and over USB in Finder, so you can pull them off without a network.")
                }
            }
            .navigationTitle("Export")
            .onAppear(perform: refresh)
        }
    }

    private func refresh() {
        files = LogExporter.shared.existingExports()
        LogWriter.shared.count { totalEvents = $0 }
    }

    private func runExport() {
        isExporting = true
        error = nil

        LogExporter.shared.export(format: format,
                                  from: useDateRange ? startDate : nil,
                                  to: useDateRange ? endDate : nil) { result in
            isExporting = false
            switch result {
            case .success(let value):
                lastResult = value
                refresh()
            case .failure(let failure):
                error = failure.localizedDescription
            }
        }
    }

    private func deleteFiles(at offsets: IndexSet) {
        for index in offsets { LogExporter.shared.deleteExport(at: files[index]) }
        refresh()
    }

    private func sizeString(for url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let date = (attributes?[.modificationDate] as? Date) ?? Date()
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            + " \u{2022} " + DateFormatter.logDisplay.string(from: date)
    }
}
