// ResizableHeight.swift
// IJSDashboardUI
//
// Wraps content (a table) in a user-resizable height: a drag handle below it lets
// you pull the table taller or shorter. Tables in the scrolling page need a
// bounded height, and this makes that bound adjustable.

#if canImport(SwiftUI)
import SwiftUI
import AppKit

struct ResizableHeight<Content: View>: View {
    private let minHeight: CGFloat
    private let content: Content

    @State private var height: CGFloat
    @State private var dragStart: CGFloat?

    init(initial: CGFloat, minHeight: CGFloat = 120, @ViewBuilder content: () -> Content) {
        self.minHeight = minHeight
        self._height = State(initialValue: initial)
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content.frame(height: height)
            handle
        }
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Color.secondary.opacity(0.35))
            .frame(width: 40, height: 4)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? height
                        if dragStart == nil { dragStart = height }
                        height = max(minHeight, (start + value.translation.height).rounded())
                    }
                    .onEnded { _ in dragStart = nil }
            )
    }
}

extension View {
    /// Makes this view's height user-resizable via a drag handle beneath it.
    func resizableHeight(initial: CGFloat, minHeight: CGFloat = 120) -> some View {
        ResizableHeight(initial: initial, minHeight: minHeight) { self }
    }
}
#endif
