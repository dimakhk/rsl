import XCTest

/* Presses the buttons the way a finger does, in the Simulator, and checks
   what the app shows after each press.

   The other tests call the app's code directly and would pass with a button
   that cannot be reached at all - which is exactly what happened once: the
   history button lay under the invisible tap area of the chat's title. */

final class RSLUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-nosplash", "1"]
        // If the system still asks about the camera, say yes.
        addUIInterruptionMonitor(withDescription: "camera") { alert in
            for label in ["Allow", "OK", "Разрешить"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()
    }

    private func button(_ label: String) -> XCUIElement {
        let found = app.buttons[label]
        XCTAssertTrue(found.waitForExistence(timeout: 30), "no button «\(label)» on screen")
        return found
    }

    private func wait(_ element: XCUIElement, _ condition: String, timeout: TimeInterval = 10) -> Bool {
        let met = expectation(for: NSPredicate(format: condition), evaluatedWith: element)
        return XCTWaiter().wait(for: [met], timeout: timeout) == .completed
    }

    private func message(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", text)).firstMatch
    }

    func testHistoryOpensAndCloses() {
        let history = button("История чатов")
        history.tap()
        let close = app.buttons["Вернуться в чат"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "pressing the history button did not open the history")
        XCTAssertTrue(app.staticTexts["История"].exists)
        XCTAssertTrue(app.buttons["Новый чат"].exists)
        close.tap()
        XCTAssertTrue(wait(close, "exists == false"), "the history did not close")
        XCTAssertTrue(app.buttons["История чатов"].waitForExistence(timeout: 10))
    }

    func testSoundSwitches() {
        let sound = button("Озвучка")
        XCTAssertEqual(sound.value as? String, "включена")
        sound.tap()
        XCTAssertTrue(wait(sound, "value == 'выключена'"))
        sound.tap()
        XCTAssertTrue(wait(sound, "value == 'включена'"))
    }

    /* A pill opens its mode; pressed again, it closes the mode. */
    func testPillsAreSwitches() {
        for label in ["Жесты", "Голос"] {
            let pill = button(label)
            XCTAssertFalse(pill.isSelected, "«\(label)» is on before anything was pressed")
            pill.tap()
            XCTAssertTrue(wait(pill, "selected == true"), "«\(label)» did not open")
            pill.tap()
            XCTAssertTrue(wait(pill, "selected == false"), "«\(label)» did not close on the second press")
        }
        // straight from one mode into another
        let gesture = button("Жесты"), voice = button("Голос")
        gesture.tap()
        XCTAssertTrue(wait(gesture, "selected == true"))
        voice.tap()
        XCTAssertTrue(wait(voice, "selected == true"))
        XCTAssertTrue(wait(gesture, "selected == false"), "two modes are open at once")
        voice.tap()
        XCTAssertTrue(wait(voice, "selected == false"))
    }

    /* What is typed shows in the chat; a tap beside the keyboard puts it away
       and the message stays. Digits: nothing for autocorrection to "fix". */
    func testKeyboardWritesIntoTheChat() {
        button("Клавиатура").tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 15), "the keyboard did not come up")
        app.typeText("2468 1357")
        XCTAssertTrue(message("2468 1357").waitForExistence(timeout: 10), "typed text is not in the chat")
        app.typeText("\n")
        app.typeText("90")
        XCTAssertTrue(message("90").waitForExistence(timeout: 10), "a second message did not start after Return")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        XCTAssertTrue(wait(app.keyboards.firstMatch, "exists == false"), "a tap beside the keyboard did not put it away")
        let keys = button("Клавиатура")
        XCTAssertFalse(keys.isSelected)
        XCTAssertTrue(message("2468 1357").exists)
        XCTAssertTrue(message("90").exists, "what was typed and not sent was lost with the keyboard")
    }
}
