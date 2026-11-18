import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
    // run() 은 돌아오지 않지만 delegate 수명을 명시적으로 붙잡아 둔다.
    withExtendedLifetime(delegate) {}
}
