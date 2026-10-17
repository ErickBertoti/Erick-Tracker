import XCTest

@MainActor final class WorkoutFlowTests: XCTestCase {
    func testOfflineSessionResumeAndCorrection() throws {
        let app = XCUIApplication()
        let id = UUID().uuidString
        app.launchArguments = ["-ui-testing", "-ui-testing-store", id, "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
        app.launch()
        let workout = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "workout-")).firstMatch
        XCTAssertTrue(workout.waitForExistence(timeout: 15))
        workout.tap()
        app.buttons["Iniciar treino"].tap()
        let reps = app.textFields["Repetições da etapa 1"]
        XCTAssertTrue(reps.waitForExistence(timeout: 10)); reps.tap(); reps.typeText("12")
        let load = app.textFields["Carga em kg da etapa 1"]
        load.tap(); load.typeText("15,5")
        app.buttons["OK"].tap()
        let register = app.buttons["Registrar série"]
        if !register.isHittable { app.swipeUp() }
        register.tap()
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Sessão com descanso"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.terminate(); app.launch()
        let resume = app.buttons["resume-session"]
        XCTAssertTrue(resume.waitForExistence(timeout: 15)); resume.tap()
        XCTAssertTrue(app.textFields["Repetições da etapa 1"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["Repetições da etapa 1"].value as? String, "12")
        XCTAssertEqual(app.textFields["Carga em kg da etapa 1"].value as? String, "15,5")
        app.buttons["Concluir"].tap()
        app.buttons["Concluir treino"].tap()
        XCTAssertTrue(app.staticTexts["Concluído"].waitForExistence(timeout: 10))
        let correctedReps = app.textFields["Repetições da etapa 1"]
        correctedReps.tap(); correctedReps.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2) + "13")
        app.buttons["OK"].tap()
        app.buttons["Fechar"].tap()
        app.terminate(); app.launch()
        app.tabBars.buttons["Histórico"].tap()
        let history = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "history-session-")).firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 10)); history.tap()
        XCTAssertTrue(app.staticTexts["13 reps × 15,5 kg"].waitForExistence(timeout: 10))
        app.buttons["Corrigir registro"].tap()
        XCTAssertTrue(app.textFields["Repetições da etapa 1"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["Repetições da etapa 1"].value as? String, "13")
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = XCTAttachment(screenshot: app.screenshot()); landscape.name = "Sessão concluída horizontal"; landscape.lifetime = .keepAlways; add(landscape)
        XCUIDevice.shared.orientation = .portrait
    }
    func testSettingsAndAppearance() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-store", UUID().uuidString, "-AppleLanguages", "(pt-BR)"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Ajustes"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Ajustes"].tap()
        XCTAssertTrue(app.staticTexts["Aparência"].waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Ajustes do iPhone"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
