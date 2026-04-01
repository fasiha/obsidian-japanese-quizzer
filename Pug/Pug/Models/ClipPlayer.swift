// ClipPlayer.swift
// Singleton audio player for timed lyric clips in DocumentReaderView.
//
// A single AVAudioPlayer is kept alive so only one clip plays at a time.
// Tapping a line's play button starts the clip; tapping it again stops playback.
// A DispatchWorkItem fires after (end − start) seconds to stop automatically.

import AVFoundation
import Foundation

@Observable
@MainActor
final class ClipPlayer {
    /// The clip that is currently playing, or nil when idle. Used by the UI to toggle ▶/⏹.
    var currentClip: AudioClip? = nil

    private var player: AVAudioPlayer? = nil
    private var stopWork: DispatchWorkItem? = nil

    /// Play `clip`, resolving its audio file from Documents or the external folder bookmark.
    /// If `clip` is already playing, calling this stops it (toggle behaviour).
    /// Does nothing silently if the audio file cannot be found.
    func play(clip: AudioClip, externalFolderBookmark: Data?) {
        print("[ClipPlayer] play() called for \(clip.audioFile) (\(clip.start)–\(clip.end)s)")
        if currentClip == clip {
            print("[ClipPlayer] Clip already playing, stopping")
            stop()
            return
        }

        stop()

        guard let found = AudioFileFinder.findURL(for: clip.audioFile,
                                                  externalFolderBookmark: externalFolderBookmark)
        else {
            print("[ClipPlayer] Could not resolve audio file: \(clip.audioFile)")
            return
        }

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)

            let newPlayer = try AVAudioPlayer(contentsOf: found.fileURL)
            // Security-scoped access is only needed during file open; stop it immediately.
            found.folderURL?.stopAccessingSecurityScopedResource()

            newPlayer.currentTime = clip.start
            newPlayer.prepareToPlay()
            newPlayer.play()

            player = newPlayer
            currentClip = clip
            print("[ClipPlayer] Now playing: \(clip.audioFile) from \(clip.start)s")

            let duration = max(clip.end - clip.start, 0)
            if duration > 0 {
                print("[ClipPlayer] Will stop after \(duration)s")
                let work = DispatchWorkItem { [weak self] in
                    self?.stop()
                }
                stopWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
            }
        } catch {
            found.folderURL?.stopAccessingSecurityScopedResource()
            print("[ClipPlayer] Failed to load \(clip.audioFile): \(error)")
        }
    }

    /// Stop any in-progress playback and clear state.
    func stop() {
        stopWork?.cancel()
        stopWork = nil
        player?.stop()
        player = nil
        currentClip = nil
    }
}
