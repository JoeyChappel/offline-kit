import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The can't-miss alert at the top of Ask when someone may be in danger.
/// Full size when someone pressed Emergency; smaller, and dismissible, when the words of a question raised it.
struct EmergencyBanner: View {
    let alert: EmergencyAlert
    /// A question has been asked, so steps are (or will be) below.
    var asked = true
    let showNumbers: () -> Void
    let done: () -> Void

    var body: some View {
        if alert.detected { compact } else { full }
    }

    private var detail: String { asked ? alert.detail : EmergencyAlert.waitingDetail }

    private var full: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(alert.headline).font(.system(.title, design: .rounded, weight: .bold))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .accessibilityAddTraits(.isHeader)
            Text(detail).font(.title3)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { callAction(.title2); numbersButton; doneButton }
                VStack(alignment: .leading, spacing: 10) {
                    callAction(.title2)
                    HStack(spacing: 10) { numbersButton; doneButton }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.red, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onAppear { getAttention(critical: true) }
    }

    /// Raised by a question's words: the same advice, smaller, with a close button.
    private var compact: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.title2)
            VStack(alignment: .leading, spacing: 6) {
                Text(alert.headline).font(.system(.title3, design: .rounded, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Text(detail).font(.callout)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { callAction(.headline); numbersButton.controlSize(.regular) }
                    VStack(alignment: .leading, spacing: 8) { callAction(.headline); numbersButton.controlSize(.regular) }
                }
            }
            Spacer(minLength: 0)
            Button(action: done) { Image(systemName: "xmark").font(.headline) }
                .buttonStyle(.borderless)
                .help("Close this alert. Answers go back to normal.")
                .accessibilityLabel("Close emergency alert")
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.red, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onAppear { getAttention(critical: false) }
    }

    private static let red = Color(red: 0.72, green: 0.08, blue: 0.08)

    /// On iPhone, a real call button. On a Mac, which can't call, plain words: nothing that looks clickable.
    @ViewBuilder private func callAction(_ font: Font) -> some View {
        #if os(iOS)
        if let url = URL(string: "tel:\(alert.dial)") {
            Link(destination: url) {
                Label(alert.numberLabel, systemImage: "phone.fill").font(font.bold())
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(.white, in: Capsule()).foregroundStyle(Self.red)
            }
        }
        #else
        Label("Call \(alert.number) from any phone", systemImage: "phone.fill")
            .font(font.bold())
            .accessibilityAddTraits(.isStaticText)
        #endif
    }

    private var numbersButton: some View {
        Button(action: showNumbers) { Label("Emergency Numbers", systemImage: "list.bullet").font(.headline) }
            .buttonStyle(.bordered).tint(.white).controlSize(.large)
            .help("Poison Help, 988, the Disaster Distress Helpline and radio channels")
    }

    private var doneButton: some View {
        Button(action: done) { Text("I’m Safe Now").font(.headline) }
            .buttonStyle(.bordered).tint(.white).controlSize(.large)
            .help("Close the alert and go back to normal answers")
    }

    private func getAttention(critical: Bool) {
        #if os(iOS)
        if critical { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
        UIAccessibility.post(notification: .announcement, argument: alert.headline)
        #else
        if critical { NSApp.requestUserAttention(.criticalRequest) }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: alert.headline, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        #endif
    }
}
