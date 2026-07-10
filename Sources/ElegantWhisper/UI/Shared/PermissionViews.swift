import SwiftUI

struct PermissionStatusRow: View {
    let title: String
    let detail: String
    let granted: Bool

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? Color.green : Color.orange)
            Text(title).fontWeight(.medium)
            Spacer()
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

struct PermissionActionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.semibold)
                Text(granted ? "Granted" : detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button(granted ? "Open" : actionTitle, action: action)
        }
        .padding(.vertical, 5)
    }
}
