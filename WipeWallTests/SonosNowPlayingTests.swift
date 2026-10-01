import XCTest
@testable import WipeWall

private final class SpotifyCatalogTestProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.url?.host, WallConfiguration.serverURL.host)
        XCTAssertEqual(request.url?.path, "/api/device/spotify/search")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-approved-device")
        let limited = request.url?.query?.contains("rate-limited") == true
        let body = limited
            ? #"{"error":"Spotify asked Wall to wait before searching again."}"#
            : #"{"tracks":{"items":[{"id":"01xyAVYhR2QJ9YsiFnGzw7","name":"Is There Really No Happiness?","artists":[{"name":"Porter Robinson"}],"type":"track"}]}}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: limited ? 429 : 200,
                                       httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class SonosNowPlayingTests: XCTestCase {
    func testCatalogBrokerUsesDeviceTokenAndPreservesExactTrackID() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpotifyCatalogTestProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let catalog = SpotifyCatalogClient(session: session, deviceToken: { "test-approved-device" })
        let rows = try await catalog.searchTracks(query: "Porter Robinson")
        XCTAssertEqual(rows.first?.reference.id, "01xyAVYhR2QJ9YsiFnGzw7")
        XCTAssertEqual(rows.first?.artistName, "Porter Robinson")
    }

    func testCatalogBrokerReturnsServerFailureWithoutAskingForSpotifyLogin() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SpotifyCatalogTestProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let catalog = SpotifyCatalogClient(session: session, deviceToken: { "test-approved-device" })
        do {
            _ = try await catalog.searchTracks(query: "rate-limited")
            XCTFail("A failed response must not become empty search results")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Spotify asked Wall to wait before searching again.")
        }
    }

    func testCatalogBrokerRejectsMissingDeviceWithoutPersonalOAuth() async {
        let catalog = SpotifyCatalogClient(deviceToken: { nil })
        do {
            _ = try await catalog.searchTracks(query: "Porter Robinson")
            XCTFail("Missing device identity must fail closed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("device connection"))
        }
    }

    func testLiveSpotifyResolverWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["WALL_LIVE_SPOTIFY_RESOLVER"] == "1" else {
            throw XCTSkip("Set WALL_LIVE_SPOTIFY_RESOLVER=1 for the live exact-track lookup.")
        }
        let reference = try await SpotifyTrackResolver().resolve(
            query: "Play Is There Really No Happiness by Porter Robinson"
        )
        XCTAssertTrue(
            ["59BNro4EvYBdUzW8SKvvl8", "3eE6IderHf7lnqOorqiNVK"].contains(reference.id),
            "Resolver selected unexpected Spotify track \(reference.id)"
        )
    }

    func testLiveLivingRoomVolumeAndSpotifyPlaybackWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["WALL_LIVE_SONOS"] == "1" else {
            throw XCTSkip("Set WALL_LIVE_SONOS=1 for the audible home-network integration check.")
        }

        let baseURL = try XCTUnwrap(URL(string: "http://198.51.100.20:1400"))
        let volumeData = try await SonosSOAP.validatedData(
            for: SonosSOAP.volumeRequest(baseURL: baseURL),
            using: .shared
        )
        let currentVolume = try XCTUnwrap(SonosSOAP.parseVolume(from: volumeData))
        _ = try await SonosSOAP.validatedData(
            for: SonosSOAP.setVolumeRequest(baseURL: baseURL, volume: currentVolume),
            using: .shared
        )

        let result = await SonosMusicService().play(
            query: "Is There Really No Happiness by Porter Robinson"
        )
        if !result.hasPrefix("Playing ") {
            let request = SonosSOAP.makeRequest(
                baseURL: baseURL,
                path: SonosSOAP.avTransportPath,
                service: SonosSOAP.avTransportService,
                action: "GetPositionInfo",
                body: "<InstanceID>0</InstanceID>"
            )
            if let data = try? await SonosSOAP.validatedData(for: request, using: .shared) {
                let metadata = SonosSOAP.parseTrackMetadata(from: data)
                let values = SonosMusicXML.flatValues(in: data)
                print("SONOS_SAFE_NOW track=\(values["Track"] ?? "?") title=\(metadata.title) artist=\(metadata.artist)")
            }
        }
        XCTAssertTrue(result.hasPrefix("Playing "), result)
    }

    func testPositionInfoParsesEntityEscapedLivingRoomDIDLMetadata() {
        let response = #"""
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:GetPositionInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><Track>0</Track><TrackDuration>0:03:02</TrackDuration><TrackMetaData>&lt;DIDL-Lite xmlns:dc=&quot;http://purl.org/dc/elements/1.1/&quot; xmlns:upnp=&quot;urn:schemas-upnp-org:metadata-1-0/upnp/&quot; xmlns:r=&quot;urn:schemas-rinconnetworks-com:metadata-1-0/&quot; xmlns=&quot;urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/&quot;&gt;&lt;item id=&quot;-1&quot; parentID=&quot;-1&quot;&gt;&lt;res duration=&quot;0:03:02&quot;&gt;x-sonos-spotify:spotify:track:5NmBhMK9Pfu1XNAyzmxIro?sid=12&amp;amp;flags=0&amp;amp;sn=4&lt;/res&gt;&lt;upnp:albumArtURI&gt;https://i.scdn.co/image/ab67616d0000b273629b2ffb2039193f3628066b&lt;/upnp:albumArtURI&gt;&lt;upnp:class&gt;object.item.audioItem.musicTrack&lt;/upnp:class&gt;&lt;dc:title&gt;That&amp;apos;s How I Got To Memphis&lt;/dc:title&gt;&lt;dc:creator&gt;Tom T. Hall&lt;/dc:creator&gt;&lt;upnp:album&gt;Tom T. Hall - Storyteller, Poet, Philosopher&lt;/upnp:album&gt;&lt;r:streamInfo&gt;bd:16,sr:44100,c:0,l:0,d:0&lt;/r:streamInfo&gt;&lt;/item&gt;&lt;/DIDL-Lite&gt;</TrackMetaData><TrackURI>x-sonos-vli:RINCON_5CAAFD57886001400:2,spotify:a25eddfa017a62bc20e1ac4458244d96</TrackURI><RelTime>0:06:06</RelTime><AbsTime>NOT_IMPLEMENTED</AbsTime><RelCount>2147483647</RelCount><AbsCount>2147483647</AbsCount></u:GetPositionInfoResponse></s:Body></s:Envelope>
        """#

        XCTAssertEqual(
            SonosSOAP.parseTrackMetadata(from: Data(response.utf8)),
            SonosTrackMetadata(
                title: "That's How I Got To Memphis",
                artist: "Tom T. Hall",
                album: "Tom T. Hall - Storyteller, Poet, Philosopher",
                albumArtURI: "https://i.scdn.co/image/ab67616d0000b273629b2ffb2039193f3628066b"
            )
        )
    }

    func testMusicSearchRetainsSpotifyIDsAndArtworkWithoutReresolvingTitles() throws {
        let data = Data(#"""
        {"tracks":{"items":[null,{"id":"59BNro4EvYBdUzW8SKvvl8","name":"Is There Really No Happiness?","artists":[{"name":"Porter Robinson"}],"album":{"name":"SMILE! :D","images":[{"url":"https://i.scdn.co/image/cover"}]},"type":"track"},{"id":"local-file","name":"Local","artists":[]}]}}
        """#.utf8)
        let result = try XCTUnwrap(WallMusicSearchModel.results(in: data).first)
        XCTAssertEqual(result.spotifyQuery, "Is There Really No Happiness? by Porter Robinson")
        XCTAssertEqual(result.reference.canonical, "spotify:track:59BNro4EvYBdUzW8SKvvl8")
        XCTAssertEqual(result.artworkURL?.absoluteString, "https://i.scdn.co/image/cover")
        XCTAssertEqual(try WallMusicSearchModel.results(in: data).count, 1)
    }

    func testVoiceResolverUsesCatalogArtistAndDoesNotTakeWrongFirstResult() async throws {
        let wrong = WallMusicSearchResult(
            reference: try XCTUnwrap(SpotifyTrackResolver.reference(in: "spotify:track:5NmBhMK9Pfu1XNAyzmxIro")),
            trackName: "Is There Really No Happiness?", artistName: "Wrong Artist", collectionName: nil, artworkURL: nil)
        let right = WallMusicSearchResult(
            reference: try XCTUnwrap(SpotifyTrackResolver.reference(in: "spotify:track:59BNro4EvYBdUzW8SKvvl8")),
            trackName: "Is There Really No Happiness?", artistName: "Porter Robinson", collectionName: nil, artworkURL: nil)
        let resolver = SpotifyTrackResolver(search: { query in
            XCTAssertEqual(query, "Is There Really No Happiness Porter Robinson")
            return [wrong, right]
        })
        let match = try await resolver.resolve(query: "Play Is There Really No Happiness by Porter Robinson")
        XCTAssertEqual(match, right.reference)
        let withoutBy = try await resolver.resolve(query: "Is There Really No Happiness Porter Robinson")
        XCTAssertEqual(withoutBy, right.reference)
    }

    func testExplicitSpotifyLinkNeverStartsAnotherSearch() async throws {
        let resolver = SpotifyTrackResolver(search: { _ in
            XCTFail("An exact selected Spotify ID must not be searched again")
            return []
        })
        let result = try await resolver.resolve(query: "https://open.spotify.com/track/59BNro4EvYBdUzW8SKvvl8?si=abc")
        XCTAssertEqual(result.id, "59BNro4EvYBdUzW8SKvvl8")
    }

    func testSpotifySelectionsReplaceOldQueueWhileExplicitQueueRemainsAdditive() {
        XCTAssertEqual(SonosQueueContinuationPolicy.enqueueAsNext, 1)
        XCTAssertEqual(SonosQueueContinuationPolicy.appendToEnd, 0)
        XCTAssertEqual(SonosQueueContinuationPolicy.playMode, "REPEAT_ALL")
        XCTAssertEqual(SonosQueueContinuationPolicy.replacementPlayMode, "NORMAL")
    }

    func testSpotifySongRadioBuildsExactSonosContext() throws {
        let seed = try XCTUnwrap(SpotifyTrackResolver.reference(in: "spotify:track:59BNro4EvYBdUzW8SKvvl8"))
        let identity = SpotifySonosPlaybackIdentity(serviceID: 12, accountSerial: 2)
        let context = SpotifySongRadioContext.make(reference: seed, identity: identity)
        XCTAssertEqual(
            context.uri,
            "x-sonosapi-radio:spotify%3atrackRadio%3a59BNro4EvYBdUzW8SKvvl8?sid=12&flags=8300&sn=2"
        )
        XCTAssertTrue(context.metadata.contains("object.item.audioItem.audioBroadcast.#trackRadio"))
        XCTAssertTrue(context.metadata.contains("100c206cspotify%3atrackRadio%3a59BNro4EvYBdUzW8SKvvl8"))
        XCTAssertTrue(context.metadata.contains("SA_RINCON3079_X_#Svc3079-0-Token"))
    }

    func testSpotifySonosIdentityParsesCurrentTrackURI() {
        let value = "x-sonos-spotify:spotify%3atrack%3aabc?sid=12&amp;flags=8232&amp;sn=2"
        XCTAssertEqual(
            SpotifySonosPlaybackIdentity.parse([value]),
            SpotifySonosPlaybackIdentity(serviceID: 12, accountSerial: 2)
        )
    }

    func testSOAPRequestsUsePort1400BaseURLAndExpectedAction() throws {
        let baseURL = try XCTUnwrap(URL(string: "http://198.51.100.20:1400"))
        let request = SonosSOAP.transportInfoRequest(baseURL: baseURL)

        XCTAssertEqual(request.url?.absoluteString, "http://198.51.100.20:1400/MediaRenderer/AVTransport/Control")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "SOAPACTION"),
            "\"urn:schemas-upnp-org:service:AVTransport:1#GetTransportInfo\""
        )
        XCTAssertTrue(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8)?.contains("<InstanceID>0</InstanceID>") == true)
    }

    func testTransportAndVolumeSOAPValuesParse() {
        let transport = Data("<Envelope><CurrentTransportState>PLAYING</CurrentTransportState></Envelope>".utf8)
        let volume = Data("<Envelope><CurrentVolume>41</CurrentVolume></Envelope>".utf8)
        XCTAssertEqual(SonosSOAP.parseTransportState(from: transport), .playing)
        XCTAssertEqual(SonosSOAP.parseVolume(from: volume), 41)
    }

    func testPartialSkipRefreshPreservesLastConfirmedVolume() {
        XCTAssertEqual(SonosVolumeReconciliation.value(polled: nil, previous: 41), 41)
        XCTAssertEqual(SonosVolumeReconciliation.value(polled: 0, previous: 41), 0)
        XCTAssertEqual(SonosVolumeReconciliation.value(polled: 74, previous: 41), 74)
    }

    func testSpotifyResolverAcceptsOnlyCanonicalTwentyTwoCharacterTrackURI() throws {
        let expected = "spotify:track:59BNro4EvYBdUzW8SKvvl8"
        let reference = try XCTUnwrap(SpotifyTrackResolver.reference(in: "Result: \(expected)"))
        XCTAssertEqual(reference.canonical, expected)
        XCTAssertEqual(reference.encoded, "spotify%3atrack%3a59BNro4EvYBdUzW8SKvvl8")
        XCTAssertNil(SpotifyTrackResolver.reference(in: "spotify:album:59BNro4EvYBdUzW8SKvvl8"))
        XCTAssertNil(SpotifyTrackResolver.reference(in: "spotify:track:59BNro4EvYBdUzW8SKvvl8X"))
    }

    func testSpotifyResolverParsesResponsesOutputText() throws {
        let response: [String: Any] = [
            "status": "completed",
            "output": [[
                "type": "message",
                "content": [[
                    "type": "output_text",
                    "text": "spotify:track:59BNro4EvYBdUzW8SKvvl8"
                ]]
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: response)
        XCTAssertEqual(
            SpotifyTrackResolver.reference(inResponseData: data)?.canonical,
            "spotify:track:59BNro4EvYBdUzW8SKvvl8"
        )
    }

    func testSpotifyResolverCollectsAndDeduplicatesMultipleCandidates() throws {
        let first = "spotify:track:59BNro4EvYBdUzW8SKvvl8"
        let second = "spotify:track:5NmBhMK9Pfu1XNAyzmxIro"
        let response: [String: Any] = [
            "output": [["content": [["text": "\(first)\n\(second)\n\(first)"]]]]
        ]
        let data = try JSONSerialization.data(withJSONObject: response)
        XCTAssertEqual(
            SpotifyTrackResolver.references(inResponseData: data).map(\.canonical),
            [first, second]
        )
    }

    func testSpotifyOEmbedVerifiesTheResolvedLinkInsteadOfReSearchingTheTypedPhrase() throws {
        let reference = try XCTUnwrap(
            SpotifyTrackResolver.reference(in: "https://open.spotify.com/track/59BNro4EvYBdUzW8SKvvl8")
        )
        let data = Data(#"""
        {
          "provider_name":"Spotify",
          "title":"Is There Really No Happiness?",
          "html":"<iframe src=\"https://open.spotify.com/embed/track/59BNro4EvYBdUzW8SKvvl8?utm_source=oembed\"></iframe>"
        }
        """#.utf8)
        let metadata = try JSONDecoder().decode(SpotifyOEmbedMetadata.self, from: data)

        XCTAssertTrue(metadata.matches(
            reference: reference,
            query: "Is There Really No Happiness? by Porter Robinson"
        ))
        XCTAssertFalse(metadata.matches(reference: reference, query: "Happiness by The 1975"))
    }

    func testSpotifyOfficialMetadataRequiresExactRequestedTitleAndArtist() throws {
        let html = #"""
        <html><head>
        <meta property="og:title" content="Is There Really No Happiness?">
        <meta property="og:description" content="Porter Robinson · SMILE! :D · Song · 2024">
        </head></html>
        """#
        let metadata = try XCTUnwrap(SpotifyTrackPageMetadata(data: Data(html.utf8)))

        XCTAssertTrue(metadata.matches(query: "Play Is There Really No Happiness by Porter Robinson"))
        XCTAssertFalse(metadata.matches(query: "Play Happiness by The 1975"))
        XCTAssertFalse(metadata.matches(query: "Play Is There Really No Happiness by Taylor Swift"))
    }

    func testSonosMetadataCannotVerifyAWeakOrDifferentSong() {
        let expected = "Play Is There Really No Happiness by Porter Robinson"
        XCTAssertTrue(
            SpotifyTrackPageMetadata(
                title: "Is There Really No Happiness?",
                artist: "Porter Robinson"
            ).matches(query: expected)
        )
        XCTAssertFalse(
            SpotifyTrackPageMetadata(
                title: "Everything To Me",
                artist: "Porter Robinson"
            ).matches(query: expected)
        )
    }

    func testLivingRoomTopologyResolvesItsGroupCoordinator() throws {
        let topology = #"""
        <ZoneGroups><ZoneGroup Coordinator="RINCON_COORDINATOR"><ZoneGroupMember UUID="RINCON_COORDINATOR" ZoneName="Kitchen" Location="http://198.51.100.21:1400/xml/device_description.xml"/><ZoneGroupMember UUID="RINCON_LIVING" ZoneName="Living Room" Location="http://198.51.100.20:1400/xml/device_description.xml"/></ZoneGroup></ZoneGroups>
        """#
        XCTAssertEqual(
            SonosMusicXML.coordinator(in: topology, roomName: "Living Room"),
            SonosCoordinator(host: "198.51.100.21", port: 1400, uuid: "RINCON_COORDINATOR")
        )
    }

    func testSpotifyDIDLEscapesExactlyOnceAtSOAPBoundary() throws {
        let reference = try XCTUnwrap(SpotifyTrackResolver.reference(in: "spotify:track:59BNro4EvYBdUzW8SKvvl8"))
        let didl = SonosMusicXML.spotifyDIDL(reference: reference, serviceNumber: 2311)
        XCTAssertTrue(didl.contains("00032020spotify%3atrack%3a59BNro4EvYBdUzW8SKvvl8"))
        XCTAssertTrue(didl.contains("SA_RINCON2311_X_#Svc2311-0-Token"))
        let outer = SonosMusicXML.escape(didl)
        XCTAssertTrue(outer.hasPrefix("&lt;DIDL-Lite"))
        XCTAssertFalse(outer.contains("&amp;lt;DIDL-Lite"))
    }

    func testSiftStreamDIDLIncludesVisibleTrackMetadata() {
        let didl = SonosMusicXML.streamDIDL(
            title: "Terra & Incognita",
            artist: "Wata Igarashi",
            album: "My Supernova"
        )
        XCTAssertTrue(didl.contains("<dc:title>Terra &amp; Incognita</dc:title>"))
        XCTAssertTrue(didl.contains("<dc:creator>Wata Igarashi</dc:creator>"))
        XCTAssertTrue(didl.contains("<upnp:album>My Supernova</upnp:album>"))
        XCTAssertTrue(SonosMusicXML.escape(didl).contains("&lt;DIDL-Lite"))
    }

    func testShuffleSOAPUsesSetPlayMode() throws {
        let request = SonosSOAP.playModeRequest(
            baseURL: try XCTUnwrap(URL(string: "http://198.51.100.20:1400")),
            mode: "SHUFFLE"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "SOAPACTION"),
            "\"urn:schemas-upnp-org:service:AVTransport:1#SetPlayMode\""
        )
        XCTAssertTrue(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8)?.contains(
            "<NewPlayMode>SHUFFLE</NewPlayMode>"
        ) == true)
    }
}
