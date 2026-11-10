import Foundation

/// The name a client registers with when the user hasn't typed one:
/// `<device> (<client>)`, as `MacBook Pro (Cohesion)`, so several clients on
/// one device can be told apart in Settings › Clients. With no device name it
/// is `cohesion (<client>)`. Mirrors `generated_client_name` in `cohesion-rs`;
/// the two must stay in step.
nonisolated func generatedClientName(device: String?, client: String) -> String {
    let device = device?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return "\(device.isEmpty ? "cohesion" : device) (\(client))"
}
