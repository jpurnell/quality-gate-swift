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

// MARK: - Dead code that happens to be near SwiftUI (should still be flagged)

func deadNearSwiftUI() -> Int { 42 }
