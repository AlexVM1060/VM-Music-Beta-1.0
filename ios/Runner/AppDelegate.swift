import Flutter
import UIKit
import Vision
import CoreImage
import Speech
import MediaPlayer

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let artworkCutoutChannelName = "com.vm.music.beta/artwork_cutout"
  private let liveLyricsAlignmentChannelName = "com.vm.music.beta/ios_live_lyrics_alignment"
  private let lockScreenFavoriteChannelName = "com.vm.music.beta/ios_lock_screen_favorite"
  private let siriPlaybackChannelName = "com.vm.music.beta/siri_playback"
  private let appleMusicMigrationChannelName = "com.vm.music.beta/apple_music_migration"
  private let siriPlaybackPendingKey = "com.vm.music.beta.pending_siri_playback"
  private let ciContext = CIContext(options: nil)
  private var liveLyricsTask: SFSpeechRecognitionTask?
  private var lockScreenFavoriteChannel: FlutterMethodChannel?
  private var siriPlaybackChannel: FlutterMethodChannel?

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

    if let registrar = self.registrar(forPlugin: "LiveLyricsAlignmentChannelPlugin") {
      let channel = FlutterMethodChannel(
        name: liveLyricsAlignmentChannelName,
        binaryMessenger: registrar.messenger()
      )
      channel.setMethodCallHandler { [weak self] call, result in
        self?.handleLiveLyricsAlignment(call: call, result: result)
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

    if let registrar = self.registrar(forPlugin: "SiriPlaybackChannelPlugin") {
      let channel = FlutterMethodChannel(
        name: siriPlaybackChannelName,
        binaryMessenger: registrar.messenger()
      )
      siriPlaybackChannel = channel
      channel.setMethodCallHandler { [weak self] call, result in
        self?.handleSiriPlayback(call: call, result: result)
      }
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

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
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

  private func handleSiriPlayback(call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "consumePendingSiriPlayRequest" {
      let defaults = UserDefaults.standard
      let payload = defaults.dictionary(forKey: siriPlaybackPendingKey)
      defaults.removeObject(forKey: siriPlaybackPendingKey)
      result(payload)
      return
    }
    result(FlutterMethodNotImplemented)
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

  private func fetchMediaLibraryPlaylists() -> [[String: Any]] {
    let query = MPMediaQuery.playlists()
    let collections = query.collections ?? []
    var output: [[String: Any]] = []
    output.reserveCapacity(collections.count)

    for collection in collections {
      guard let playlist = collection as? MPMediaPlaylist else { continue }
      let name = (playlist.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if name.isEmpty { continue }
      output.append([
        "id": String(playlist.persistentID),
        "name": name,
        "trackCount": playlist.count
      ])
    }

    output.sort { left, right in
      let leftName = (left["name"] as? String ?? "").lowercased()
      let rightName = (right["name"] as? String ?? "").lowercased()
      return leftName < rightName
    }
    return output
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

  @MainActor
  static func storePendingSiriPlayback(song: String, artist: String) {
    let cleanSong = song.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanSong.isEmpty else { return }
    let payload: [String: Any] = [
      "song": cleanSong,
      "artist": cleanArtist,
      "timestampMs": Int(Date().timeIntervalSince1970 * 1000)
    ]
    UserDefaults.standard.set(payload, forKey: "com.vm.music.beta.pending_siri_playback")
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

  private func handleLiveLyricsAlignment(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "transcribeLocalFile" else {
      result(FlutterMethodNotImplemented)
      return
    }

    guard #available(iOS 13.0, *) else {
      result(FlutterError(code: "unsupported_ios", message: "Requires iOS 13+", details: nil))
      return
    }

    guard let args = call.arguments as? [String: Any],
          let path = args["filePath"] as? String else {
      result(FlutterError(code: "invalid_args", message: "filePath is required", details: nil))
      return
    }

    let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedPath.isEmpty else {
      result(FlutterError(code: "invalid_args", message: "filePath is empty", details: nil))
      return
    }
    guard FileManager.default.fileExists(atPath: normalizedPath) else {
      result(FlutterError(code: "file_not_found", message: "Audio file not found", details: nil))
      return
    }

    requestSpeechAuthorization { [weak self] authorized in
      guard let self else { return }
      guard authorized else {
        DispatchQueue.main.async {
          result(FlutterError(code: "speech_denied", message: "Speech recognition denied", details: nil))
        }
        return
      }
      self.transcribeLocalFile(path: normalizedPath, flutterResult: result)
    }
  }

  private func requestSpeechAuthorization(_ completion: @escaping (Bool) -> Void) {
    if #available(iOS 13.0, *) {
      let status = SFSpeechRecognizer.authorizationStatus()
      switch status {
      case .authorized:
        completion(true)
      case .denied, .restricted:
        completion(false)
      case .notDetermined:
        SFSpeechRecognizer.requestAuthorization { auth in
          completion(auth == .authorized)
        }
      @unknown default:
        completion(false)
      }
    } else {
      completion(false)
    }
  }

  @available(iOS 13.0, *)
  private func transcribeLocalFile(path: String, flutterResult: @escaping FlutterResult) {
    liveLyricsTask?.cancel()
    liveLyricsTask = nil

    let localeCandidates: [Locale] = [
      Locale.current,
      Locale(identifier: "es-MX"),
      Locale(identifier: "es-ES"),
      Locale(identifier: "en-US")
    ]
    guard let recognizer = localeCandidates.compactMap({ SFSpeechRecognizer(locale: $0) }).first else {
      flutterResult(FlutterError(code: "recognizer_unavailable", message: "No speech recognizer available", details: nil))
      return
    }

    guard recognizer.isAvailable else {
      flutterResult(FlutterError(code: "recognizer_unavailable", message: "Speech recognizer unavailable", details: nil))
      return
    }
    if recognizer.supportsOnDeviceRecognition == false {
      flutterResult(FlutterError(code: "on_device_unavailable", message: "On-device recognition unavailable", details: nil))
      return
    }

    let request = SFSpeechURLRecognitionRequest(url: URL(fileURLWithPath: path))
    request.shouldReportPartialResults = false
    request.requiresOnDeviceRecognition = true

    var didFinish = false
    liveLyricsTask = recognizer.recognitionTask(with: request) { [weak self] recognitionResult, error in
      guard !didFinish else { return }
      if let error = error {
        didFinish = true
        self?.liveLyricsTask = nil
        flutterResult(FlutterError(code: "recognition_failed", message: error.localizedDescription, details: nil))
        return
      }

      guard let recognitionResult = recognitionResult, recognitionResult.isFinal else {
        return
      }

      let words: [[String: Any]] = recognitionResult.bestTranscription.segments.map { segment in
        let startMs = Int((segment.timestamp * 1000.0).rounded())
        let endMs = Int(((segment.timestamp + segment.duration) * 1000.0).rounded())
        return [
          "word": segment.substring,
          "startMs": max(0, startMs),
          "endMs": max(max(0, startMs), endMs),
          "confidence": segment.confidence
        ]
      }

      didFinish = true
      self?.liveLyricsTask = nil
      flutterResult(words)
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
