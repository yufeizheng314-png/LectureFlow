import XCTest

/// Runs against the installed LectureFlow app after CI injects build/ui-fixture
/// into Documents/LectureFlow. No recording, model download or cloud request.
final class LectureFlowFeatureUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testMindMapInteractionAndChineseLanguageSurviveRelaunch() throws {
        let app = XCUIApplication(bundleIdentifier: "com.yufeizheng.lectureflow")
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
        defer { app.terminate() }

        let fixtureTitle = "自动化测试课程 · 水循环（非真实云生成）"
        let course = app.buttons["lectureflow.map.course"]
        waitForHittable(course, "The injected water-cycle lesson must open with its course map")
        XCTAssertTrue(course.label.contains(fixtureTitle), "The map must belong to the injected fixture course")
        let originalCourseLabel = course.label
        keepScreenshot(app, named: "Fixture course mind map")

        // The initial fit depends on the iPad viewport, so read the actual value.
        let zoom = app.staticTexts["lectureflow.map.zoom"]
        XCTAssertTrue(zoom.waitForExistence(timeout: 10))
        let initialPercent = try percentage(from: zoom)
        XCTAssertGreaterThanOrEqual(initialPercent, 45)
        XCTAssertLessThanOrEqual(initialPercent, 85)
        let enlarge = app.buttons["放大导图"]
        waitForHittable(enlarge, "The zoom-in control must be available")
        enlarge.tap()
        waitForLabel(zoom, equalTo: "\(initialPercent + 20)%")
        let shrink = app.buttons["缩小导图"]
        waitForHittable(shrink, "The zoom-out control must be available")
        shrink.tap()
        waitForLabel(zoom, equalTo: "\(initialPercent)%")

        let fullscreen = app.buttons["lectureflow.map.fullscreen"]
        waitForHittable(fullscreen, "The map must offer a full-screen view")
        fullscreen.tap()
        let fullscreenBar = app.navigationBars["课堂思维导图"]
        XCTAssertTrue(fullscreenBar.waitForExistence(timeout: 10), "Full screen must present the course map")
        keepScreenshot(app, named: "Full-screen course mind map")
        let closeFullscreen = fullscreenBar.buttons["完成"]
        waitForHittable(closeFullscreen, "Full screen must have a working close control")
        closeFullscreen.tap()
        waitForDisappearance(fullscreenBar, "Closing full screen must return to the lesson")

        // The central course node has separate complete English/Chinese content
        // in its detail sheet; check that content rather than only sheet launch.
        waitForHittable(course, "The course node must remain accessible after full screen closes")
        course.tap()
        let nodeBar = app.navigationBars["课程"]
        XCTAssertTrue(nodeBar.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts[fixtureTitle + "\n\nWater cycle"].waitForExistence(timeout: 10),
                      "The node detail must show the complete course title and English concept")
        XCTAssertTrue(app.staticTexts["水循环"].waitForExistence(timeout: 10),
                      "The node detail must show its Chinese concept")
        keepScreenshot(app, named: "Complete bilingual course node")
        let closeNode = nodeBar.buttons["完成"]
        waitForHittable(closeNode, "Node detail must have a working close control")
        closeNode.tap()
        waitForDisappearance(nodeBar, "Closing the node detail must return to the lesson")

        let language = app.segmentedControls["lectureflow.language"]
        XCTAssertTrue(language.waitForExistence(timeout: 10))
        let english = language.buttons["英文课"]
        let chinese = language.buttons["中文课"]
        // Reset a previously run fixture so this always exercises a real change.
        waitForHittable(english, "The course language can change without preparing a model")
        if !english.isSelected {
            english.tap()
            waitForSelection(english)
        }
        waitForHittable(chinese, "Chinese must be available for the existing fixture course")
        chinese.tap()
        waitForSelection(chinese)
        XCTAssertTrue(app.staticTexts["中文实时转写"].waitForExistence(timeout: 10),
                      "The transcript heading must reflect the saved Chinese selection")

        app.terminate()
        app.launch()
        let restoredCourse = app.buttons["lectureflow.map.course"]
        waitForHittable(restoredCourse, "The existing fixture map must survive an app relaunch")
        XCTAssertEqual(restoredCourse.label, originalCourseLabel, "Relaunch must restore the same fixture course")
        let restoredChinese = app.segmentedControls["lectureflow.language"].buttons["中文课"]
        XCTAssertTrue(restoredChinese.waitForExistence(timeout: 10))
        waitForSelection(restoredChinese)
        XCTAssertTrue(app.staticTexts["中文实时转写"].waitForExistence(timeout: 10),
                      "Chinese must persist independently of a loaded speech model")
        keepScreenshot(app, named: "Chinese fixture course after relaunch")
    }

    @MainActor
    private func percentage(from element: XCUIElement) throws -> Int {
        try XCTUnwrap(Int(element.label.filter { $0.isNumber }), "Zoom must expose a numeric percentage")
    }

    @MainActor
    private func waitForHittable(_ element: XCUIElement, _ message: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 15), message, file: file, line: line)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, message, file: file, line: line)
    }

    @MainActor
    private func waitForLabel(_ element: XCUIElement, equalTo label: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 10), .completed,
                       "Expected zoom label \(label), found \(element.label)", file: file, line: line)
    }

    @MainActor
    private func waitForDisappearance(_ element: XCUIElement, _ message: String,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 10), .completed, message, file: file, line: line)
    }

    @MainActor
    private func waitForSelection(_ element: XCUIElement,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 10), .completed,
                       "The course language must reflect the persisted selection", file: file, line: line)
    }

    @MainActor
    private func keepScreenshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
