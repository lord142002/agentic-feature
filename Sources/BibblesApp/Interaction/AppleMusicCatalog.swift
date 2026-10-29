import MusicKit

/// Catalog playback uses MusicKit's own player on macOS. The system Music
/// player is unavailable on macOS, so the audio belongs to Bibbles.
@available(macOS 14.0, *)
enum AppleMusicCatalog {
    enum Kind { case song, genre }

    @MainActor
    static func play(query: String, kind: Kind) async throws -> MacActionResult {
        let status = await MusicAuthorization.request()
        guard status == .authorized else {
            throw MacActionError.failed("Allow Bibbles access to Media & Apple Music in System Settings → Privacy & Security, then try again.")
        }
        let subscription: MusicSubscription
        do { subscription = try await MusicSubscription.current }
        catch {
            throw MacActionError.failed("Apple Music access isn't ready. Check Bibbles' MusicKit app service and your Apple Music sign-in.")
        }
        guard subscription.canPlayCatalogContent else {
            throw MacActionError.failed("This Mac cannot play Apple Music catalog tracks with its current account. Sign in to an active Apple Music subscription, or ask for a song already in your Music library.")
        }
        try Task.checkCancellation()
        let player = ApplicationMusicPlayer.shared
        do {
            if kind == .genre {
                var request = MusicCatalogSearchRequest(term: query, types: [Playlist.self])
                request.limit = 10
                guard let playlist = try await request.response().playlists.first else {
                    throw MacActionError.failed("No Apple Music playlist matched “\(query)”. Try a more specific style.")
                }
                try Task.checkCancellation()
                player.queue = .init(for: [playlist])
                try await player.play()
                return MacActionResult(message: "Playing “\(playlist.name)” in Bibbles via Apple Music.")
            }
            var request = MusicCatalogSearchRequest(term: query, types: [Song.self])
            request.limit = 10
            let songs = Array(try await request.response().songs)
            guard let song = bestSong(for: query, from: songs) else {
                throw MacActionError.failed("No Apple Music song matched “\(query)”. Try adding the artist.")
            }
            try Task.checkCancellation()
            player.queue = .init(for: [song])
            try await player.play()
            return MacActionResult(message: "Playing “\(song.title)” by \(song.artistName) in Bibbles via Apple Music.")
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MacActionError {
            throw error
        } catch {
            throw MacActionError.failed("Apple Music couldn't start playback: \(error.localizedDescription). Check your subscription and Bibbles' MusicKit app service.")
        }
    }

    static func bestSong(for query: String, from songs: [Song]) -> Song? {
        guard let index = bestIndex(for: query, in: songs.map { ($0.title, $0.artistName) }) else { return nil }
        return songs[index]
    }

    static func bestIndex(for query: String, in candidates: [(title: String, artist: String)]) -> Int? {
        guard !candidates.isEmpty else { return nil }
        let parts = query.range(of: " by ", options: .caseInsensitive)
        let title = parts.map { String(query[..<$0.lowerBound]) } ?? query
        let artist = parts.map { String(query[$0.upperBound...]) }
        func normalized(_ value: String) -> String {
            value.lowercased().folding(options: [.diacriticInsensitive], locale: .current)
                .filter { $0.isLetter || $0.isNumber }
        }
        let wantedTitle = normalized(title)
        let wantedArtist = artist.map(normalized)
        // Search ranking breaks ties; exact title and named artist take priority.
        let ranked = candidates.enumerated().map { index, candidate in
            let foundTitle = normalized(candidate.title)
            let foundArtist = normalized(candidate.artist)
            let titleScore = foundTitle == wantedTitle ? 4 : (foundTitle.contains(wantedTitle) ? 2 : 0)
            let artistScore = wantedArtist.map { foundArtist.contains($0) ? 5 : -5 } ?? 0
            return (index, titleScore + artistScore)
        }
        let best = ranked.max { a, b in a.1 == b.1 ? a.0 > b.0 : a.1 < b.1 }
        guard let best, best.1 >= 2 else { return nil }
        return best.0
    }
}
