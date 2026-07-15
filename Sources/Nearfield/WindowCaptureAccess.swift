import CoreGraphics

enum WindowCaptureAccess {
    static func isGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}
