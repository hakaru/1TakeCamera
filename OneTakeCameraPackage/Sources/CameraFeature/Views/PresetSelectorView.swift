// PresetSelectorView.swift
// Pill selector for CompressorPreset — shown above the record button.

import SwiftUI

public struct PresetSelectorView: View {
    @Binding public var selection: CompressorPreset
    public let isEnabled: Bool

    public init(selection: Binding<CompressorPreset>, isEnabled: Bool) {
        self._selection = selection
        self.isEnabled = isEnabled
    }

    public var body: some View {
        HStack(spacing: 8) {
            ForEach(CompressorPreset.allCases) { preset in
                Button {
                    selection = preset
                } label: {
                    VStack(spacing: 2) {
                        Text(preset.displayName).font(.caption.bold())
                        Text(preset.characterName).font(.caption2)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(selection == preset ? Color.blue : Color.black.opacity(0.5))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.5)
            }
        }
    }
}
