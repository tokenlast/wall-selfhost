import XCTest

final class WallTouchArchitectureUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft

        addUIInterruptionMonitor(withDescription: "Wall permissions") { alert in
            for title in ["Don’t Allow", "Don't Allow", "Not Now", "OK", "Allow"] {
                let button = alert.buttons[title]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            return false
        }

        app = XCUIApplication()
        app.launchArguments = ["-DisableWakeWord", "-ResetWallTestState"]
        app.launch()
        dismissPendingPermissionAlerts()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testLiveWallTouchArchitecture() throws {
        let gallery = element("wall.gallery.button")
        XCTAssertTrue(gallery.waitForExistence(timeout: 8), "Gallery button never appeared")
        XCTAssertTrue(gallery.isHittable)
        gallery.tap()

        let galleryDone = element("wall.gallery.done")
        XCTAssertTrue(galleryDone.waitForExistence(timeout: 5), "Gallery sheet never opened")
        XCTAssertTrue(galleryDone.isHittable)
        galleryDone.tap()

        for identifier in ["wall.camera.button", "wall.settings.button", "wall.pencil.button", "wall.widget.add"] {
            let control = element(identifier)
            XCTAssertTrue(control.waitForExistence(timeout: 5), "Missing fixed Wall control: \(identifier)")
            XCTAssertTrue(control.isHittable, "Fixed Wall control is not tappable: \(identifier)")
        }

        // A long-hold on an object enters edit with that exact object selected.
        let clockDisplay = element("wall.clock.display")
        XCTAssertTrue(clockDisplay.waitForExistence(timeout: 5))
        clockDisplay.press(forDuration: 0.7)
        XCTAssertTrue(element("wall.edit.done").waitForExistence(timeout: 3))

        let clock = element("wall.element.clock")
        XCTAssertTrue(clock.waitForExistence(timeout: 5), "Clock edit surface never appeared")
        XCTAssertTrue(clock.isHittable)
        let clockTransform = element("wall.element.clock.transform")
        XCTAssertTrue(clockTransform.waitForExistence(timeout: 2))
        let transformState = element("wall.edit.transform-state")
        XCTAssertTrue(transformState.waitForExistence(timeout: 2))

        for identifier in [
            "wall.element.clock.snap",
            "wall.element.clock.back",
            "wall.element.clock.forward"
        ] {
            let control = element(identifier)
            XCTAssertTrue(control.waitForExistence(timeout: 3), "Missing clock control: \(identifier)")
            XCTAssertTrue(control.isHittable, "Clock control is not tappable: \(identifier)")
            control.tap()
        }

        // A tap on another object switches selection; all subsequent direct
        // manipulation belongs to that newly selected object.
        let weatherSelector = element("wall.element.weather.select")
        XCTAssertTrue(weatherSelector.waitForExistence(timeout: 3))
        weatherSelector.tap()
        XCTAssertTrue(element("wall.element.weather.snap").waitForExistence(timeout: 3))
        let selectedWeather = element("wall.element.weather")
        XCTAssertTrue(selectedWeather.waitForExistence(timeout: 3))

        // Exercise the real two-finger UIKit rotation recognizer.
        let beforeRotation = element("wall.edit.transform-state").label
        selectedWeather.rotate(.pi / 4, withVelocity: 1)
        let rotationChanged = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                self.element("wall.edit.transform-state").label != beforeRotation
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [rotationChanged], timeout: 3), .completed)

        let beforeDrag = element("wall.edit.transform-state").label
        let originalFrame = selectedWeather.frame
        let start = selectedWeather.coordinate(withNormalizedOffset: CGVector(dx: 0.28, dy: 0.72))
        let horizontalTravel: CGFloat = originalFrame.midX < app.frame.midX ? 90 : -90
        let verticalTravel: CGFloat = originalFrame.midY < app.frame.midY ? 55 : -55
        let destination = start.withOffset(CGVector(dx: horizontalTravel, dy: verticalTravel))
        start.press(forDuration: 0.12, thenDragTo: destination)

        let movementSettled = expectation(description: "movement animation settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            movementSettled.fulfill()
        }
        wait(for: [movementSettled], timeout: 2)
        let dragChanged = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                self.element("wall.edit.transform-state").label != beforeDrag
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dragChanged], timeout: 3), .completed)

        // The fixed Done button remains operable after direct manipulation.
        let doneAfterDrag = element("wall.edit.done")
        XCTAssertTrue(doneAfterDrag.waitForExistence(timeout: 2))
        XCTAssertTrue(doneAfterDrag.isHittable)
        doneAfterDrag.tap()

        // A blank-canvas tap is the universal way out of edit mode.
        let movedDisplay = element("wall.clock.display")
        XCTAssertTrue(movedDisplay.waitForExistence(timeout: 3))
        enterEditMode()
        XCTAssertTrue(element("wall.edit.done").waitForExistence(timeout: 3))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.52, dy: 0.92)).tap()
        XCTAssertFalse(element("wall.edit.done").waitForExistence(timeout: 1))

        // Explicit edit entry can be repeated and its fixed Done control stays
        // above every selected transform surface.
        enterEditMode()
        let finishEditing = element("wall.edit.done")
        XCTAssertTrue(finishEditing.waitForExistence(timeout: 3))
        XCTAssertTrue(finishEditing.isHittable)
        finishEditing.tap()

        let settings = element("wall.settings.button")
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        XCTAssertTrue(settings.isHittable)
        settings.tap()

        XCTAssertTrue(app.navigationBars["Wall"].waitForExistence(timeout: 5), "Settings UI never opened")
        XCTAssertTrue(element("wall.settings.done").isHittable)
        XCTAssertTrue(element("wall.settings.wake-toggle").exists)
    }

    func testGoonMenuPlusAndMinusAdjustTallyWithoutEditMode() throws {
        let addButton = element("wall.goon.add")
        XCTAssertTrue(addButton.waitForExistence(timeout: 8))
        XCTAssertTrue(addButton.isHittable)

        let count = element("wall.goon.count.alex")
        XCTAssertTrue(count.waitForExistence(timeout: 3))
        let originalCount = try XCTUnwrap(Int(count.label))

        addButton.tap()
        let plus = element("wall.goon.menu.plus.alex")
        XCTAssertTrue(plus.waitForExistence(timeout: 3))
        XCTAssertTrue(plus.isHittable)
        plus.tap()

        let incremented = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in Int(count.label) == originalCount + 1 },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [incremented], timeout: 3), .completed)

        let minus = element("wall.goon.menu.minus.alex")
        XCTAssertTrue(minus.waitForExistence(timeout: 3))
        XCTAssertTrue(minus.isHittable)
        minus.tap()

        let decremented = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in Int(count.label) == originalCount },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [decremented], timeout: 3), .completed)

        XCTAssertTrue(plus.isHittable)
        plus.tap()
        let incrementedAgain = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in Int(count.label) == originalCount + 1 },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [incrementedAgain], timeout: 3), .completed)
    }

    func testSpotifyCatalogSearchDoesNotRequirePersonalLogin() {
        app.terminate()
        app.launchArguments += ["-WallVerifySpotifySearch", "is there really no happiness porter robinson"]
        app.launch()
        XCTAssertTrue(element("wall.music.close").waitForExistence(timeout: 8))
        XCTAssertFalse(element("wall.music.spotify.connect").exists)
        XCTAssertFalse(app.staticTexts["Wall could not find an exact Spotify track for that request."].exists)
    }

    func testRapidTripleAppearsOverOpenTallyMenuAndLeavesButtonsUsable() {
        let button = element("wall.goon.add")
        XCTAssertTrue(button.waitForExistence(timeout: 8))
        button.tap()
        let plus = element("wall.goon.menu.plus.alex")
        XCTAssertTrue(plus.waitForExistence(timeout: 3))
        plus.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        let combo = element("wall.goon.combo.phase")
        XCTAssertTrue(combo.waitForExistence(timeout: 3), "Combo must render above the tally menu")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Triple celebration above open tally menu"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: combo)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 7), .completed)
        XCTAssertTrue(plus.isHittable)
        let minus = element("wall.goon.menu.minus.alex")
        minus.tap(withNumberOfTaps: 3, numberOfTouches: 1)
    }

    func testTappingSonosSongTitleOpensMusicPanel() {
        let title = element("wall.sonos.title")
        XCTAssertTrue(title.waitForExistence(timeout: 8), "Sonos song title never appeared")
        XCTAssertTrue(title.isHittable, "Sonos song title is not tappable")
        title.tap()

        let close = element("wall.music.close")
        XCTAssertTrue(close.waitForExistence(timeout: 4), "Tapping the song title did not open music")
        XCTAssertTrue(close.isHittable)
        close.tap()
        XCTAssertFalse(close.waitForExistence(timeout: 1))
    }

    func testGIFTwoFingerRotationPersists() throws {
        let gif = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Animated GIF"))
            .firstMatch
        XCTAssertTrue(gif.waitForExistence(timeout: 8))
        enterEditMode()
        XCTAssertTrue(element("wall.edit.done").waitForExistence(timeout: 3))

        let gifSelector = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier MATCHES %@",
                "wall\\.gif\\.[0-9A-Fa-f-]{36}\\.select"
            ))
            .firstMatch
        XCTAssertTrue(gifSelector.waitForExistence(timeout: 3))
        gifSelector.tap()

        let state = element("wall.edit.transform-state")
        XCTAssertTrue(state.waitForExistence(timeout: 2))
        XCTAssertTrue(state.label.hasPrefix("gif:"), "Tap did not select the GIF")
        let beforeRotation = state.label
        let transform = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier MATCHES %@",
                "wall\\.gif\\.[0-9A-Fa-f-]{36}"
            ))
            .firstMatch
        XCTAssertTrue(transform.waitForExistence(timeout: 3), "GIF transform surface never appeared")
        transform.rotate(.pi / 3, withVelocity: 1)

        let rotationChanged = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in state.label != beforeRotation },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [rotationChanged], timeout: 3),
            .completed,
            "Two-finger GIF rotation was not persisted"
        )
    }

    func testGifCitiesSearchFieldDoesNotDismissTheBrowser() {
        let add = element("wall.widget.add")
        XCTAssertTrue(add.waitForExistence(timeout: 8))
        add.tap()

        let openGifCities = app.descendants(matching: .any)["Open GifCities"]
        XCTAssertTrue(openGifCities.waitForExistence(timeout: 3))
        openGifCities.tap()

        let websiteSearch = app.webViews.searchFields.firstMatch
        XCTAssertTrue(websiteSearch.waitForExistence(timeout: 10))
        XCTAssertTrue(websiteSearch.isHittable)
        websiteSearch.tap()

        let search = element("wall.gif.search")
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        let focused = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasKeyboardFocus == true"),
            object: search
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [focused], timeout: 3),
            .completed,
            "Tapping GifCities' search field did not focus Wall's keyboard-backed search"
        )
        search.typeText("sparkles")
        search.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(search.exists, "GifCities browser dismissed while searching")
        XCTAssertTrue(element("wall.gif.done").exists)
    }

    func testAddedWidgetHasReachableDeleteControl() {
        let add = element("wall.widget.add")
        XCTAssertTrue(add.waitForExistence(timeout: 8))
        add.tap()

        let addDate = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Add Date"))
            .firstMatch
        XCTAssertTrue(addDate.waitForExistence(timeout: 3), "Date widget row never appeared")
        XCTAssertTrue(addDate.isHittable)
        addDate.tap()

        let pickerDone = element("wall.widget.picker.done")
        XCTAssertTrue(pickerDone.isHittable)
        pickerDone.tap()

        let delete = element("wall.widget.date.delete")
        XCTAssertTrue(delete.waitForExistence(timeout: 3), "Selected widget has no delete control")
        XCTAssertTrue(delete.isHittable, "Widget delete control is not tappable")
        delete.tap()
        XCTAssertFalse(delete.waitForExistence(timeout: 1), "Widget remained selected after deletion")

        add.tap()
        let addDateAgain = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Add Date"))
            .firstMatch
        XCTAssertTrue(addDateAgain.waitForExistence(timeout: 3), "Deleted widget cannot be added again")
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func enterEditMode() {
        let add = element("wall.widget.add")
        XCTAssertTrue(add.waitForExistence(timeout: 3))
        add.tap()
        let pickerDone = element("wall.widget.picker.done")
        XCTAssertTrue(pickerDone.waitForExistence(timeout: 3))
        pickerDone.tap()
    }

    private func dismissPendingPermissionAlerts() {
        for _ in 0..<4 {
            if element("wall.gallery.button").exists { return }
            app.tap()
            _ = element("wall.gallery.button").waitForExistence(timeout: 1)
        }
    }
}
