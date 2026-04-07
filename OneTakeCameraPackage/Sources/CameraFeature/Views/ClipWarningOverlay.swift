// ClipWarningOverlay.swift
// Full-screen red border that appears when post-DSP audio clips above -1 dBFS.

import SwiftUI

public struct ClipWarningOverlay: View {
    public let isVisible: Bool

    public init(isVisible: Bool) {
        self.isVisible = isVisible
    }

    public var body: some View {
        Rectangle()
            .stroke(Color.red, lineWidth: 6)
            .opacity(isVisible ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: isVisible)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}
