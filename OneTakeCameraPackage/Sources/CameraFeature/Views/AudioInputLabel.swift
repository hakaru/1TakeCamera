// AudioInputLabel.swift
// Small text label showing the current active audio input device name.

import SwiftUI

/// Displays the current audio input device name (e.g. "Scarlett 2i2" or "Built-in Mic").
/// Intended for the top-left HUD area of the camera UI.
struct AudioInputLabel: View {
    let inputName: String

    var body: some View {
        Text(inputName)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.45))
            .clipShape(Capsule())
    }
}
