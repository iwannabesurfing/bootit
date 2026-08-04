import BootItKit

/// The whole executable target.
///
/// Everything BootIt does lives in `BootItKit`; this is the `@main` that starts
/// it. The split exists so the package can offer a scheme with no executable in
/// it, which is the only arrangement in which Xcode renders `#Preview` here —
/// see `BootItMain` for what was measured.
///
/// Keep this file as the only thing in the target. A second file here is a file
/// whose previews cannot render and whose types cannot be tested.
@main
enum Main {
    static func main() {
        BootItMain.run()
    }
}
