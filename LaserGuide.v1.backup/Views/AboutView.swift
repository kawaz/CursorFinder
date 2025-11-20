// AboutView.swift
import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    private var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "Unknown"
    }

    private var teamIdentifier: String {
        "3QMEVK549R"
    }

    private var organizationName: String {
        "ZunSystem Inc."
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Text("🔍")
                    .font(.system(size: 48))

                Text("LaserGuide")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Version \(appVersion)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 4) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(.green)
                        .imageScale(.small)

                    Text("Notarized by Apple")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()

            // Info section (compact)
            VStack(alignment: .leading, spacing: 6) {
                CompactInfoRow(label: "Bundle ID", value: bundleIdentifier)
                CompactInfoRow(label: "Code Signed", value: "\(organizationName) (\(teamIdentifier))")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)

            Divider()

            // Footer
            VStack(spacing: 8) {
                Text("© 2025 \(organizationName)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button(action: {
                    if let url = URL(string: "https://github.com/kawaz/LaserGuide") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "link")
                            .imageScale(.small)
                        Text("GitHub Repository")
                    }
                    .font(.caption)
                }
                .buttonStyle(.link)
            }
            .padding(.vertical, 12)
            .padding(.bottom, 4)
        }
        .frame(width: 380, height: 260)
    }
}

struct CompactInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label + ":")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .trailing)

            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()
        }
    }
}

// Preview
#Preview {
    AboutView()
}
