/// The `kvotar` CLI ships as a bare SwiftPM executable — it has no app bundle / Info.plist,
/// so `Bundle.main` carries no version. The version is therefore a compiled constant.
///
/// Keep in sync with the app's Xcode build settings in `Kvotar.xcodeproj/project.pbxproj`:
///   `MARKETING_VERSION`  → `short`
///   `CURRENT_PROJECT_VERSION` → `build`
/// (Pre-Alpha bumps are rare and manual; a later step may have the build script stamp these.)
enum KvotarVersion {
    static let short = "0.2.0"
    static let build = "5"
    static var full: String { "\(short) (\(build))" }
}
