import SwiftUI
import UIKit

/// Shared visual tokens and building blocks for every ApplicationLibrary screen.
enum ProxyCatUI {
    static let pageSpacing: CGFloat = 16
    static let pageHorizontalPadding: CGFloat = 16
    static let pageTopPadding: CGFloat = 12
    static let pageBottomPadding: CGFloat = 24
    static let cardPadding: CGFloat = 16
    static let cardCornerRadius: CGFloat = 14
    static let iconTileSize: CGFloat = 30

    static let pageBackground = Color(uiColor: .systemGroupedBackground)
    static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)
}

// MARK: - Page and card containers

struct ProxyCatCard: ViewModifier {
    var alignment: Alignment = .leading

    func body(content: Content) -> some View {
        content
            .padding(ProxyCatUI.cardPadding)
            .frame(maxWidth: .infinity, alignment: alignment)
            .background(
                RoundedRectangle(cornerRadius: ProxyCatUI.cardCornerRadius, style: .continuous)
                    .fill(ProxyCatUI.cardBackground)
            )
    }
}

extension View {
    func proxyCatCard(alignment: Alignment = .leading) -> some View {
        modifier(ProxyCatCard(alignment: alignment))
    }

    /// Standard padded, grouped page used by card-based screens.
    func proxyCatPage(
        topPadding: CGFloat = ProxyCatUI.pageTopPadding,
        bottomPadding: CGFloat = ProxyCatUI.pageBottomPadding
    ) -> some View {
        padding(.horizontal, ProxyCatUI.pageHorizontalPadding)
            .padding(.top, topPadding)
            .padding(.bottom, bottomPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(ProxyCatUI.pageBackground.ignoresSafeArea())
    }

    /// Keep native Forms but match the app's grouped page background.
    func proxyCatForm() -> some View {
        scrollContentBackground(.hidden)
            .background(ProxyCatUI.pageBackground.ignoresSafeArea())
    }
}

// MARK: - Rows and icons

struct ProxyCatIconTile: View {
    let systemImage: String
    var tint: Color = .accentColor
    var size: CGFloat = ProxyCatUI.iconTileSize

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(tint.opacity(0.14))
            )
            .accessibilityHidden(true)
    }
}

/// Settings-style navigation row with a tinted icon tile.
struct ProxyCatNavigationRow<Destination: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    var tint: Color = .accentColor
    var accessibilityID: String? = nil
    @ViewBuilder var destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                ProxyCatIconTile(systemImage: systemImage, tint: tint)
                Text(title)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier(if: accessibilityID)
    }
}

/// Compact tappable row used on the dashboard for Web UI / Proxies entries.
struct ProxyCatActionRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    var trailingImage: String = "chevron.right"
    var isEnabled: Bool = true

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.subheadline)
            Text(title)
                .font(.subheadline.weight(.medium))
            Spacer(minLength: 8)
            Image(systemName: trailingImage)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)
        .opacity(isEnabled ? 1 : 0.48)
        .contentShape(Rectangle())
    }
}

// MARK: - State views

struct ProxyCatMetricHeader: View {
    let title: LocalizedStringKey
    let systemImage: String
    let tint: Color
    var iconFont: Font = .subheadline
    var titleFont: Font = .caption.weight(.medium)

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(iconFont)
                .foregroundStyle(tint)
            Text(title)
                .font(titleFont)
                .foregroundStyle(.secondary)
        }
    }
}

/// Small tinted capsule used for protocol / kind / rule labels across
/// the dashboard, proxies, connections, and saved-log screens.
struct ProxyCatBadge: View {
    let text: String
    var tint: Color = .secondary
    var systemImage: String?
    var font: Font = .caption2.weight(.semibold)
    var horizontalPadding: CGFloat = 6
    var verticalPadding: CGFloat = 2

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
        }
        .font(font)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background(tint.opacity(0.18), in: Capsule())
        .foregroundStyle(tint)
    }
}

struct ProxyCatLoadingView: View {
    var body: some View {
        ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Inline red banner for load/save failures that should stay on screen.
struct ProxyCatInlineErrorBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ProxyCatUI.cardPadding)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: ProxyCatUI.cardCornerRadius, style: .continuous)
                    .fill(Color.red.opacity(0.12))
            )
    }
}

struct ProxyCatEmptyState: View {
    let title: String.LocalizationValue
    let systemImage: String
    var description: String.LocalizationValue?

    var body: some View {
        if let description {
            ContentUnavailableView(
                localizedTitle: title,
                systemImage: systemImage,
                localizedDescription: description
            )
        } else {
            ContentUnavailableView(localizedTitle: title, systemImage: systemImage)
        }
    }
}

/// Shared "could not load" state with an optional Retry action.
struct ProxyCatLoadFailureView: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label("Could not load", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            if let retry {
                Button("Retry", action: retry)
                    .buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - Localized ContentUnavailableView helpers

extension ContentUnavailableView where Label == SwiftUI.Label<Text, Image>, Description == Text?, Actions == EmptyView {
    init(localizedTitle title: String.LocalizationValue, systemImage: String, description: Text? = nil) {
        // Pre-resolve through the app catalog so framework-hosted empty states
        // do not fall back to English on ContentUnavailableView convenience paths.
        self.init(
            String(localized: title, bundle: .main),
            systemImage: systemImage,
            description: description
        )
    }

    init(
        localizedTitle title: String.LocalizationValue,
        systemImage: String,
        localizedDescription description: String.LocalizationValue
    ) {
        self.init(
            localizedTitle: title,
            systemImage: systemImage,
            description: Text(String(localized: description, bundle: .main))
        )
    }
}

extension View {
    @ViewBuilder
    func accessibilityIdentifier(if identifier: String?) -> some View {
        if let identifier {
            accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}
