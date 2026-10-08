//
//  EmptyStateView.swift
//  RegionMonitor
//
//  `ContentUnavailableView` is iOS 17+, and this app runs on 16. One wrapper
//  here beats an `if #available` at every empty state, and keeps the two
//  versions looking alike rather than drifting apart.
//

import SwiftUI

struct EmptyStateView: View {

    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        if #available(iOS 17.0, *) {
            ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
        } else {
            VStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 52))
                    .foregroundStyle(.secondary)

                Text(title)
                    .font(.title2.weight(.semibold))

                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
