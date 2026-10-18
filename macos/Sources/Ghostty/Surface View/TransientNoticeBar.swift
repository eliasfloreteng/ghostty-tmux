import SwiftUI

/// A one line notice over the bottom of a surface, styled like the bar
/// shown when a child process exits. It gets out of the way of the mouse,
/// since it sits over terminal content someone may want to click.
struct TransientNoticeBar: View {
    let notice: Ghostty.OSSurfaceView.TransientNotice
    @State private var isHovered: Bool = false

    var body: some View {
        Text(notice.text)
            .lineLimit(2)
            .truncationMode(.tail)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .center)
            .background(background)
            .foregroundColor(.primary)
            .contentShape(.rect)
            .accessibilityLabel(notice.text)
            .transition(.move(edge: .bottom))
            .opacity(isHovered ? 0 : 1)
            .allowsHitTesting(false)
            .overlay {
                Color.clear
                    .onHover {
                        isHovered = $0
                    }
            }
    }

    private var background: AnyShapeStyle {
        switch notice.level {
        case .info:
            AnyShapeStyle(.background)
        case .error:
            AnyShapeStyle(.red.opacity(0.5))
        }
    }
}
