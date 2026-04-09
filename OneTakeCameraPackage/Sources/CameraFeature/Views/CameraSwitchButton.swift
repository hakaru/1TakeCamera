// CameraSwitchButton.swift
// Front/rear camera toggle button.

import SwiftUI

struct CameraSwitchButton: View {
    let isFront: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.black.opacity(0.3))
                .clipShape(Circle())
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityLabel(isFront ? "Switch to rear camera" : "Switch to front camera")
    }
}
