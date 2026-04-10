// LensSelectorView.swift
// Horizontal row of circular lens buttons — modelled after the standard iOS Camera UI.

import SwiftUI

struct LensSelectorView: View {
    let lenses: [LensOption]
    @Binding var selection: String
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 10) {
            ForEach(lenses) { lens in
                Button {
                    selection = lens.id
                } label: {
                    Text(lens.displayName)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(selection == lens.id ? Color.black : Color.white)
                        .frame(width: 44, height: 44)
                        .background(
                            Circle().fill(
                                selection == lens.id
                                    ? Color.yellow.opacity(0.9)
                                    : Color.black.opacity(0.5)
                            )
                        )
                }
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.5)
                .accessibilityLabel("Switch to \(lens.displayName) lens")
            }
        }
    }
}
