import SwiftUI

/// Colors for the drop-down sections. Each section gets its own.
enum SectionColor {
    static let drone  = Color(red: 0.49, green: 0.23, blue: 0.93)   // purple
    // Ready for future sections:
    static let blue   = Color(red: 0.16, green: 0.47, blue: 0.96)
    static let orange = Color(red: 0.96, green: 0.52, blue: 0.13)
    static let green  = Color(red: 0.13, green: 0.66, blue: 0.38)
    static let pink   = Color(red: 0.91, green: 0.27, blue: 0.56)
    static let teal   = Color(red: 0.10, green: 0.65, blue: 0.70)
}

/// A colored drop-down section: click the header to open or close it.
/// Remembers whether it was open, separately for each `key`.
struct ColorSection<Content: View>: View {
    let title: String
    let icon: String
    let color: Color
    @AppStorage private var expanded: Bool
    private let content: Content

    init(_ title: String, icon: String, color: Color, key: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.color = color
        self._expanded = AppStorage(wrappedValue: true, "section.open." + key)
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: icon).font(.title3)
                    Text(title).font(.title3.bold())
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.body.bold())
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(color)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 18) { content }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(color.opacity(0.06))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.55), lineWidth: 1.5))
    }
}
