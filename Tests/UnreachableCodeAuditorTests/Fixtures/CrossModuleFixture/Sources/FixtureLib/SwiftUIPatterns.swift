// SwiftUI and Combine exist only on Apple platforms, and this fixture imported both
// unguarded. That made the whole fixture package uncompilable on Linux — and the fixture is
// built by the checker under test, so the failure did not look like a fixture problem. It
// looked like the index store was unavailable:
//
//   Cross-module pass skipped: swift build (index-store) failed:
//     SwiftUIPatterns.swift:1:8: error: no such module 'SwiftUI'
//
// On 6.4 that cost every index-backed test in the suite — six CrossModuleTests and
// SwiftUIAwarenessTests, all of which assert symbols defined in *other* files. On 6.2 the
// build failed too, but emitted units for the files that had already compiled, so only the
// executable target's symbol went missing: one failure instead of seven, from the same cause.
//
// The guard covers the SwiftUI-dependent declarations alone. `deadNearSwiftUI()` at the end of
// the file stays outside it on purpose: it is a plain function that happens to sit near SwiftUI
// code, which is the whole point of the test that asserts it is still flagged, and that test is
// not about SwiftUI at all.
#if canImport(SwiftUI)
import SwiftUI
import Combine

// MARK: - View with property wrappers (all should be kept alive)

public struct SampleView: View {
    @State private var count = 0
    @Binding var isPresented: Bool
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var viewModel: SampleViewModel

    let formatter = NumberFormatter()

    public init(isPresented: Binding<Bool>) {
        self._isPresented = isPresented
    }

    public var body: some View {
        VStack {
            Text("Count: \(count)")
            Button("Dismiss") { dismiss() }
            Text(viewModel.title)
            Text(formatter.string(from: NSNumber(value: count)) ?? "")
        }
    }

    private func helperMethod() -> String {
        "helper"
    }
}

// MARK: - ObservableObject with @Published

public class SampleViewModel: ObservableObject {
    @Published var title: String = "Hello"
    @Published var subtitle: String = "World"
}

// MARK: - View detected by body property (no explicit View in inheritance)

public struct InferredView: View {
    @State private var active = false

    public init() {}

    public var body: some View {
        Toggle("Active", isOn: $active)
    }
}

// MARK: - Scene conformance

public struct SampleScene: Scene {
    @State private var windowTitle = "Main"

    public init() {}

    public var body: some Scene {
        WindowGroup(windowTitle) {
            Text("content")
        }
    }
}

// MARK: - AppStorage

public struct PrefsView: View {
    @AppStorage("theme") var theme = "light"
    @SceneStorage("tab") var selectedTab = 0

    public init() {}

    public var body: some View {
        Text(theme)
    }
}

// MARK: - FocusState

public struct FocusView: View {
    @FocusState private var isFocused: Bool

    public init() {}

    public var body: some View {
        TextField("Name", text: .constant(""))
            .focused($isFocused)
    }
}

#endif

// MARK: - Dead code that happens to be near SwiftUI (should still be flagged)

func deadNearSwiftUI() -> Int { 42 }
