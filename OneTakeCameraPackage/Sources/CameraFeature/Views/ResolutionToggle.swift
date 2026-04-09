// ResolutionToggle.swift
// HD | 4K pill toggle for the viewfinder top-left area.

import SwiftUI

struct ResolutionToggle: View {
    @Binding var resolution: CaptureResolution
    let is4KSupported: Bool
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(CaptureResolution.allCases) { res in
                let isSelected = resolution == res
                let isAvailable = res == .hd || is4KSupported
                Button {
                    resolution = res
                } label: {
                    Text(res.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isSelected ? .white : Color(white: 0.7))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            isSelected
                                ? Color.blue.opacity(0.8)
                                : Color.clear
                        )
                }
                .disabled(!isEnabled || !isAvailable)
                .opacity((isEnabled && isAvailable) ? 1 : 0.4)
            }
        }
        .background(Color.black.opacity(0.5))
        .clipShape(Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Resolution: \(resolution.displayName)")
    }
}
