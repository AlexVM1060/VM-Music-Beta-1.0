import Flutter
import UIKit
import Vision
import CoreImage
import MediaPlayer
import Intents
import AppIntents

private let siriPlayPendingKey = "com.vm.music.beta.pending_siri_play"

private func enqueueSiriPlayRequest(song: String, artist: String?) {
  let cleanedSong = song.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !cleanedSong.isEmpty else { return }
  let cleanedArtist = (artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  let query = cleanedArtist.isEmpty ? cleanedSong : "\(cleanedSong) \(cleanedArtist)"

  var payload: [String: Any] = [
    "song": cleanedSong,
    "query": query,
    "timestampMs": Int(Date().timeIntervalSince1970 * 1000)
  ]
  if !cleanedArtist.isEmpty {
    payload["artist"] = cleanedArtist
  }
  UserDefaults.standard.set(payload, forKey: siriPlayPendingKey)
}

private func parseSiriSongAndArtist(from query: String) -> (song: String, artist: String?) {
  let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !cleaned.isEmpty else { return ("", nil) }

  let separators = [" de ", " by "]
  for separator in separators {
    if let range = cleaned.range(
      of: separator,
      options: [.caseInsensitive, .diacriticInsensitive]
    ) {
      let song = String(cleaned[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
      let artist = String(cleaned[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
      if !song.isEmpty && !artist.isEmpty {
        return (song, artist)
      }
    }
  }
  return (cleaned, nil)
}

@available(iOS 16.0, *)
struct PlaySongWithVMMusicIntent: AppIntent {
  static var title: LocalizedStringResource = "Reproducir canción en VM Music"
  static var description = IntentDescription(
    "Busca la canción y reproduce la coincidencia más relevante en VM Music."
  )
  static var openAppWhenRun: Bool = true

  @Parameter(title: "Canción o búsqueda")
  var query: String

  static var parameterSummary: some ParameterSummary {
    Summary("Reproducir \(\.$query)")
  }

  func perform() async throws -> some IntentResult & ProvidesDialog {
    let parsed = parseSiriSongAndArtist(from: query)
    guard !parsed.song.isEmpty else {
      return .result(dialog: "Dime el nombre de la canción.")
    }
    enqueueSiriPlayRequest(song: parsed.song, artist: parsed.artist)
    if let artist = parsed.artist, !artist.isEmpty {
      return .result(dialog: "Reproduciendo \(parsed.song) de \(artist) en VM Music.")
    }
    return .result(dialog: "Reproduciendo \(parsed.song) en VM Music.")
  }
}

@available(iOS 16.0, *)
struct VMMusicAppShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: PlaySongWithVMMusicIntent(),
      phrases: [
        "Reproduce una canción en \(.applicationName)",
        "Pon música en \(.applicationName)",
        "Play music on \(.applicationName)"
      ],
      shortTitle: "Reproducir canción",
      systemImageName: "music.note"
    )
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let artworkCutoutChannelName = "com.vm.music.beta/artwork_cutout"
  private let lockScreenFavoriteChannelName = "com.vm.music.beta/ios_lock_screen_favorite"
  private let songShareChannelName = "com.vm.music.beta/song_share"
  private let siriControlChannelName = "com.vm.music.beta/siri"
  private let powerModeChannelName = "com.vm.music.beta/power_mode"
  private let appleMusicMigrationChannelName = "com.vm.music.beta/apple_music_migration"
  private let backgroundTaskChannelName = "com.vm.music.beta/background_task"
  private let sharedSongPendingKey = "com.vm.music.beta.pending_shared_song"
  private let ciContext = CIContext(options: nil)
  private var lockScreenFavoriteChannel: FlutterMethodChannel?
  private var songShareChannel: FlutterMethodChannel?
  private var siriControlChannel: FlutterMethodChannel?
  private var powerModeChannel: FlutterMethodChannel?
  private var activeBackgroundTasks: [String: UIBackgroundTaskIdentifier] = [:]

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if let registrar = self.registrar(forPlugin: "ArtworkCutoutChannelPlugin") {
      let channel = FlutterMethodChannel(
        name: artworkCutoutChannelName,
        binaryMessenger: registrar.messenger()
      )
      channel.setMethodCallHandler { [weak self] call, result in
        self?.handleArtworkCutout(call: call, result: result)
      }
    }

    if let registrar = self.registrar(forPlugin: "LockScreenFavoriteChannelPlugin") {
      let channel = FlutterMethodChannel(
        name: lockScreenFavoriteChannelName,
        binaryMessenger: registrar.messenger()
      )
      lockScreenFavoriteChannel = channel
      channel.setMethodCallHandler { [weak self] call, result in
        self?.handleLockScreenFavorite(call: call, result: result)
      }
      configureLockScreenFavoriteCommands()
    }

    if let registrar = self.registrar(forPlugin: "SongShareChannelPlugin") {
      let channel = FlutterMethodChannel(
        name: songShareChannelName,
        binaryMessenger: registrar.messenger()
      )
      songShareChannel = channel
      channel.setMethodCallHandler { [weak self] call, result in
        self?.handleSongShare(call: call, result: result)
      }
    }

    if let registrar = self.registrar(forPlugin: "SiriControlChannelPlugin") {
      let channel = FlutterMethodChannel(
        name: siriControlChannelName,
        binaryMessenger: registrar.messenger()
      )
      siriControlChannel = channel
      channel.setMethodCallHandler { [weak self] call, result in
        self?.handleSiriControl(call: call, result: result)
      }
    }

    if let registrar = self.registrar(forPlugin: "PowerModeChannelPlugin") {
      let channel = FlutterMethodChannel(
        name: powerModeChannelName,
        binaryMessenger: registrar.messenger()
      )
      powerModeChannel = channel
      channel.setMethodCallHandler { [weak self] call, result in
        self?.handlePowerMode(call: call, result: result)
      }
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(handlePowerModeChangedNotification),
        name: Notification.Name.NSProcessInfoPowerStateDidChange,
        object: nil
      )
    }

    if let registrar = self.registrar(forPlugin: "AppleMusicMigrationChannelPlugin") {
      let channel = FlutterMethodChannel(
        name: appleMusicMigrationChannelName,
        binaryMessenger: registrar.messenger()
      )
      channel.setMethodCallHandler { [weak self] call, result in
        self?.handleAppleMusicMigration(call: call, result: result)
      }
    }

    if let registrar = self.registrar(forPlugin: "BackgroundTaskChannelPlugin") {
      let channel = FlutterMethodChannel(
        name: backgroundTaskChannelName,
        binaryMessenger: registrar.messenger()
      )
      channel.setMethodCallHandler { [weak self] call, result in
        self?.handleBackgroundTask(call: call, result: result)
      }
    }

    if let launchUrl = launchOptions?[.url] as? URL {
      _ = captureSharedSong(from: launchUrl)
    }

    GeneratedPluginRegistrant.register(with: self)
    if #available(iOS 16.0, *) {
      VMMusicAppShortcuts.updateAppShortcutParameters()
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  deinit {
    NotificationCenter.default.removeObserver(
      self,
      name: Notification.Name.NSProcessInfoPowerStateDidChange,
      object: nil
    )
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey : Any] = [:]
  ) -> Bool {
    if captureSharedSong(from: url) {
      return true
    }
    return super.application(app, open: url, options: options)
  }

  private func configureLockScreenFavoriteCommands() {
    let commandCenter = MPRemoteCommandCenter.shared()

    commandCenter.likeCommand.isEnabled = true
    commandCenter.likeCommand.localizedTitle = "Favorito"
    commandCenter.likeCommand.addTarget { [weak self] _ in
      self?.notifyLockScreenFavoritePressed(source: "like")
      return .success
    }

    if #available(iOS 9.1, *) {
      commandCenter.bookmarkCommand.isEnabled = true
      commandCenter.bookmarkCommand.localizedTitle = "Favorito"
      commandCenter.bookmarkCommand.addTarget { [weak self] _ in
        self?.notifyLockScreenFavoritePressed(source: "bookmark")
        return .success
      }
    }
  }

  private func notifyLockScreenFavoritePressed(source: String) {
    DispatchQueue.main.async { [weak self] in
      self?.lockScreenFavoriteChannel?.invokeMethod(
        "onFavoritePressed",
        arguments: ["source": source]
      )
    }
  }

  private func handleLockScreenFavorite(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "setFavoriteState" else {
      result(FlutterMethodNotImplemented)
      return
    }
    let args = call.arguments as? [String: Any]
    let enabled = (args?["enabled"] as? Bool) ?? true
    let isFavorite = (args?["isFavorite"] as? Bool) ?? false
    let title = ((args?["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
      ? (args?["title"] as? String ?? "Favorito")
      : "Favorito"

    let commandCenter = MPRemoteCommandCenter.shared()
    commandCenter.likeCommand.isEnabled = enabled
    commandCenter.likeCommand.localizedTitle = title
    commandCenter.likeCommand.isActive = isFavorite

    if #available(iOS 9.1, *) {
      commandCenter.bookmarkCommand.isEnabled = enabled
      commandCenter.bookmarkCommand.localizedTitle = title
      commandCenter.bookmarkCommand.isActive = isFavorite
    }
    result(nil)
  }

  private func handleSongShare(call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "consumePendingSharedSong" {
      let defaults = UserDefaults.standard
      let payload = defaults.dictionary(forKey: sharedSongPendingKey)
      defaults.removeObject(forKey: sharedSongPendingKey)
      result(payload)
      return
    }
    result(FlutterMethodNotImplemented)
  }

  private func handleSiriControl(call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "consumePendingSiriPlayRequest" {
      let defaults = UserDefaults.standard
      let payload = defaults.dictionary(forKey: siriPlayPendingKey)
      defaults.removeObject(forKey: siriPlayPendingKey)
      result(payload)
      return
    }
    result(FlutterMethodNotImplemented)
  }

  private func handlePowerMode(call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "getLowPowerModeEnabled" {
      result(ProcessInfo.processInfo.isLowPowerModeEnabled)
      return
    }
    result(FlutterMethodNotImplemented)
  }

  @objc private func handlePowerModeChangedNotification() {
    let enabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    DispatchQueue.main.async { [weak self] in
      self?.powerModeChannel?.invokeMethod("onPowerModeChanged", arguments: enabled)
    }
  }

  private func captureSharedSong(from url: URL) -> Bool {
    let parsed = parseSharedSongPayload(from: url)
    guard let payload = parsed else { return false }
    UserDefaults.standard.set(payload, forKey: sharedSongPendingKey)
    DispatchQueue.main.async { [weak self] in
      self?.songShareChannel?.invokeMethod("onSharedSongReceived", arguments: payload)
    }
    return true
  }

  private func parseSharedSongPayload(from url: URL) -> [String: Any]? {
    if let scheme = url.scheme?.lowercased(),
       scheme == "vmmusic",
       url.host?.lowercased() == "song",
       let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
      let items = comps.queryItems ?? []
      let map = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
      let videoId = (map["videoId"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if videoId.isEmpty { return nil }
      let title = (map["title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let artist = (map["artist"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let thumbnailUrl = (map["thumbnailUrl"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      var payload: [String: Any] = [
        "videoId": videoId,
        "title": title,
        "artist": artist,
        "thumbnailUrl": thumbnailUrl,
        "timestampMs": Int(Date().timeIntervalSince1970 * 1000)
      ]
      if let durationRaw = map["durationMs"],
         let durationMs = Int(durationRaw),
         durationMs > 0 {
        payload["durationMs"] = durationMs
      }
      return payload
    }

    let ext = url.pathExtension.lowercased()
    guard ext == "vmsong" || ext == "json" else { return nil }
    let hasAccess = url.startAccessingSecurityScopedResource()
    defer {
      if hasAccess {
        url.stopAccessingSecurityScopedResource()
      }
    }
    guard let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    let type = (json["type"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if !type.isEmpty && type != "vm_music_song" {
      return nil
    }
    let videoId = (json["videoId"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if videoId.isEmpty { return nil }
    let title = (json["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let artist = (json["artist"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let thumbnailUrl = (json["thumbnailUrl"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    var payload: [String: Any] = [
      "videoId": videoId,
      "title": title,
      "artist": artist,
      "thumbnailUrl": thumbnailUrl,
      "timestampMs": Int(Date().timeIntervalSince1970 * 1000)
    ]
    if let durationMs = json["durationMs"] as? NSNumber {
      payload["durationMs"] = durationMs
    }
    return payload
  }

  private func handleAppleMusicMigration(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getAuthorizationStatus":
      result(mediaLibraryAuthorizationLabel(status: MPMediaLibrary.authorizationStatus()))
    case "requestAuthorization":
      MPMediaLibrary.requestAuthorization { status in
        DispatchQueue.main.async {
          result(self.mediaLibraryAuthorizationLabel(status: status))
        }
      }
    case "fetchUserPlaylists":
      guard MPMediaLibrary.authorizationStatus() == .authorized else {
        result(
          FlutterError(
            code: "not_authorized",
            message: "Apple Music no está autorizado.",
            details: nil
          )
        )
        return
      }
      result(fetchMediaLibraryPlaylists())
    case "fetchPlaylistTracks":
      guard MPMediaLibrary.authorizationStatus() == .authorized else {
        result(
          FlutterError(
            code: "not_authorized",
            message: "Apple Music no está autorizado.",
            details: nil
          )
        )
        return
      }
      guard let args = call.arguments as? [String: Any],
            let rawPlaylistId = (args["playlistId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawPlaylistId.isEmpty,
            let playlistId = UInt64(rawPlaylistId) else {
        result(
          FlutterError(
            code: "invalid_args",
            message: "playlistId es obligatorio.",
            details: nil
          )
        )
        return
      }
      result(fetchTracksForPlaylist(playlistId: playlistId))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func mediaLibraryAuthorizationLabel(status: MPMediaLibraryAuthorizationStatus) -> String {
    switch status {
    case .authorized:
      return "authorized"
    case .denied:
      return "denied"
    case .restricted:
      return "restricted"
    case .notDetermined:
      return "notDetermined"
    @unknown default:
      return "notDetermined"
    }
  }

  private func handleBackgroundTask(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "beginTask":
      let args = call.arguments as? [String: Any]
      let requestedName = (args?["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      let taskName = (requestedName?.isEmpty == false) ? requestedName! : "vm_music_background_task"
      let token = UUID().uuidString
      var identifier: UIBackgroundTaskIdentifier = .invalid
      identifier = UIApplication.shared.beginBackgroundTask(withName: taskName) { [weak self] in
        guard let self else { return }
        let pending = self.activeBackgroundTasks[token] ?? .invalid
        if pending != .invalid {
          UIApplication.shared.endBackgroundTask(pending)
        }
        self.activeBackgroundTasks.removeValue(forKey: token)
      }
      if identifier == .invalid {
        result(nil)
        return
      }
      activeBackgroundTasks[token] = identifier
      result(token)
    case "endTask":
      guard let args = call.arguments as? [String: Any],
            let token = (args["token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty else {
        result(nil)
        return
      }
      let identifier = activeBackgroundTasks[token] ?? .invalid
      if identifier != .invalid {
        UIApplication.shared.endBackgroundTask(identifier)
      }
      activeBackgroundTasks.removeValue(forKey: token)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func fetchMediaLibraryPlaylists() -> [[String: Any]] {
    let query = MPMediaQuery.playlists()
    let collections = query.collections ?? []
    var output: [[String: Any]] = []
    output.reserveCapacity(collections.count)

    for collection in collections {
      guard let playlist = collection as? MPMediaPlaylist else { continue }
      let name = (playlist.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if name.isEmpty { continue }
      var payload: [String: Any] = [
        "id": String(playlist.persistentID),
        "name": name,
        "trackCount": playlist.count
      ]
      if let artworkBase64 = playlistArtworkBase64(playlist: playlist) {
        payload["artworkBase64"] = artworkBase64
      }
      output.append(payload)
    }

    output.sort { left, right in
      let leftName = (left["name"] as? String ?? "").lowercased()
      let rightName = (right["name"] as? String ?? "").lowercased()
      return leftName < rightName
    }
    return output
  }

  private func playlistArtworkBase64(playlist: MPMediaPlaylist) -> String? {
    guard let artwork = playlist.representativeItem?.artwork else { return nil }
    let targetSize = CGSize(width: 240, height: 240)
    guard let image = artwork.image(at: targetSize),
          let imageData = image.jpegData(compressionQuality: 0.86) else {
      return nil
    }
    return imageData.base64EncodedString()
  }

  private func fetchTracksForPlaylist(playlistId: UInt64) -> [[String: Any]] {
    let query = MPMediaQuery.playlists()
    let collections = query.collections ?? []
    guard let playlist = collections
      .compactMap({ $0 as? MPMediaPlaylist })
      .first(where: { $0.persistentID == playlistId }) else {
      return []
    }

    let items = playlist.items
    var output: [[String: Any]] = []
    output.reserveCapacity(items.count)

    for item in items {
      let title = (item.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if title.isEmpty { continue }
      let artist = (item.artist ?? item.albumArtist ?? "Artista desconocido")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let album = (item.albumTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      output.append([
        "title": title,
        "artist": artist.isEmpty ? "Artista desconocido" : artist,
        "album": album
      ])
    }

    return output
  }

  private func handleArtworkCutout(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "extractSubjectCutout" else {
      result(FlutterMethodNotImplemented)
      return
    }

    guard #available(iOS 17.0, *) else {
      result(nil)
      return
    }

    guard let args = call.arguments as? [String: Any],
          let bytes = args["bytes"] as? FlutterStandardTypedData else {
      result(nil)
      return
    }
    let zoom = (args["viewportZoom"] as? NSNumber)?.doubleValue ?? 1.0

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let output = self?.extractSubjectCutout(bytes: bytes.data, viewportZoom: CGFloat(zoom))
      DispatchQueue.main.async {
        if let data = output, !data.isEmpty {
          result(FlutterStandardTypedData(bytes: data))
        } else {
          result(nil)
        }
      }
    }
  }

  @available(iOS 17.0, *)
  private func extractSubjectCutout(bytes: Data, viewportZoom: CGFloat) -> Data? {
    guard let image = UIImage(data: bytes), let cgImage = image.cgImage else {
      return nil
    }
    guard let prepared = prepareViewportImage(cgImage: cgImage, zoom: viewportZoom) else {
      return nil
    }

    let request = VNGenerateForegroundInstanceMaskRequest()
    let handler = VNImageRequestHandler(cgImage: prepared, options: [:])
    do {
      try handler.perform([request])
      guard let observation = request.results?.first else { return nil }
      let instances = observation.allInstances
      guard !instances.isEmpty else { return nil }

      let maskBuffer = try observation.generateScaledMaskForImage(
        forInstances: instances,
        from: handler
      )
      let inputCI = CIImage(cgImage: prepared)
      let rawMaskCI = CIImage(cvPixelBuffer: maskBuffer)
      let maskCI = rawMaskCI.applyingFilter(
        "CIColorMatrix",
        parameters: [
          "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
          "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
          "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
          "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1.28),
          "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: -0.14)
        ]
      )
      let clearBG = CIImage(color: .clear).cropped(to: inputCI.extent)
      let outputCI = inputCI.applyingFilter(
        "CIBlendWithMask",
        parameters: [
          kCIInputMaskImageKey: maskCI,
          kCIInputBackgroundImageKey: clearBG
        ]
      )
      guard let outCG = ciContext.createCGImage(outputCI, from: inputCI.extent) else {
        return nil
      }
      return UIImage(cgImage: outCG).pngData()
    } catch {
      return nil
    }
  }

  private func prepareViewportImage(cgImage: CGImage, zoom: CGFloat) -> CGImage? {
    let width = cgImage.width
    let height = cgImage.height
    let side = min(width, height)
    guard side > 0 else { return nil }

    let squareX = (width - side) / 2
    let squareY = (height - side) / 2
    guard let square = cgImage.cropping(to: CGRect(x: squareX, y: squareY, width: side, height: side)) else {
      return nil
    }

    let clampedZoom = max(1.0, min(2.4, zoom))
    guard clampedZoom > 1.001 else { return square }

    let innerSide = max(24, min(side, Int(CGFloat(side) / clampedZoom)))
    let innerX = (side - innerSide) / 2
    let innerY = (side - innerSide) / 2
    guard let zoomCrop = square.cropping(to: CGRect(x: innerX, y: innerY, width: innerSide, height: innerSide)) else {
      return square
    }

    let format = UIGraphicsImageRendererFormat.default()
    format.opaque = false
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
    let rendered = renderer.image { _ in
      UIImage(cgImage: zoomCrop).draw(in: CGRect(x: 0, y: 0, width: side, height: side))
    }
    return rendered.cgImage ?? zoomCrop
  }
}
