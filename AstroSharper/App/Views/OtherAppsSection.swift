// Cross-promotion section — "More from joergsflow".
//
// Lists every sibling app (AppFamily.others) with an App Store link and a
// GitHub link, so a user of one app in the astro toolkit discovers the
// rest. Shared by SplashView and AboutView so the layout lives in exactly
// one place. Present in BOTH the Developer-ID and App Store builds —
// linking to other App Store apps is fully allowed and is not an
// external-payment link, so this is intentionally not gated by APP_STORE.
import SwiftUI
import AppKit

struct OtherAppsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("More from joergsflow")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            ForEach(AppFamily.others) { app in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(app.name)
                                .font(.system(size: 12, weight: .semibold))
                            Text(app.platform)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        Text(app.tagline)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    Button("App Store") { NSWorkspace.shared.open(app.appStore) }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                    if let gh = app.github {
                        Button("GitHub") { NSWorkspace.shared.open(gh) }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                    }
                }
            }
        }
    }
}
