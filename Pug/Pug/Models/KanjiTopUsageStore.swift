// KanjiTopUsageStore.swift
// Observable wrapper around the optional KanjiTopUsageManifest, injected via SwiftUI environment.
// Avoids threading the manifest as an explicit prop through every intermediate view.

import Foundation

@Observable final class KanjiTopUsageStore {
    var manifest: KanjiTopUsageManifest? = nil

    /// Returns the top-usage entry for the given kanji character, or nil if unavailable.
    func entry(for kanji: String) -> KanjiTopUsageEntry? {
        manifest?.kanji[kanji]
    }

    /// Load from cache; download only when cache is absent.
    func load() async {
        if let cached = KanjiTopUsageSync.cached() {
            manifest = cached
            return
        }
        do {
            manifest = try await KanjiTopUsageSync.sync()
        } catch {
            print("[KanjiTopUsageStore] load failed: \(error.localizedDescription)")
        }
    }

    /// Force-download and replace the current manifest.
    func reload() async {
        do {
            manifest = try await KanjiTopUsageSync.sync()
        } catch {
            print("[KanjiTopUsageStore] reload failed: \(error.localizedDescription)")
        }
    }
}
