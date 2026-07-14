import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let messenger = flutterViewController.engine.binaryMessenger
    let foundationModelsHost = FoundationModelsHostApiImpl(binaryMessenger: messenger)
    FoundationModelsHostApiSetup.setUp(binaryMessenger: messenger, api: foundationModelsHost)

    super.awakeFromNib()
  }
}
