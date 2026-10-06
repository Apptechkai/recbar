import SwiftUI

/// SwiftUI's `State`, used as `@ViewState` instead of `@State`.
///
/// In the macOS 27 SDK, writing `@State` expands a macro whose plugin ships
/// only with Xcode, not with Apple's command line tools. The installer builds
/// with the command line tools, so `@State` fails there ("plugin for module
/// 'SwiftUIMacros' not found", then "'self' is immutable" wherever state is
/// set). The alias names the same property wrapper without the macro, so it
/// builds both ways.
typealias ViewState<Value> = SwiftUI.State<Value>
