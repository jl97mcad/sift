import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--cli" || arguments.first == "cli" {
    CLI.run(arguments: Array(arguments.dropFirst()))
}

MainActor.assumeIsolated {
    let demo = CommandLine.arguments.contains("--demo")
    let demoChat = CommandLine.arguments.contains("--demo-chat")
    let demoControl = CommandLine.arguments.contains("--demo-control")
    let demoSearch = CommandLine.arguments.contains("--demo-search")
    let app = NSApplication.shared
    let appDelegate = AppDelegate(demo: demo, openDemoChat: demoChat, openDemoControl: demoControl,
                                  openDemoSearch: demoSearch,
                                  demoNeedsYou: CommandLine.arguments.contains("--demo-needs-you"))
    app.delegate = appDelegate
    app.setActivationPolicy(.accessory)
    app.run()
}
