import SwiftUI

enum ProxyCatUI {
    static let pageSpacing: CGFloat = 14
    static let pageHorizontalPadding: CGFloat = 16
    static let pageTopPadding: CGFloat = 12
    static let cardPadding: CGFloat = 14
    static let cardCornerRadius: CGFloat = 8
}

struct ProxyCatCard: ViewModifier {
    var alignment: Alignment = .leading

    func body(content: Content) -> some View {
        content
            .padding(ProxyCatUI.cardPadding)
            .frame(maxWidth: .infinity, alignment: alignment)
            .background(
                RoundedRectangle(cornerRadius: ProxyCatUI.cardCornerRadius, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
            )
    }
}

extension View {
    func proxyCatCard(alignment: Alignment = .leading) -> some View {
        modifier(ProxyCatCard(alignment: alignment))
    }
}

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
