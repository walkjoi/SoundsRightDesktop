#if SWIFT_PACKAGE
import SwiftUI

// Command Line Tools-only build shim.
//
// The macOS 27 SDK ships `@State` as a `State()` macro (in SwiftUICore) that
// shadows the long-standing `State<Value>` property wrapper. Expanding that
// macro needs the `SwiftUIMacros` compiler plugin, which is bundled only with
// full Xcode — under Command Line Tools it is absent, so `swift build` fails
// with "external macro implementation type 'SwiftUIMacros.StateMacro' could
// not be found". A same-name local property wrapper cannot win over the macro
// in attribute resolution, so shadowing does not help.
//
// Instead, `Scripts/build-app.sh` compiles a copy of the sources in which every
// `@State` attribute is rewritten to `@CLTState`, and this property wrapper
// stands in for it. It composes the real `SwiftUI.State` (kept as a stored
// `DynamicProperty`, so SwiftUI still installs a storage location and drives
// view updates) and forwards `wrappedValue` / `$`-projection to it, giving
// behavior identical to `@State`. No compiler plugin required.
//
// Gated on `SWIFT_PACKAGE`: only the SwiftPM/CLT build defines it and performs
// the rewrite. Xcode builds have the plugin, keep the real `@State` macro, and
// compile this file to nothing.
@propertyWrapper
struct CLTState<Value>: DynamicProperty {
    private var base: SwiftUI.State<Value>

    init(wrappedValue value: Value) {
        base = SwiftUI.State(wrappedValue: value)
    }

    // Matches `_storage = State(initialValue:)` written in a view's `init`.
    init(initialValue value: Value) {
        self.init(wrappedValue: value)
    }

    var wrappedValue: Value {
        get { base.wrappedValue }
        nonmutating set { base.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> { base.projectedValue }
}
#endif
