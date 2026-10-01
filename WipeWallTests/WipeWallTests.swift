import XCTest
@testable import WipeWall

final class WipeWallTests: XCTestCase {
    func testPhotoEditStorageUsesStableSafePerPhotoDirectories() {
        let first = WallPhotoEditStorage.identifier(for: "fit-20260910T120000Z-one.jpg")
        let repeated = WallPhotoEditStorage.identifier(for: "fit-20260910T120000Z-one.jpg")
        let second = WallPhotoEditStorage.identifier(for: "fit-20260910T120001Z-two.jpg")

        XCTAssertEqual(first, repeated)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.count, 64)
        XCTAssertNotNil(first.range(of: "^[a-f0-9]{64}$", options: .regularExpression))
    }

    func testWeatherSnapshotIncludesCurrentConditionsAndTwoHourPeriods() throws {
        let json = #"{"current":{"time":"2026-09-03T14:00","temperature_2m":79.4,"weather_code":2},"hourly":{"time":["2026-09-03T13:00","2026-09-03T14:00","2026-09-03T15:00","2026-09-03T16:00","2026-09-03T18:00","2026-09-03T20:00","2026-09-03T22:00","2026-09-04T00:00"],"temperature_2m":[78,79.4,80,81.2,77,73,70,68],"precipitation_probability":[10,20,25,40,60,45,20,10],"weather_code":[1,2,2,61,61,3,2,0]},"daily":{"temperature_2m_max":[81.2],"temperature_2m_min":[63.4],"precipitation_probability_max":[60],"rain_sum":[0.02]}}"#
        let snapshot = try WeatherService.snapshot(from: Data(json.utf8))

        XCTAssertEqual(snapshot.currentTemperature, 79.4)
        XCTAssertEqual(snapshot.currentCode, 2)
        XCTAssertEqual(snapshot.periods.count, 6)
        XCTAssertEqual(snapshot.periods.map(\.rainChance), [20, 40, 60, 45, 20, 10])
        XCTAssertEqual(snapshot.periods.map(\.weatherCode), [2, 61, 61, 3, 2, 0])
        XCTAssertEqual(WeatherCodePresentation.label(for: snapshot.currentCode), "partly cloudy")
    }

    func testHoroscopeDayUsesNewYorkInsteadOfDeviceTimeZone() {
        let date = Date(timeIntervalSince1970: 1_788_494_400) // 2026-09-04 02:00 UTC, still Sep 3 in New York
        XCTAssertEqual(WallHoroscopeAPI.dayKey(for: date), "2026-09-03")
    }

    func testHoroscopeAcceptsOnlyLocalDayOrProviderUTCRollover() {
        XCTAssertTrue(WallHoroscopeAPI.isCurrentProviderDate("2026-09-03", localDay: "2026-09-03"))
        XCTAssertTrue(WallHoroscopeAPI.isCurrentProviderDate("2026-09-04", localDay: "2026-09-03"))
        XCTAssertFalse(WallHoroscopeAPI.isCurrentProviderDate("2026-09-02", localDay: "2026-09-03"))
        XCTAssertFalse(WallHoroscopeAPI.isCurrentProviderDate("2030-01-01", localDay: "2026-09-03"))
    }

    func testVoiceMusicSourceDefaultsToSpotifyAndRequiresExplicitSoundCloud() {
        XCTAssertEqual(WallMusicSource.toolSelection(nil), .spotify)
        XCTAssertEqual(WallMusicSource.toolSelection("spotify"), .spotify)
        XCTAssertEqual(WallMusicSource.toolSelection("soundcloud"), .soundcloud)
        XCTAssertEqual(WallMusicSource.toolSelection("unknown"), .spotify)
    }

    func testPhotoBoothEmailPolicyRejectsIncompleteAddresses() {
        XCTAssertTrue(PhotoBoothEmailPolicy.isPlausible("guest@example.com"))
        XCTAssertTrue(PhotoBoothEmailPolicy.isPlausible(" Guest+party@Example.co.uk "))
        XCTAssertFalse(PhotoBoothEmailPolicy.isPlausible("guest"))
        XCTAssertFalse(PhotoBoothEmailPolicy.isPlausible("guest@example"))
    }

    func testSpotifyResolverAcceptsOfficialURLAndCanonicalURIForms() {
        let id = "0123456789ABCDEFGHIJKL"
        let references = SpotifyTrackResolver.references(in: """
        https://open.spotify.com/track/\(id)?si=abc
        https://open.spotify.com/intl-us/track/\(id)
        spotify:track:\(id)
        """)
        XCTAssertEqual(references.map(\.canonical), ["spotify:track:\(id)"])
    }

    func testPhotoBoothNightUsesNewYorkCalendarDay() {
        let date = Date(timeIntervalSince1970: 1_787_970_900) // 2026-08-29 02:35 UTC
        XCTAssertEqual(
            PhotoBoothNight.identifier(for: date, timeZone: TimeZone(identifier: "America/New_York")!),
            "2026-08-28"
        )
    }

    func testGlobalWallLayerControlsMoveToAbsoluteBoundariesAndPersist() throws {
        let suiteName = "wall-layer-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let gifID = UUID()
        let widgetID = UUID()
        let gif = WallLayerID.gif(gifID)
        let widget = WallLayerID.widget(widgetID)
        let clock = WallLayerID.element(.clock)
        let key = "test.global-layers"
        let store = WallLayerStore(defaults: defaults, persistenceKey: key)

        store.synchronize(with: [gif, widget, clock])
        XCTAssertEqual(store.order, [gif, widget, clock])

        store.bringToFront(gif)
        XCTAssertEqual(store.order, [widget, clock, gif])
        store.sendToBack(gif)
        XCTAssertEqual(store.order, [gif, widget, clock])

        let restored = WallLayerStore(defaults: defaults, persistenceKey: key)
        XCTAssertEqual(restored.order, [gif, widget, clock])
        XCTAssertLessThan(restored.zIndex(for: gif), restored.zIndex(for: widget))
        XCTAssertLessThan(restored.zIndex(for: widget), restored.zIndex(for: clock))
    }

    func testHelveticaClockUsesTwelveHourTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: 2026, month: 8, day: 23)
        XCTAssertEqual(WallClockText.time(for: components.date!, calendar: calendar), "12:00")
    }

    func testCommandIsRemovedFromWakePhrase() {
        XCTAssertEqual(
            DonVoiceController.commandAfterWakeWord(in: "Hi Wall, turn off the kitchen lights"),
            "turn off the kitchen lights"
        )
        XCTAssertEqual(
            DonVoiceController.commandAfterWakeWord(in: "Hi Wall, open Megalopolis"),
            "open Megalopolis"
        )
        XCTAssertEqual(
            DonVoiceController.commandAfterWakeWord(in: "Hi, Wall — play music"),
            "play music"
        )
        XCTAssertEqual(
            DonVoiceController.commandAfterWakeWord(in: "High wall, pause Sonos"),
            "pause Sonos"
        )
        XCTAssertEqual(
            DonVoiceController.commandAfterWakeWord(in: "Hey Wall! what's the weather"),
            "what's the weather"
        )
        XCTAssertEqual(
            DonVoiceController.commandAfterWakeWord(in: "Hi well play the radio"),
            "play the radio"
        )
        XCTAssertEqual(
            DonVoiceController.commandAfterWakeWord(in: "Hi all, show the weather"),
            "show the weather"
        )
        XCTAssertEqual(
            DonVoiceController.commandAfterWakeWord(in: "HiWall play the radio"),
            "play the radio"
        )
        XCTAssertEqual(
            DonVoiceController.commandAfterWakeWord(in: "Hi world, show me the photos"),
            "show me the photos"
        )
        XCTAssertEqual(
            DonVoiceController.commandAfterWakeWord(in: "Hi y'all turn the TV on"),
            "turn the TV on"
        )
    }

    func testWakeActivationToneIsAPlayablePCMWave() {
        let data = WakeActivationTone.wavData
        XCTAssertGreaterThan(data.count, 3_000)
        XCTAssertEqual(String(data: Data(data.prefix(4)), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: Data(data.dropFirst(8).prefix(4)), encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: Data(data.dropFirst(36).prefix(4)), encoding: .ascii), "data")
    }

    func testGoonMoanUsesTheBundledMP3() throws {
        let appBundle = Bundle(for: FitPicController.self)
        let url = try XCTUnwrap(GoonMoanSound.resourceURL(in: appBundle))
        XCTAssertEqual(url.lastPathComponent, "579256__bluedeer__animemoan.mp3")
        XCTAssertGreaterThan(try Data(contentsOf: url).count, 60_000)
        XCTAssertEqual(GoonMoanSound.captureDelay, 1)
    }

    func testTransitParserKeepsEveryCurrentRouteAlert() throws {
        let json = #"{"entity":[{"id":"1","alert":{"active_period":[{"start":100,"end":300}],"informed_entity":[{"route_id":"L"}],"header_text":{"translation":[{"text":"[L] trains are suspended","language":"en"}]},"transit_realtime.mercury_alert":{"alert_type":"Suspended"}}},{"id":"2","alert":{"active_period":[{"start":100,"end":300}],"informed_entity":[{"route_id":"G"}],"header_text":{"translation":[{"text":"Boarding change","language":"en"}]},"transit_realtime.mercury_alert":{"alert_type":"Boarding Change"}}}]}"#
        let alerts = try TransitService.parse(data: Data(json.utf8), now: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(alerts, [
            TransitAlert(id: "1", routes: ["L"], headline: "L trains are suspended", kind: "Suspended"),
            TransitAlert(id: "2", routes: ["G"], headline: "Boarding change", kind: "Boarding Change")
        ])
    }

    func testMTARouteAppearancesMatchOfficialLineFamilies() {
        XCTAssertEqual(MTARouteAppearance.forRoute("A").backgroundHex, 0x0062CF)
        XCTAssertEqual(MTARouteAppearance.forRoute("F").backgroundHex, 0xEB6800)
        XCTAssertEqual(MTARouteAppearance.forRoute("G").backgroundHex, 0x799534)
        XCTAssertEqual(MTARouteAppearance.forRoute("J").backgroundHex, 0x8E5C33)
        XCTAssertEqual(MTARouteAppearance.forRoute("L").backgroundHex, 0x7C858C)
        XCTAssertEqual(MTARouteAppearance.forRoute("N").backgroundHex, 0xF6BC26)
        XCTAssertTrue(MTARouteAppearance.forRoute("N").usesDarkLettering)
        XCTAssertEqual(MTARouteAppearance.forRoute("2").backgroundHex, 0xD82233)
        XCTAssertEqual(MTARouteAppearance.forRoute("5").backgroundHex, 0x009952)
        XCTAssertEqual(MTARouteAppearance.forRoute("7").backgroundHex, 0x9A38A1)
        XCTAssertEqual(MTARouteAppearance.forRoute("SI").label, "SIR")
    }

    func testWallTransitScopeKeepsOnlyLAndMAlertsAndBullets() {
        let alerts = [
            TransitAlert(id: "l", routes: ["L"], headline: "L change", kind: "Service Change"),
            TransitAlert(id: "shared", routes: ["F", "M"], headline: "F and M change", kind: "Delays"),
            TransitAlert(id: "a", routes: ["A"], headline: "A change", kind: "Delays")
        ]

        XCTAssertEqual(WallTransitScope.alerts(from: alerts), [
            TransitAlert(id: "l", routes: ["L"], headline: "L change", kind: "Service Change"),
            TransitAlert(id: "shared", routes: ["M"], headline: "F and M change", kind: "Delays")
        ])
    }

    func testDrawingUndoAndEraserHistory() {
        let ink = InkCanvasModel(persistenceURL: nil)
        let point = CGPoint(x: 40, y: 40)

        ink.toggleDrawingMode()
        ink.appendPoint(point)
        ink.endGesture()
        XCTAssertEqual(ink.visibleStrokeCount, 1)

        ink.toggleEraser()
        ink.appendPoint(point)
        ink.endGesture()
        XCTAssertEqual(ink.visibleStrokeCount, 0)

        ink.undo()
        XCTAssertEqual(ink.visibleStrokeCount, 1)
        ink.undo()
        XCTAssertEqual(ink.visibleStrokeCount, 0)
    }

    func testCancelledDrawingGestureLeavesNoMark() {
        let ink = InkCanvasModel(persistenceURL: nil)
        ink.toggleDrawingMode()
        ink.appendPoint(CGPoint(x: 30, y: 40))
        ink.appendPoint(CGPoint(x: 35, y: 45))
        ink.cancelActiveGesture()
        XCTAssertEqual(ink.visibleStrokeCount, 0)
    }

    func testClearingDrawingCanBeUndone() {
        let ink = InkCanvasModel(persistenceURL: nil)
        ink.toggleDrawingMode()
        ink.appendPoint(CGPoint(x: 10, y: 10))
        ink.endGesture()
        ink.clear()
        XCTAssertEqual(ink.visibleStrokeCount, 0)
        ink.undo()
        XCTAssertEqual(ink.visibleStrokeCount, 1)
    }

    func testDrawingPersistsUntilExplicitlyCleared() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("wall-ink-\(UUID().uuidString).json")
        let first = InkCanvasModel(persistenceURL: file)
        first.toggleDrawingMode()
        first.appendPoint(CGPoint(x: 22, y: 33))
        first.endGesture()
        XCTAssertEqual(InkCanvasModel(persistenceURL: file).visibleStrokeCount, 1)

        let restored = InkCanvasModel(persistenceURL: file)
        restored.clear()
        XCTAssertEqual(InkCanvasModel(persistenceURL: file).visibleStrokeCount, 0)
    }

    func testDrawingStartsDisabledUntilPencilIsTapped() {
        let ink = InkCanvasModel(persistenceURL: nil)
        ink.appendPoint(CGPoint(x: 12, y: 18))
        ink.endGesture()
        XCTAssertEqual(ink.visibleStrokeCount, 0)

        ink.toggleDrawingMode()
        ink.appendPoint(CGPoint(x: 12, y: 18))
        ink.endGesture()
        XCTAssertEqual(ink.visibleStrokeCount, 1)

        ink.toggleDrawingMode()
        ink.appendPoint(CGPoint(x: 30, y: 30))
        ink.endGesture()
        XCTAssertEqual(ink.visibleStrokeCount, 1)
    }

    func testWallInputPolicyLeavesControlsLiveUntilPencilIsEnabled() {
        XCTAssertFalse(
            WallInputPolicy.routesDrawingGesture(
                isEditing: false,
                isDrawingEnabled: false,
                allowsDrawingThrough: true
            )
        )
        XCTAssertFalse(
            WallInputPolicy.routesDrawingGesture(
                isEditing: false,
                isDrawingEnabled: true,
                allowsDrawingThrough: false
            )
        )
        XCTAssertTrue(
            WallInputPolicy.routesDrawingGesture(
                isEditing: false,
                isDrawingEnabled: true,
                allowsDrawingThrough: true
            )
        )
        XCTAssertFalse(
            WallInputPolicy.routesDrawingGesture(
                isEditing: true,
                isDrawingEnabled: true,
                allowsDrawingThrough: true
            )
        )
    }

    func testPencilColorSelectionUpdatesImmediately() {
        let ink = InkCanvasModel(persistenceURL: nil)
        ink.toggleDrawingMode()
        ink.selectColor(.blue)
        XCTAssertEqual(ink.selectedColor, .blue)
        XCTAssertFalse(ink.isErasing)
    }

    func testGIFSelectionHitTestingIncludesImageAndDeleteControl() {
        let item = WallGIFItem(
            id: UUID(),
            source: .bundled("test"),
            naturalWidth: 100,
            naturalHeight: 50,
            normalizedX: 0.5,
            normalizedY: 0.5,
            scale: 1,
            rotationDegrees: 25
        )
        let container = CGSize(width: 500, height: 400)
        XCTAssertTrue(item.containsSelectionTap(item.displayedCenter(in: container), in: container))
        XCTAssertTrue(item.containsSelectionTap(item.deleteControlPosition(in: container), in: container))
        XCTAssertTrue(item.containsSelectionTap(item.snapControlPosition(in: container), in: container))
        XCTAssertFalse(item.containsSelectionTap(CGPoint(x: 20, y: 20), in: container))
    }

    func testFitPicCooldownLastsTenMinutesAndSurvivesRelaunchMath() {
        let triggered = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(FitPicController.triggerCooldown, 10 * 60)
        XCTAssertEqual(
            FitPicController.cooldownRemaining(
                now: triggered.addingTimeInterval(5 * 60),
                lastTrigger: triggered
            ),
            5 * 60,
            accuracy: 0.01
        )
        XCTAssertEqual(
            FitPicController.cooldownRemaining(
                now: triggered.addingTimeInterval(11 * 60),
                lastTrigger: triggered
            ),
            0,
            accuracy: 0.01
        )
    }

    func testPhotoBoothIncludesAllFourBundledGIFs() {
        XCTAssertEqual(PhotoBoothGIFAssets.names.count, 4)
        for index in 1...4 {
            XCTAssertNotNil(PhotoBoothGIFAssets.data(for: index))
        }
    }

    func testAutomaticFitPicRequiresSustainedOnDevicePersonPresence() {
        XCTAssertEqual(FitPicPresenceGate.requiredDwell, 3)
        var gate = FitPicPresenceGate()
        let start = Date(timeIntervalSince1970: 20_000)

        XCTAssertFalse(gate.observe(personPresent: true, at: start))
        XCTAssertFalse(gate.observe(personPresent: true, at: start.addingTimeInterval(1.4)))
        XCTAssertFalse(gate.observe(personPresent: false, at: start.addingTimeInterval(2.3)))
        XCTAssertFalse(gate.hasSeenPerson, "A passerby must reset after leaving the frame")

        let stayed = start.addingTimeInterval(4)
        XCTAssertFalse(gate.observe(personPresent: true, at: stayed))
        XCTAssertFalse(gate.observe(personPresent: true, at: stayed.addingTimeInterval(0.7)))
        XCTAssertFalse(gate.observe(personPresent: true, at: stayed.addingTimeInterval(1.4)))
        XCTAssertFalse(gate.observe(personPresent: true, at: stayed.addingTimeInterval(2.1)))
        XCTAssertFalse(gate.observe(personPresent: true, at: stayed.addingTimeInterval(2.8)))
        XCTAssertTrue(gate.observe(personPresent: true, at: stayed.addingTimeInterval(3.05)))
    }

    func testFitPicCameraFollowsEveryInterfaceOrientation() {
        XCTAssertEqual(FitPicController.videoOrientation(for: .portrait), .portrait)
        XCTAssertEqual(FitPicController.videoOrientation(for: .portraitUpsideDown), .portraitUpsideDown)
        XCTAssertEqual(FitPicController.videoOrientation(for: .landscapeLeft), .landscapeLeft)
        XCTAssertEqual(FitPicController.videoOrientation(for: .landscapeRight), .landscapeRight)
        XCTAssertEqual(FitPicController.visionOrientation(for: .portrait), .leftMirrored)
        XCTAssertEqual(FitPicController.visionOrientation(for: .portraitUpsideDown), .rightMirrored)
        XCTAssertEqual(FitPicController.visionOrientation(for: .landscapeLeft), .downMirrored)
        XCTAssertEqual(FitPicController.visionOrientation(for: .landscapeRight), .upMirrored)
    }

    func testFitPicRejectsPureBlackFramesButKeepsDarkFramesWithDetail() {
        XCTAssertFalse(FitPicLumaQuality.isUsable(samples: [UInt8](repeating: 0, count: 192)))
        var detailed = [UInt8](repeating: 7, count: 192)
        detailed[24] = 80
        detailed[96] = 160
        XCTAssertTrue(FitPicLumaQuality.isUsable(samples: detailed))
    }

    func testGoonCounterPersistsEachPersonSeparately() {
        let suite = "wall-goon-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = GoonCounterModel(defaults: defaults, persistenceKey: "counts")
        first.increment(.alex)
        let firstCelebration = first.celebration
        first.increment(.alex)
        let secondCelebration = first.celebration
        first.increment(.ellis)
        let restored = GoonCounterModel(defaults: defaults, persistenceKey: "counts")
        XCTAssertEqual(restored.counts[.alex], 2)
        XCTAssertEqual(restored.counts[.ellis], 1)
        XCTAssertEqual(restored.counts[.blake], 0)
        XCTAssertEqual(firstCelebration?.person, .alex)
        XCTAssertEqual(secondCelebration?.person, .alex)
        XCTAssertNotEqual(firstCelebration?.id, secondCelebration?.id)
        let latestCelebration = first.celebration
        XCTAssertEqual(latestCelebration?.person, .ellis)
        first.decrement(.alex)
        XCTAssertEqual(first.counts[.alex], 1)
        XCTAssertEqual(first.celebration, latestCelebration)
        first.decrement(.blake)
        XCTAssertEqual(first.counts[.blake], 0)
        first.finishCelebration(UUID())
        XCTAssertEqual(first.celebration, latestCelebration)
        if let latestCelebration {
        first.finishCelebration(latestCelebration.id)
        }
        XCTAssertNil(first.celebration)
    }

    func testGoonCounterRanksLeaderFirstAndKeepsStableTieOrder() {
        let suite = "wall-goon-ranking-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = GoonCounterModel(defaults: defaults, persistenceKey: "counts")

        model.increment(.ellis)
        model.increment(.ellis)
        model.increment(.blake)
        model.increment(.casey)

        XCTAssertEqual(model.rankedPeople, [.ellis, .blake, .casey, .alex, .drew])
    }

    func testThreeRapidGoonAddsTriggerExactEggplantPeachCombo() {
        let suite = "wall-goon-combo-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let start = Date(timeIntervalSince1970: 1_000)
        var current = start
        let model = GoonCounterModel(
            defaults: defaults,
            persistenceKey: "counts",
            now: { current }
        )

        model.increment(.alex)
        XCTAssertEqual(model.celebration?.style, .splash)
        current = start.addingTimeInterval(0.7)
        model.increment(.blake)
        XCTAssertEqual(model.celebration?.style, .splash)
        current = start.addingTimeInterval(1.4)
        model.increment(.ellis)
        XCTAssertEqual(model.celebration?.style, .rapidTriple)
        let comboID = model.celebration?.id
        current = start.addingTimeInterval(1.5)
        model.increment(.alex)
        XCTAssertEqual(model.celebration?.id, comboID, "A fourth tap must not interrupt the five-second combo")
        current = start.addingTimeInterval(1.6)
        model.increment(.alex)
        current = start.addingTimeInterval(1.7)
        model.increment(.alex)
        XCTAssertEqual(model.celebration?.id, comboID, "A second triple must not restart an active combo")
        model.finishCelebration(UUID())
        XCTAssertEqual(model.celebration?.id, comboID, "A stale splash completion must not dismiss the combo")
        if let comboID { model.finishCelebration(comboID) }

        current = start.addingTimeInterval(10)
        model.increment(.casey)
        current = start.addingTimeInterval(11.1)
        model.increment(.drew)
        current = start.addingTimeInterval(16.2)
        model.increment(.alex)
        XCTAssertEqual(model.celebration?.style, .splash, "Adds outside the five-second window must not combo")

        XCTAssertEqual(GoonRapidTripleAnimationPolicy.phaseCount, 10)
        XCTAssertEqual(GoonRapidTripleAnimationPolicy.phaseDuration, 0.5)
        XCTAssertEqual(
            (0..<GoonRapidTripleAnimationPolicy.phaseCount).map(GoonRapidTripleAnimationPolicy.emoji(for:)),
            ["🍆", "🍑", "🍆", "🍑", "🍆", "🍑", "🍆", "🍑", "🍆", "🍑"]
        )
    }

    func testGoonCounterRecordsAddsAndCorrections() throws {
        let suite = "wall-goon-events-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = GoonEventRecorderSpy()
        let model = GoonCounterModel(
            defaults: defaults,
            persistenceKey: "counts",
            eventRecorder: recorder
        )

        model.increment(.drew)
        model.decrement(.drew)
        model.decrement(.blake)

        XCTAssertEqual(recorder.events.map(\.person), [.drew, .drew])
        XCTAssertEqual(recorder.events.map(\.action), [.add, .remove])
        XCTAssertEqual(Set(recorder.events.map(\.id)).count, 2)
    }

    func testRotationSnapUsesRequestedAngles() {
        XCTAssertEqual(WallRotationSnap.closest(to: 17), 0)
        XCTAssertEqual(WallRotationSnap.closest(to: 44), 45)
        XCTAssertEqual(WallRotationSnap.closest(to: 93), 90)
        XCTAssertEqual(WallRotationSnap.closest(to: 140), 135)
        XCTAssertEqual(WallRotationSnap.closest(to: 179), 180)
        XCTAssertEqual(WallRotationSnap.closest(to: 358), 0)
    }

    func testWallElementRotationButtonPersistsSnappedAngle() {
        let suite = "wall-elements-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = CGSize(width: 1_024, height: 768)
        let center = CGPoint(x: 300, y: 240)
        let store = WallElementStore(defaults: defaults, persistenceKey: "transforms")

        store.update(.clock, center: center, scale: 1, rotation: .degrees(93), in: container)
        store.snapRotation(.clock, defaultCenter: center, in: container)

        let restored = WallElementStore(defaults: defaults, persistenceKey: "transforms")
        XCTAssertEqual(
            restored.transform(for: .clock, defaultCenter: center, in: container).rotationDegrees,
            90
        )
    }

    func testWallEditTransformPersistsMoveScaleAndRotationTogether() {
        let suite = "wall-edit-transform-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = CGSize(width: 1_024, height: 768)
        let destination = CGPoint(x: 710, y: 420)
        let store = WallElementStore(defaults: defaults, persistenceKey: "transforms")

        store.update(
            .weather,
            center: destination,
            scale: 1.6,
            rotation: .degrees(44),
            in: container
        )

        let restored = WallElementStore(defaults: defaults, persistenceKey: "transforms")
        let transform = restored.transform(for: .weather, defaultCenter: .zero, in: container)
        XCTAssertEqual(transform.normalizedX, Double(destination.x / container.width), accuracy: 0.0001)
        XCTAssertEqual(transform.normalizedY, Double(destination.y / container.height), accuracy: 0.0001)
        XCTAssertEqual(transform.scale, 1.6, accuracy: 0.0001)
        XCTAssertEqual(transform.rotationDegrees, 44, accuracy: 0.0001)
    }

    func testLegacyElementLayerControlsAlsoUseAbsoluteBoundaries() {
        let suite = "wall-layers-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WallElementStore(defaults: defaults, persistenceKey: "transforms")
        let original = store.stackingOrder
        let element = original[2]

        store.sendToBack(element)
        XCTAssertEqual(store.stackingOrder.first, element)
        store.bringToFront(element)
        let restored = WallElementStore(defaults: defaults, persistenceKey: "transforms")
        XCTAssertEqual(restored.stackingOrder.last, element)
    }

    func testWidgetPickerKeepsTheOriginalFifteenThenAddsTheStrangeShelf() {
        XCTAssertEqual(WallWidgetStore.catalog.count, 32)
        XCTAssertEqual(Set(WallWidgetStore.catalog).count, 32)
        XCTAssertEqual(WallWidgetKind.voiceAssistant.title, "Sift + Sonos")
        XCTAssertFalse(WallWidgetKind.voiceAssistant.detail.localizedCaseInsensitiveContains("talk"))
        XCTAssertEqual(
            Array(WallWidgetStore.catalog.suffix(16)),
            [
                .weekStrip, .threeMonths, .weekNumber, .dayOfYear,
                .astrologicalWeather, .mercuryMemo, .lacanianSignifier,
                .mirrorStage, .desireOfOther, .dreamResidue,
                .defenseMechanism, .projection, .superegoForecast,
                .strangeOracle, .unreliableNarrator, .dailyHoroscopes
            ]
        )
    }

    func testRetardCounterCountsExactWordsWithoutDoubleCountingPartials() {
        XCTAssertEqual(TrackedWordCounter.count(in: "retard, RETARDED"), 2)
        XCTAssertEqual(TrackedWordCounter.count(in: "retardation unretardedly"), 0)

        var counter = TrackedWordCounter()
        XCTAssertEqual(counter.delta(for: "someone said retard"), 1)
        XCTAssertEqual(counter.delta(for: "someone said retarded"), 0)
        XCTAssertEqual(counter.delta(for: "someone said retarded and then retard"), 1)
        counter.reset()
        XCTAssertEqual(counter.delta(for: "retarded"), 1)
    }

    func testRetardCounterAngelAppearsOnlyForRepeatedMultiDigitCounts() {
        XCTAssertTrue(retardCounterShowsAngel(for: 11))
        XCTAssertTrue(retardCounterShowsAngel(for: 777))
        XCTAssertFalse(retardCounterShowsAngel(for: 7))
        XCTAssertFalse(retardCounterShowsAngel(for: 12))
        XCTAssertFalse(retardCounterShowsAngel(for: 101))
    }

    func testRetardCounterLaunchOverridePersistsRequestedValue() {
        let suite = "retard-counter-launch-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(17, forKey: "wall.retardCounter.count.v1")

        XCTAssertEqual(
            initialRetardCounterValue(defaults: defaults, arguments: ["Wall", "-SetRetardCount", "222"]),
            222
        )
        XCTAssertEqual(defaults.integer(forKey: "wall.retardCounter.count.v1"), 222)
        XCTAssertEqual(initialRetardCounterValue(defaults: defaults, arguments: ["Wall"]), 222)
    }

    func testDailyHoroscopePeopleSignsAndResponseDecoding() throws {
        XCTAssertEqual(WallHoroscopeAPI.sign(for: .casey), "aquarius")
        XCTAssertEqual(WallHoroscopeAPI.sign(for: .drew), "pisces")
        XCTAssertEqual(WallHoroscopeAPI.sign(for: .alex), "cancer")
        XCTAssertEqual(WallHoroscopeAPI.sign(for: .blake), "sagittarius")
        XCTAssertEqual(WallHoroscopeAPI.sign(for: .ellis), "taurus")

        let response = Data(#"{"data":{"date":"2026-08-24","period":"daily","sign":"Cancer","horoscope":"Take  care\n of   the small things."}}"#.utf8)
        XCTAssertEqual(
            WallHoroscopeAPI.reading(from: response),
            WallHoroscopeReading(
                date: "2026-08-24",
                sign: "Cancer",
                horoscope: "Take care of the small things."
            )
        )
    }

    func testDailyHoroscopeSchedulesJustAfterTheNextLocalMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 25, hour: 23, minute: 58, second: 30
        )))
        let expected = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 26, hour: 0, minute: 0, second: 5
        )))

        XCTAssertEqual(WallHoroscopeAPI.nextDailyRefresh(after: now, calendar: calendar), expected)
    }

    func testDailyHoroscopeRequestIsDailyAndCacheBusting() throws {
        let request = WallHoroscopeAPI.request(for: .alex, day: "2026-09-02")
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(query["sign"], "cancer")
        XCTAssertEqual(query["wall_day"], "2026-09-02")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-cache")
    }

    func testDesireWidgetUsesCheapHighTemperatureDailyGeneration() throws {
        XCTAssertEqual(WallOracleConfiguration.model, "gpt-5.6-luna")
        XCTAssertEqual(WallOracleConfiguration.temperature, 1.8)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let beforeMidnight = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 25, hour: 23, minute: 59
        )))
        let afterMidnight = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 26, hour: 0, minute: 1
        )))

        XCTAssertNotEqual(
            WallOracleConfiguration.dayKey(for: beforeMidnight, calendar: calendar),
            WallOracleConfiguration.dayKey(for: afterMidnight, calendar: calendar)
        )
    }

    func testWidgetsPersistTransformsAndDoNotDuplicateKinds() throws {
        let suite = "wall-widgets-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = CGSize(width: 1_024, height: 768)
        let store = WallWidgetStore(defaults: defaults, persistenceKey: "widgets")

        let firstID = store.add(.moonPhase, in: container)
        XCTAssertEqual(store.add(.moonPhase, in: container), firstID)
        XCTAssertEqual(store.items.count, 1)

        store.update(
            firstID,
            center: CGPoint(x: 420, y: 310),
            scale: 1.4,
            rotation: .degrees(93),
            in: container
        )
        store.snapRotation(firstID)

        let restored = WallWidgetStore(defaults: defaults, persistenceKey: "widgets")
        XCTAssertEqual(restored.items.count, 1)
        let item = try XCTUnwrap(restored.items.first)
        XCTAssertEqual(item.kind, .moonPhase)
        XCTAssertEqual(item.scale, 1.4, accuracy: 0.001)
        XCTAssertEqual(item.rotationDegrees, 90)

        restored.remove(item.id)
        XCTAssertTrue(restored.items.isEmpty)
        XCTAssertNil(restored.selectedID)
        XCTAssertTrue(
            WallWidgetStore(defaults: defaults, persistenceKey: "widgets").items.isEmpty,
            "Deleting a widget must persist so it can be added again"
        )
    }

    func testWakePhraseMatchesNaturalVariantsWithoutConsumingTheCommand() {
        XCTAssertNotNil(WakePhrase.range(in: "hi wall play the living room"))
        XCTAssertNotNil(WakePhrase.range(in: "Hi, Wall — turn it down"))
        XCTAssertNotNil(WakePhrase.range(in: "Hey Wall play my Sift queue"))
        XCTAssertNotNil(WakePhrase.range(in: "yo wall turn it up"))
        XCTAssertNotNil(WakePhrase.range(in: "Wally play some music"))
        XCTAssertNil(WakePhrase.range(in: "the hallway light is on"))
        XCTAssertEqual(
            DonVoiceController.commandAfterWakeWord(in: "Hi Wall, play Tom T. Hall"),
            "play Tom T. Hall"
        )
        XCTAssertEqual(
            DonVoiceController.commandAfterWakeWord(in: "Wally, lower the volume"),
            "lower the volume"
        )
    }

    func testTerminalToolWaitsForOriginWhenToolFinishesFirst() {
        var state = TerminalToolTurnState()
        XCTAssertTrue(state.begin(callID: "call-1", originResponseID: "origin"))
        XCTAssertEqual(state.toolCompleted(output: "Changed the volume."), .none)
        XCTAssertEqual(
            state.responseFinished(id: "origin"),
            .finishCommand(callID: "call-1", output: "Changed the volume.")
        )
        XCTAssertEqual(state.responseFinished(id: "origin"), .none)
    }

    func testTerminalToolWaitsForToolWhenOriginFinishesFirst() {
        var state = TerminalToolTurnState()
        XCTAssertTrue(state.begin(callID: "call-2", originResponseID: "origin"))
        XCTAssertEqual(state.responseFinished(id: "origin"), .none)
        XCTAssertEqual(
            state.toolCompleted(output: "Paused Sonos."),
            .finishCommand(callID: "call-2", output: "Paused Sonos.")
        )
        XCTAssertEqual(state.responseFinished(id: "unrelated"), .none)
    }

    func testTerminalToolAcceptsOnlyFirstFunctionCall() {
        var state = TerminalToolTurnState()
        XCTAssertTrue(state.begin(callID: "first", originResponseID: "origin"))
        XCTAssertFalse(state.begin(callID: "second", originResponseID: "origin"))
    }

    func testRealtimeUsesLowerCostSilentCommandMode() {
        XCTAssertEqual(RealtimeClient.modelID, "gpt-realtime-2.1-mini")
        XCTAssertEqual(RealtimeClient.outputModalities, ["text"])
        XCTAssertFalse(RealtimeClient.allowsSpokenResponses)
    }

    func testSiftLibraryFixtureResolvesQueueAndNamedPlaylist() throws {
        let data = Data(#"""
        {
          "playlists": [
            {"id":"queue","name":"Queue","trackIds":["track-a"],"settings":{"deleteAfterListen":{"enabled":true,"targets":["playlist","cloud"]}}},
            {"id":"busy-summer","name":"Busy Summer","trackIds":["track-b"],"settings":{"deleteAfterListen":{"enabled":false,"targets":[]}}}
          ],
          "tracks": [{
            "id":"track-a",
            "primaryUrl":"https://example.com/a",
            "sourceService":"spotify",
            "metadata":{"title":"A","artist":"Artist","durationSeconds":181.5},
            "files":[{"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","bytes":12,"relativePath":"A.mp3","kind":"audio","mimeType":"audio/mpeg"}],
            "streamIds":["queue"]
          }]
        }
        """#.utf8)
        let library = try JSONDecoder().decode(SiftCloudLibrary.self, from: data)

        XCTAssertEqual(SiftSonosService.resolvePlaylist(named: "my queue", in: library.playlists)?.id, "queue")
        XCTAssertEqual(SiftSonosService.resolvePlaylist(named: "busy summer", in: library.playlists)?.id, "busy-summer")
        XCTAssertEqual(library.tracks.first?.audioFile?.relativePath, "A.mp3")
        XCTAssertEqual(library.tracks.first?.duration, 181.5)
        let queue = try XCTUnwrap(SiftSonosService.resolvePlaylist(named: "queue", in: library.playlists))
        XCTAssertEqual(SiftSonosService.orderedTracks(in: queue, library: library).map(\.id), ["track-a"])
    }

    func testSiftMetadataAcceptsDurationFallbackShapes() throws {
        let direct = try JSONDecoder().decode(
            SiftTrackMetadata.self,
            from: Data(#"{"title":"A","duration":"181.5"}"#.utf8)
        )
        let nested = try JSONDecoder().decode(
            SiftTrackMetadata.self,
            from: Data(#"{"title":"B","nowPlaying":{"durationSeconds":202}}"#.utf8)
        )

        XCTAssertEqual(direct.durationSeconds, 181.5)
        XCTAssertEqual(nested.durationSeconds, 202)
    }

    func testSiftArtworkPrefersAuthenticatedCloudFileAndFallsBackToRemoteMetadata() throws {
        let data = Data(#"""
        {
          "id":"track-art",
          "primaryUrl":null,
          "sourceService":"spotify",
          "metadata":{"title":"Art","artworkUrl":"https://i.scdn.co/image/fallback"},
          "files":[{
            "sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            "bytes":2048,
            "relativePath":"Artwork/Art cover.jpg",
            "kind":"artwork",
            "mimeType":"image/jpeg"
          }],
          "streamIds":["queue"]
        }
        """#.utf8)
        let track = try JSONDecoder().decode(SiftCloudTrack.self, from: data)
        let baseURL = try XCTUnwrap(URL(string: "https://sift.example.invalid/cloud/"))
        let protectedURL = try XCTUnwrap(SiftArtworkResolver.url(
            for: track,
            baseURL: baseURL,
            accessToken: "device-token"
        ))
        let components = try XCTUnwrap(URLComponents(url: protectedURL, resolvingAgainstBaseURL: false))
        let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })

        XCTAssertEqual(
            components.path,
            "/cloud/v1/files/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        )
        XCTAssertEqual(queryItems["name"] ?? nil, "Artwork/Art cover.jpg")
        XCTAssertEqual(queryItems["token"] ?? nil, "device-token")
        XCTAssertEqual(
            SiftArtworkResolver.url(for: track, baseURL: baseURL, accessToken: nil)?.absoluteString,
            "https://i.scdn.co/image/fallback"
        )
    }

    func testSiftSonosPlaybackClockAdvancesWhenSpeakerReportsZero() {
        let playingElapsed = SiftSonosPlaybackPolicy.reconciledElapsed(
            previous: 12,
            reported: 0,
            pollInterval: 0.4,
            wasPlaying: true
        )
        let pausedElapsed = SiftSonosPlaybackPolicy.reconciledElapsed(
            previous: playingElapsed,
            reported: 0,
            pollInterval: 1,
            wasPlaying: false
        )

        XCTAssertEqual(playingElapsed, 12.4, accuracy: 0.001)
        XCTAssertEqual(pausedElapsed, playingElapsed, accuracy: 0.001)
        XCTAssertFalse(SiftSonosPlaybackPolicy.shouldAdvance(
            elapsed: 179.2,
            duration: 180,
            state: .playing,
            observedPlaying: true
        ))
        XCTAssertTrue(SiftSonosPlaybackPolicy.shouldAdvance(
            elapsed: 179.25,
            duration: 180,
            state: .playing,
            observedPlaying: true
        ))
    }

    func testSiftDeparturePlanMatchesDeleteAfterListenSettings() throws {
        let playlist = SiftCloudPlaylist(
            id: "queue",
            name: "Queue",
            trackIds: ["track-a"],
            settings: SiftPlaylistSettings(
                deleteAfterListen: SiftDeleteAfterListen(
                    enabled: true,
                    targets: ["playlist", "cloud", "device", "folder"]
                )
            )
        )

        XCTAssertNil(SiftSonosService.departurePlan(
            playlist: playlist,
            trackID: "track-a",
            listenedSeconds: 4.99
        ))
        XCTAssertEqual(
            SiftSonosService.departurePlan(
                playlist: playlist,
                trackID: "track-a",
                listenedSeconds: 5
            ),
            SiftDeparturePlan(
                playlistID: "queue",
                trackID: "track-a",
                deleteTargets: ["playlist", "cloud", "device", "folder"]
            )
        )
    }
}

private final class GoonEventRecorderSpy: GoonEventRecording {
    private(set) var events: [GoonLogEvent] = []

    func record(_ event: GoonLogEvent) {
        events.append(event)
    }
}
