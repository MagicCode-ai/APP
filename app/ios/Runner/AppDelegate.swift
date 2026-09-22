import Flutter
import Network
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var localNetworkBrowser: NWBrowser?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    requestLocalNetworkAccess()
    application.isIdleTimerDisabled = true
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// iOS 重装后会清掉「本地网络」授权。Dart HttpClient 走 BSD socket，
  /// 未授权时直接 ClientException，系统弹窗不一定出现。先 browse 一下触发提示。
  private func requestLocalNetworkAccess() {
    let browser = NWBrowser(for: .bonjour(type: "_http._tcp", domain: "local."), using: .tcp)
    browser.stateUpdateHandler = { _ in }
    browser.start(queue: .main)
    localNetworkBrowser = browser
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
      self?.localNetworkBrowser?.cancel()
      self?.localNetworkBrowser = nil
    }
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MagicStreamingPlugin") {
      MagicStreamingPlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MagicSrPlugin") {
      MagicSrPlugin.register(with: registrar)
    }
  }
}
