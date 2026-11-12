#if os(iOS)
import SwiftUI

/// Pairs an iPad, as a form in a sheet over the empty app.
struct PairingSheet: View {
    let store: PairingStore
    let onPair: () -> Void

    @State private var draft = PairingDraft()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Setup Code", text: $draft.setupCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(pair)
                } footer: {
                    Text("Enter a setup code to connect this device to your Cohesion server.")
                }
                Section {
                    TextField("Name", text: $draft.name)
                } footer: {
                    if let error = draft.error {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Pair with Cohesion")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if draft.isPairing {
                        ProgressView()
                    } else {
                        Button("Pair", action: pair)
                            .disabled(!draft.canPair)
                    }
                }
            }
        }
    }

    private func pair() {
        draft.pair(with: store, onPair: onPair)
    }
}
#endif
