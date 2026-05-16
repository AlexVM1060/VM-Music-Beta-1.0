import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private let videoPipChannelName = "com.vm.music.beta/video_pip"
  private var videoPipChannel: FlutterMethodChannel?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    let hostWindow = NSApp.windows.first
    guard
      let controller = hostWindow?.contentViewController as? FlutterViewController
    else { return }
    let channel = FlutterMethodChannel(
      name: videoPipChannelName,
      binaryMessenger: controller.engine.binaryMessenger
    )
    videoPipChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handleVideoPip(call: call, result: result)
    }
  }

  private func handleVideoPip(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "enterPictureInPicture" else {
      result(FlutterMethodNotImplemented)
      return
    }
    result(
      FlutterError(
        code: "PIP_UNSUPPORTED_ON_MACOS",
        message: "PiP nativo en macOS está desactivado temporalmente en este build.",
        details: nil
      )
    )
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
