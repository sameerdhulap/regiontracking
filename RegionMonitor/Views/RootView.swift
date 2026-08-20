//
//  RootView.swift
//  RegionMonitor
//

import CoreLocation
import SwiftUI

struct RootView: View {

    @EnvironmentObject private var location: LocationService

    var body: some View {
        TabView {
            LogListView()
                .tabItem { Label("Log", systemImage: "list.bullet.rectangle") }

            RegionListView()
                .tabItem { Label("Regions", systemImage: "mappin.circle") }

            ExportView()
                .tabItem { Label("Export", systemImage: "square.and.arrow.up") }
        }
        .overlay(alignment: .top) { authorizationBanner }
    }

    @ViewBuilder
    private var authorizationBanner: some View {
        if location.authorizationStatus != .authorizedAlways {
            VStack(spacing: 8) {
                Text(bannerMessage)
                    .font(.footnote)
                    .multilineTextAlignment(.center)

                Button(bannerAction) {
                    switch location.authorizationStatus {
                    case .notDetermined, .authorizedWhenInUse: location.requestAuthorization()
                    default: location.openSettings()
                    }
                }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(.thinMaterial)
        }
    }

    private var bannerMessage: String {
        switch location.authorizationStatus {
        case .notDetermined:
            return "Region monitoring needs location access to get started."
        case .authorizedWhenInUse:
            return "Only \u{201C}While Using\u{201D} is granted. Background and terminated-state events need \u{201C}Always\u{201D}."
        case .denied, .restricted:
            return "Location access is off, so nothing will be recorded."
        default:
            return ""
        }
    }

    private var bannerAction: String {
        switch location.authorizationStatus {
        case .notDetermined:       return "Grant access"
        case .authorizedWhenInUse: return "Upgrade to Always"
        default:                   return "Open Settings"
        }
    }
}
