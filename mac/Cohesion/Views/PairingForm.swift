import SwiftUI

/// Registers this app with a server elsewhere using the setup code it
/// printed, under a name that starts as the device's and the app's.
struct PairingForm: View {
    let store: PairingStore
    let onPair: (RemotePairing) -> Void

    @State private var draft = PairingDraft()

    /// `onPair` runs with the new pairing once the store holds it.
    init(store: PairingStore, onPair: @escaping (RemotePairing) -> Void = { _ in }) {
        self.store = store
        self.onPair = onPair
    }

    var body: some View {
        VStack(spacing: 12) {
            // One inset group, as a settings list draws its rows.
            VStack(spacing: 0) {
                TextField("Name", text: $draft.name)
                    .padding(12)
                Divider()
                    .padding(.leading, 12)
                TextField("Setup Code", text: $draft.setupCode)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .onSubmit(pair)
                    .padding(12)
                Divider()
                    .padding(.leading, 12)
                TextField("Account Name (Optional)", text: $draft.accountName)
                    .onSubmit(pair)
                    .padding(12)
            }
            .textFieldStyle(.plain)
            .background(.background, in: .rect(cornerRadius: 12))
            Button(action: pair) {
                Group {
                    if draft.isPairing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Pair")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!draft.canPair)
            if let error = draft.error {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
        }
    }

    private func pair() {
        draft.pair(with: store, onPair: onPair)
    }
}

/// Stands in for the web UI while there is no server to show it for.
struct PairingView: View {
    let store: PairingStore
    let onPair: (RemotePairing) -> Void

    init(store: PairingStore, onPair: @escaping (RemotePairing) -> Void = { _ in }) {
        self.store = store
        self.onPair = onPair
    }

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                Text("Pair with Cohesion")
                    .font(.title2.bold())
                Text("Enter a setup code to connect this device to your Cohesion server.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            PairingForm(store: store, onPair: onPair)
        }
        .frame(maxWidth: 360)
        .padding(32)
        .background(.fill.quaternary, in: .rect(cornerRadius: 24))
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
