// MIT License
// Copyright (c) 2021-2026 LinearMouse

import SwiftUI

extension ScrollingSettings {
    struct MosScrollingSettings: View {
        @ObservedObject private var state = ScrollingSettingsState.shared

        var body: some View {
            Group {
                Picker(selection: $state.mosWheelInput) {
                    ForEach(ScrollingSettingsState.MosWheelInput.allCases) { input in
                        Text(input.label).tag(input)
                    }
                } label: {
                    withDescription {
                        Text("Wheel input")
                        Text("How the wheel is read before Mos smooths it.")
                    }
                }
                .modifier(PickerViewModifier())

                if state.mosWheelInput == .byLines {
                    Slider(
                        value: $state.scrollingDistanceInLines,
                        in: 0 ... 10,
                        step: 1
                    ) {
                        Text("Distance")
                    } minimumValueLabel: {
                        Text(verbatim: "0")
                    } maximumValueLabel: {
                        Text(verbatim: "10")
                    }
                }

                sliderRow(
                    title: "Step",
                    description: "Sets the minimum scroll distance",
                    value: $state.mosStep,
                    range: Scheme.Scrolling.Mos.stepRange
                )
                sliderRow(
                    title: "Speed",
                    description: "Sets scrolling acceleration",
                    value: $state.mosSpeed,
                    range: Scheme.Scrolling.Mos.speedRange
                )
                sliderRow(
                    title: "Duration",
                    description: "Sets the duration of the scroll animation",
                    value: $state.mosDuration,
                    range: Scheme.Scrolling.Mos.durationRange
                )

                keyPicker("Dash key", description: "Hold to scroll 5 times as far", selection: $state.mosDash)
                keyPicker(
                    "Toggle key",
                    description: "Hold to change vertical scrolling to horizontal scrolling",
                    selection: $state.mosToggle
                )
                keyPicker(
                    "Block key",
                    description: "Hold to temporarily block smooth scrolling",
                    selection: $state.mosBlock
                )

                Button("Revert to Mos defaults") {
                    state.revertMosToDefaults()
                }
            }
        }

        private func sliderRow(
            title: LocalizedStringKey,
            description: LocalizedStringKey,
            value: Binding<Double>,
            range: ClosedRange<Double>
        ) -> some View {
            HStack(alignment: .firstTextBaseline) {
                Slider(value: value, in: range) {
                    labelWithDescription {
                        Text(title)
                        Text(description)
                    }
                }

                DeferredNumberField(
                    value: value,
                    formatter: state.mosFormatter,
                    range: range
                )
                .frame(width: 60, height: 22)
            }
        }

        private func keyPicker(
            _ title: LocalizedStringKey,
            description: LocalizedStringKey,
            selection: Binding<Scheme.Scrolling.Mos.Key>
        ) -> some View {
            Picker(selection: selection) {
                ForEach(Scheme.Scrolling.Mos.Key.allCases, id: \.self) { key in
                    Text(key.label).tag(key)
                    if key == .none {
                        Divider()
                    }
                }
            } label: {
                withDescription {
                    Text(title)
                    Text(description)
                }
            }
            .modifier(PickerViewModifier())
        }
    }
}

extension Scheme.Scrolling.Mos.Key {
    var label: LocalizedStringKey {
        switch self {
        case .none:
            return "None"
        case .option:
            return "⌥ Option (either)"
        case .leftOption:
            return "⌥ Left Option"
        case .rightOption:
            return "⌥ Right Option"
        case .shift:
            return "⇧ Shift (either)"
        case .leftShift:
            return "⇧ Left Shift"
        case .rightShift:
            return "⇧ Right Shift"
        case .command:
            return "⌘ Command (either)"
        case .leftCommand:
            return "⌘ Left Command"
        case .rightCommand:
            return "⌘ Right Command"
        case .control:
            return "⌃ Control (either)"
        case .leftControl:
            return "⌃ Left Control"
        case .rightControl:
            return "⌃ Right Control"
        }
    }
}
