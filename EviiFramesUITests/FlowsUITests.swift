import XCTest

/// Clicks every screen. Screenshot fixtures do not run the model: Start is a no-op,
/// and cancel is the visible control. Unsupported files are opened by ProbeQATests;
/// this target only checks the alert the app shows for them.
final class FlowsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testHomeQueueSettingsAndBackground() {
        let app = launch("home")
        XCTAssertTrue(app.staticTexts["Evii Frames"].waitForExistence(timeout: 8))
        app.buttons["mode-interp"].tap()
        app.buttons["mode-slow"].tap()
        app.buttons["Усі"].tap()
        XCTAssertTrue(app.staticTexts["Нещодавні"].waitForExistence(timeout: 5))
        app.buttons["Назад"].tap()
        app.tabBars.buttons["Черга"].tap()
        XCTAssertTrue(app.staticTexts["Черга"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["start-button"].waitForExistence(timeout: 4))
        app.buttons["start-button"].tap()
        app.tabBars.buttons["Налаштування"].tap()
        let device = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "iPhone 14 Pro")).firstMatch
        XCTAssertTrue(device.waitForExistence(timeout: 4))
        app.switches["Темна тема"].tap()
        XCUIDevice.shared.press(.home)
        sleep(1)
        app.activate()
        let foreground = Date().addingTimeInterval(12)
        while app.state != .runningForeground && Date() < foreground {
            app.activate()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        XCTAssertEqual(app.state, .runningForeground)
        app.tabBars.buttons["Головна"].tap()
        XCTAssertTrue(app.staticTexts["Evii Frames"].waitForExistence(timeout: 6))
    }

    func testInterpolationExportAndSettings() {
        let app = launch("interpolation")
        XCTAssertTrue(app.buttons["start-button"].waitForExistence(timeout: 8))
        tap(app, "x8")
        tap(app, "x16")
        tap(app, "Цільовий FPS")
        tap(app, "60")
        tap(app, "Множник")
        tap(app, "x4")
        app.buttons["theme-toggle"].tap()
        let exportRow = app.buttons["nav-Експорт"]
        XCTAssertTrue(exportRow.waitForExistence(timeout: 5))
        for _ in 0..<5 where !exportRow.isHittable {
            app.swipeUp()
        }
        exportRow.tap()
        XCTAssertTrue(app.buttons["H.264"].waitForExistence(timeout: 8))
        tap(app, "H.264")
        tap(app, "HEVC")
        tap(app, "ProRes")
        if app.alerts.firstMatch.waitForExistence(timeout: 1) {
            app.alerts.buttons["Гаразд"].tap()
        }
        tap(app, "MP4")
        tap(app, "MOV")
        tap(app, "60")
        tap(app, "720p")
        tap(app, "1080p")
        let sound = app.switches["Зберегти звук"]
        if !sound.waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        XCTAssertTrue(sound.waitForExistence(timeout: 3))
        sound.tap()
        app.switches["Зберегти метадані"].tap()
        tap(app, "Мін. тривалість")
        tap(app, "5 с")
        tap(app, "Назва файлу")
        let field = app.textFields.firstMatch
        if field.waitForExistence(timeout: 3) {
            field.tap()
            field.typeText("x")
        }
        app.buttons["Гаразд"].tap()
        app.buttons["Назад"].tap()
        app.buttons["nav-Інтерполяція"].tap()
        XCTAssertTrue(app.staticTexts["МОДЕЛЬ"].waitForExistence(timeout: 5))
        tap(app, "RIFE 4.26")
        tap(app, "RIFE heavy")
        tap(app, "RIFE 4.22")
        tap(app, "RIFE lite")
        tap(app, "Apple")
        tap(app, "RIFE 4.25")
        let scenes = app.switches["Пропускати зміну сцени"]
        if !scenes.waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        XCTAssertTrue(scenes.waitForExistence(timeout: 3))
        scenes.tap()
        tap(app, "Швидко")
        tap(app, "Точно")
        tap(app, "Вимк.")
        let loop = app.switches["Зациклити"]
        if !loop.waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        XCTAssertTrue(loop.waitForExistence(timeout: 3))
        loop.tap()
        let quality = app.switches["Максимальна якість"]
        if !quality.waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        XCTAssertTrue(quality.waitForExistence(timeout: 3))
        quality.tap()
        app.switches["Режим UHD"].tap()
        let stepwise = app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", "Покроково", "Покроково")).firstMatch
        if !stepwise.waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        tap(app, "Покроково")
        tap(app, "Усе разом")
        app.buttons["Назад"].tap()
        app.buttons["start-button"].tap()
        XCTAssertTrue(app.buttons["start-button"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["cancel-processing"].exists)
    }

    func testSlowMoControls() {
        let app = launch("slowmo")
        XCTAssertTrue(app.staticTexts["Сповільнення"].waitForExistence(timeout: 8))
        tap(app, "Фрагмент")
        tap(app, "Весь кліп")
        tap(app, "x2")
        tap(app, "x8")
        tap(app, "Звук у фрагменті")
        tap(app, "Розтягнути")
        app.buttons["slowmo-next"].tap()
        XCTAssertTrue(app.staticTexts["Сповільнення"].exists)
    }

    func testProcessingCancelAndDone() {
        let app = launch("processing")
        XCTAssertTrue(app.staticTexts["Обробка"].waitForExistence(timeout: 8))
        let cancel = app.buttons["cancel-processing"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 4))
        if cancel.isHittable {
            cancel.tap()
        } else {
            app.staticTexts["Обробка"].coordinate(withNormalizedOffset: CGVector(dx: 4, dy: 0.5)).tap()
        }
        XCTAssertEqual(app.state, .runningForeground)
        app.terminate()

        let done = launch("done")
        XCTAssertTrue(done.staticTexts["Готово"].waitForExistence(timeout: 8))
        done.buttons["До"].tap()
        done.buttons["Після"].tap()
        done.buttons["0.25x"].tap()
        done.buttons["Поруч"].tap()
        XCTAssertTrue(done.buttons["primary-button"].exists)
        done.buttons["edit-again"].tap()
        XCTAssertTrue(done.staticTexts["Інтерполяція"].waitForExistence(timeout: 5))
    }

    func testUnsupportedFileAlert() {
        let app = launch("unsupported")
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 6))
        let missing = alert.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "немає відеодоріжки")).firstMatch
        XCTAssertTrue(missing.waitForExistence(timeout: 2))
        alert.buttons["Гаразд"].tap()
        XCTAssertTrue(app.staticTexts["Evii Frames"].waitForExistence(timeout: 4))
    }

    private func tap(_ app: XCUIApplication, _ title: String) {
        let button = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@ OR label BEGINSWITH %@", title, title, title)).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), title)
        button.tap()
    }

    private func launch(_ screen: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-eviiScreenshot", screen]
        app.launch()
        return app
    }
}
