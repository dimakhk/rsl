import XCTest

/* Presses the buttons the way a finger does, in the Simulator, and checks
   what the app shows after each press.

   The other tests call the app's code directly and would pass with a button
   that cannot be reached at all - which is exactly what happened once: the
   history button lay under the invisible tap area of the chat's title.

   The app is started with nothing kept from earlier runs and without the
   microphone: the Simulator has none, and a test must not depend on the one
   before it. */

final class RSLUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-nosplash", "1", "-nostore", "1", "-noaudio", "1"]
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

    /* A message in the chat (a bubble), by its text. The name of the chat in
       the top bar may be the same words, and is not a message. */
    private func message(_ text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ AND identifier != 'chat-title'", text)).firstMatch
    }

    /* When a check fails: what is on screen, into the log (lines starting RSLDUMP). */
    private func found(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        if element.waitForExistence(timeout: timeout) { return true }
        for line in app.debugDescription.split(whereSeparator: \.isNewline) {
            print("RSLDUMP", line.trimmingCharacters(in: .whitespaces))
        }
        return false
    }

    /* The name of the open chat, in the top bar. */
    private var title: XCUIElement { app.descendants(matching: .any)["chat-title"] }

    /* Types a message and puts the keyboard away. Digits: nothing for autocorrection to "fix". */
    private func write(_ text: String) {
        button("Клавиатура").tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 15), "the keyboard did not come up")
        app.typeText(text)
        app.typeText("\n")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        XCTAssertTrue(wait(app.keyboards.firstMatch, "exists == false"), "a tap beside the keyboard did not put it away")
    }

    /* "On screen and can be pressed" is asked, not "exists": the history
       screen is always there, slid out of sight below the bottom edge. */
    func testHistoryOpensAndCloses() {
        let history = button("История чатов")
        let close = app.buttons["Вернуться в чат"]
        XCTAssertFalse(close.isHittable, "the history is open before anything was pressed")
        history.tap()
        XCTAssertTrue(wait(close, "hittable == true"), "pressing the history button did not open the history")
        XCTAssertTrue(app.staticTexts["История"].isHittable)
        close.tap()
        XCTAssertTrue(wait(close, "hittable == false"), "the history did not close")
        XCTAssertTrue(wait(history, "hittable == true"), "the chat did not come back")
    }

    /* A chat takes its name from what was said in it; «+» starts a new one;
       the old one waits in the history and opens again with its messages. */
    func testChatsAreNamedKeptAndReopened() {
        XCTAssertTrue(title.waitForExistence(timeout: 30))
        XCTAssertEqual(title.label, "Новый чат")
        write("2468 1357")
        XCTAssertTrue(found(message("2468 1357")), "the typed message is not in the chat")
        XCTAssertTrue(wait(title, "label == '2468 1357'"), "the chat was not named after its first message")

        button("История чатов").tap()
        let plus = app.buttons["new-chat"]
        XCTAssertTrue(wait(plus, "hittable == true"))
        plus.tap()
        XCTAssertTrue(wait(plus, "hittable == false"), "the new chat did not open")
        XCTAssertTrue(wait(message("2468 1357"), "exists == false"), "the new chat is not empty")
        XCTAssertTrue(wait(title, "label == 'Новый чат'"))

        // back to the first chat: it is one row above the open one, so the
        // first tap brings it to the centre and the second opens it
        button("История чатов").tap()
        let row = app.buttons["2468 1357"]
        XCTAssertTrue(wait(row, "hittable == true"), "the earlier chat is not in the history")
        row.tap()
        XCTAssertTrue(wait(row, "selected == true"), "the wheel did not turn to the chat that was tapped")
        row.tap()
        XCTAssertTrue(found(message("2468 1357")), "the earlier chat did not open with its messages")
        XCTAssertTrue(wait(plus, "hittable == false"))
        XCTAssertTrue(wait(title, "label == '2468 1357'"))
    }

    /* «+» while the open chat is still empty has nothing to add: it just goes back to it. */
    func testPlusOnAnEmptyChatAddsNothing() {
        button("История чатов").tap()
        let plus = app.buttons["new-chat"]
        XCTAssertTrue(wait(plus, "hittable == true"))
        plus.tap()
        XCTAssertTrue(wait(plus, "hittable == false"))
        XCTAssertTrue(wait(title, "hittable == true"))
        XCTAssertEqual(title.label, "Новый чат")
    }

    func testSoundSwitches() {
        let sound = button("Озвучка")
        XCTAssertTrue(wait(sound, "value BEGINSWITH 'включена'"))
        sound.tap()
        XCTAssertTrue(wait(sound, "value BEGINSWITH 'выключена'"), "a tap did not turn the sound off")
        sound.tap()
        XCTAssertTrue(wait(sound, "value BEGINSWITH 'включена'"))
        // a long press changes the voice
        XCTAssertTrue(wait(sound, "value ENDSWITH 'Милена'"))
        sound.press(forDuration: 1.2)
        XCTAssertTrue(wait(sound, "value ENDSWITH 'Юрий'"), "a long press did not change the voice")
        XCTAssertTrue(wait(sound, "value BEGINSWITH 'включена'"), "a long press also switched the sound")
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

    /* In the gesture mode: the button that changes the camera. */
    func testCameraSwitch() {
        let flip = app.buttons["Сменить камеру"]
        XCTAssertFalse(flip.isHittable, "the camera button is on screen outside the gesture mode")
        button("Жесты").tap()
        XCTAssertTrue(wait(flip, "hittable == true"), "no camera button in the gesture mode")
        XCTAssertEqual(flip.value as? String, "передняя")
        flip.tap()
        XCTAssertTrue(wait(flip, "value == 'задняя'"), "the camera did not change")
        flip.tap()
        XCTAssertTrue(wait(flip, "value == 'передняя'"))
    }

    /* What is typed shows in the chat while it is typed; a tap beside the
       keyboard puts it away and nothing typed is lost. */
    func testKeyboardWritesIntoTheChat() {
        button("Клавиатура").tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 15), "the keyboard did not come up")
        app.typeText("2468 1357")
        XCTAssertTrue(found(message("2468 1357")), "typed text is not in the chat")
        app.typeText("\n")
        app.typeText("90")
        XCTAssertTrue(found(message("90")), "a second message did not start after Return")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        XCTAssertTrue(wait(app.keyboards.firstMatch, "exists == false"), "a tap beside the keyboard did not put it away")
        XCTAssertFalse(button("Клавиатура").isSelected)
        XCTAssertTrue(message("2468 1357").exists)
        XCTAssertTrue(message("90").exists, "what was typed and not sent was lost with the keyboard")
    }
}
