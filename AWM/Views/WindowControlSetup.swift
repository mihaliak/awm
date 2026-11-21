import AppKit
import SwiftUI

struct WindowControlSetup: View {
    let arrowAdvanced: Bool
    let allowWindowControl: () -> Void

    @Environment(\.menuReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        icon(Self.finderIcon, fallback: "folder.fill")
                            .measuredMenuRegion("Permission Finder icon")
                        icon(Self.appIcon, fallback: "app")
                            .measuredMenuRegion("Permission app icon")
                    }
                    Image(systemName: "arrow.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(MenuPalette.accent)
                        .measuredMenuRegion("Permission arrow")
                        .offset(x: arrowAdvanced || reduceMotion ? 6 : -6)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: arrowAdvanced)
                        .frame(width: 40)
                    icon(Self.settingsIcon, fallback: "gear")
                        .measuredMenuRegion("Permission Settings icon")
                }
                .accessibilityHidden(true)
                Text("In \(MacWindowSystem.permissionPaneName), turn on \(awmDisplayName). If it’s missing, use + to add the app shown in Finder.")
                    .font(.callout)
                    .foregroundStyle(MenuPalette.secondary)
                    .popoverProse()
                    .measuredMenuRegion("Permission instructions")
            }
            .padding(.horizontal, 10)
            Button(action: allowWindowControl) {
                MenuRowLabel("Allow Window Control…", icon: "lock.open")
            }
            .buttonStyle(MenuRowStyle(emphasized: true))
            .measuredMenuRegion("Allow Window Control row")
        }
        .measuredMenuRegion("Window Control Setup")
    }

    private static let appIcon = NSWorkspace.shared.icon(forFile: Bundle.main.bundleURL.path)
    private static let finderIcon = applicationIcon("com.apple.finder")
    private static let settingsIcon = applicationIcon("com.apple.systempreferences")

    private static func applicationIcon(_ bundleIdentifier: String) -> NSImage? {
        let workspace = NSWorkspace.shared
        return workspace.urlForApplication(withBundleIdentifier: bundleIdentifier).map { workspace.icon(forFile: $0.path) }
    }

    private func icon(_ image: NSImage?, fallback: String) -> some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: fallback)
                    .font(.system(size: 26))
                    .foregroundStyle(MenuPalette.secondary)
            }
        }
        .frame(width: 40, height: 40)
    }
}

struct WindowControlConfirmation: View {
    let finish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Thanks for using AWM")
                .font(.callout)
                .foregroundStyle(MenuPalette.secondary)
                .padding(.horizontal, 10)
                .measuredMenuRegion("Thanks for using AWM")
            Button(action: finish) {
                MenuRowLabel("Let’s start", icon: "arrow.right")
            }
            .buttonStyle(MenuRowStyle(emphasized: true))
            .keyboardShortcut(.defaultAction)
            .measuredMenuRegion("Finish Setup row")
        }
    }
}
