import AppIntents
import Foundation

@available(iOS 16.0, *)
struct VMMusicPlaySongIntent: AppIntent {
  static var title: LocalizedStringResource = "Reproducir Canción"
  static var description = IntentDescription(
    "Busca y reproduce una canción por título y artista en VM Music."
  )
  static var openAppWhenRun: Bool = true
  static var parameterSummary: some ParameterSummary {
    Summary("Reproducir \(\.$song) de \(\.$artist)")
  }

  @Parameter(
    title: "Canción",
    requestValueDialog: IntentDialog("¿Qué canción quieres reproducir?")
  )
  var song: String

  @Parameter(
    title: "Artista",
    default: "",
    requestValueDialog: IntentDialog("¿De qué artista?")
  )
  var artist: String

  func perform() async throws -> some IntentResult & ProvidesDialog {
    let cleanSong = song.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanSong.isEmpty else {
      return .result(dialog: "Necesito el nombre de la canción.")
    }

    await AppDelegate.storePendingSiriPlayback(song: cleanSong, artist: cleanArtist)
    let artistText = cleanArtist.isEmpty ? "" : " de \(cleanArtist)"
    return .result(dialog: "Reproduciendo \(cleanSong)\(artistText) en VM Music.")
  }
}

@available(iOS 16.0, *)
struct VMMusicAppShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: VMMusicPlaySongIntent(),
      phrases: [
        "Reproduce en \(.applicationName)",
        "Pon música en \(.applicationName)",
        "Reproducir canción en \(.applicationName)",
      ],
      shortTitle: "Reproducir",
      systemImageName: "music.note"
    )
    AppShortcut(
      intent: VMMusicPlaySongIntent(),
      phrases: [
        "Reproducir canción y artista en \(.applicationName)",
        "Reproducir una canción en \(.applicationName)",
      ],
      shortTitle: "Canción + Artista",
      systemImageName: "music.note.list"
    )
  }

  static var shortcutTileColor: ShortcutTileColor = .orange
}
