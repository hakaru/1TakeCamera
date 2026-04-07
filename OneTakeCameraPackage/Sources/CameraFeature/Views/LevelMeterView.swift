// LevelMeterView.swift
// Horizontal level meter: -60 to 0 dBFS, color-graded green/yellow/red.

import SwiftUI

public struct LevelMeterView: View {
    public let peakDB: Float

    public init(peakDB: Float) { self.peakDB = peakDB }

    public var body: some View {
        GeometryReader { geo in
            let normalized = CGFloat(max(0, (peakDB + 60) / 60))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.black.opacity(0.4))
                Capsule()
                    .fill(color)
                    .frame(width: geo.size.width * normalized)
                    .animation(.linear(duration: 0.033), value: peakDB)
            }
        }
        .frame(height: 6)
    }

    private var color: Color {
        if peakDB > -3 { return .red }
        if peakDB > -12 { return .yellow }
        return .green
    }
}
