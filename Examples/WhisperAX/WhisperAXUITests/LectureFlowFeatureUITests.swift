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
        selectLesson(app, titled: fixtureTitle)
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
        let closeFullscreen = fullscreenBar.buttons["完成"]
        waitForHittable(closeFullscreen, "Full screen must have a working close control")
        waitForLabel(app.staticTexts["lectureflow.map.fullscreen.zoom"], equalTo: "120%")
        keepScreenshot(app, named: "Full-screen course mind map")
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
    func testRichEconomicsAndStatisticsVisualsAndRealExports() throws {
        let app = XCUIApplication(bundleIdentifier: "com.yufeizheng.lectureflow")
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
        defer { app.terminate() }
        let regressionTitle = "自动化测试 · 计量与统计图文（预设数据）"
        let outputTitle = "自动化测试 · 经济趋势图文（预设数据）"

        openVisualGallery(app, course: regressionTitle)
        let visualZoom = app.staticTexts["lectureflow.visual.zoom"]
        XCTAssertTrue(visualZoom.waitForExistence(timeout: 10))
        waitForLabel(visualZoom, equalTo: "100%")
        let enlargeVisual = app.buttons["放大图表"]
        waitForHittable(enlargeVisual, "The visual gallery must offer working zoom controls")
        enlargeVisual.tap()
        waitForLabel(visualZoom, equalTo: "125%")
        let shrinkVisual = app.buttons["缩小图表"]
        waitForHittable(shrinkVisual, "Zoomed visuals must be able to return to their original size")
        shrinkVisual.tap()
        waitForLabel(visualZoom, equalTo: "100%")
        enlargeVisual.tap()
        waitForLabel(visualZoom, equalTo: "125%")
        let fitVisual = app.buttons["适合屏幕"]
        waitForHittable(fitVisual, "Fit-to-screen must reset a changed visual zoom")
        fitVisual.tap()
        waitForLabel(visualZoom, equalTo: "100%")
        print("VISUAL_UI_CHECK PASS gallery-zoom-enlarge-shrink-fit")
        let regressionViews: [(String, String, String, String)] = [
            ("econ-table", "样本数据表", "Hours (h)", "得分（分）"),
            ("econ-flow", "估计步骤", "Minimize squared residuals", "最小化残差平方和"),
            ("econ-causal", "混杂路径", "Hypothesis", "假设"),
            ("econ-scatter", "样本散点", "Score (points)", "课堂给定样本"),
            ("econ-formula", "斜率公式", "β̂₁", "1.5 分/小时")
        ]
        for (id, title, english, chinese) in regressionViews {
            selectVisual(app, id: id, title: title)
            verifyVisualDetails(app, english: english, chinese: chinese)
            keepScreenshot(app, named: "Economics visual \(id)")
            print("VISUAL_UI_CHECK PASS rendered+details \(id)")
        }
        selectVisual(app, id: "econ-long-table", title: "计量统计概念长表")
        keepScreenshot(app, named: "Twelve-row six-column economics comparison table")
        verifyLongTableEnds(app)
        print("VISUAL_UI_CHECK PASS rendered+details econ-long-table")

        // A real process restart must retrieve the same stored structured data.
        app.terminate()
        app.launch()
        openVisualGallery(app, course: regressionTitle)
        selectVisual(app, id: "econ-formula", title: "斜率公式")
        verifyVisualDetails(app, english: "= 3 / 2 = 1.5", chinese: "相关关系本身不能证明因果")
        keepScreenshot(app, named: "Regression visuals after app relaunch")
        print("VISUAL_UI_CHECK PASS rich-data-relaunch")

        selectVisual(app, id: "econ-table", title: "样本数据表")
        requestRealVisualExport(app, format: "png", screenshotName: "Table PNG export share sheet")
        app.terminate(); app.launch()
        openVisualGallery(app, course: regressionTitle)
        selectVisual(app, id: "econ-scatter", title: "样本散点")
        requestRealVisualExport(app, format: "png", screenshotName: "Scatter PNG export share sheet")
        app.terminate(); app.launch()
        openVisualGallery(app, course: regressionTitle)
        selectVisual(app, id: "econ-long-table", title: "计量统计概念长表")
        requestRealVisualExport(app, format: "png", screenshotName: "Long comparison table PNG export share sheet")
        app.terminate(); app.launch()
        openVisualGallery(app, course: regressionTitle)
        requestRealVisualExport(app, format: "pdf", screenshotName: "Full econometrics PDF export share sheet")

        app.terminate(); app.launch()
        openVisualGallery(app, course: outputTitle)
        for (id, title) in [("econ-bar", "年度产出柱图"), ("econ-line", "产出趋势折线")] {
            selectVisual(app, id: id, title: title)
            verifyVisualDetails(app, english: "Output (100 million yuan)", chinese: "产出（亿元）")
            keepScreenshot(app, named: "Economics visual \(id)")
            print("VISUAL_UI_CHECK PASS rendered+details \(id)")
        }
        selectVisual(app, id: "econ-bar", title: "年度产出柱图")
        requestRealVisualExport(app, format: "png", screenshotName: "Bar PNG export share sheet")
        app.terminate(); app.launch()
        openVisualGallery(app, course: outputTitle)
        requestRealVisualExport(app, format: "pdf", screenshotName: "Full economic-trend PDF export share sheet")
    }

    @MainActor
    private func selectLesson(_ app: XCUIApplication, titled title: String) {
        let course = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "lectureflow.lesson.", title)).firstMatch
        waitForHittable(course, "The explicitly named fixture course must be available in the sidebar")
        course.tap()
        let heading = app.navigationBars[title]
        XCTAssertTrue(heading.waitForExistence(timeout: 10), "Selecting a fixture must actually show that course")
    }

    @MainActor
    private func openVisualGallery(_ app: XCUIApplication, course: String) {
        selectLesson(app, titled: course)
        let gallery = app.buttons["lectureflow.visual.gallery"]
        waitForHittable(gallery, "The course notes must expose the structured-visual gallery")
        gallery.tap()
        XCTAssertTrue(app.navigationBars["课堂图文笔记"].waitForExistence(timeout: 10), "The full visual gallery must open")
        XCTAssertTrue(app.buttons["lectureflow.visual.export.png"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["lectureflow.visual.export.pdf"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func selectVisual(_ app: XCUIApplication, id: String, title: String) {
        let picker = app.buttons["lectureflow.visual.picker"]
        waitForHittable(picker, "The gallery must let the user switch between structured visual types")
        picker.tap()
        let choice = app.buttons[title].firstMatch
        waitForHittable(choice, "The \(title) visual must be present in the picker")
        choice.tap()
        let visual = app.descendants(matching: .any)["lectureflow.visual.image.\(id)"]
        XCTAssertTrue(visual.waitForExistence(timeout: 10), "Selecting a visual must present its rendered image, not only a title")
        XCTAssertTrue(visual.label.contains(title), "The rendered visual must expose its matching bilingual title")
    }

    @MainActor
    private func verifyVisualDetails(_ app: XCUIApplication, english: String, chinese: String) {
        let details = app.buttons["lectureflow.visual.details"]
        waitForHittable(details, "The rendered diagram must have complete readable bilingual data")
        details.tap()
        let bar = app.navigationBars["完整图文数据"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10))
        let englishText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", english)).firstMatch
        let chineseText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", chinese)).firstMatch
        XCTAssertTrue(englishText.waitForExistence(timeout: 10), "Complete data must retain the expected English value, axis, or relationship")
        XCTAssertTrue(chineseText.waitForExistence(timeout: 10), "Complete data must retain the expected Chinese value, axis, or relationship")
        let close = bar.buttons["完成"]
        waitForHittable(close, "The full data view must close back to the visual gallery")
        close.tap()
        waitForDisappearance(bar, "Closing complete data must return to the same rendered visual")
    }

    @MainActor
    private func verifyLongTableEnds(_ app: XCUIApplication) {
        let details = app.buttons["lectureflow.visual.details"]
        waitForHittable(details, "The maximum-size comparison table must expose its full data")
        details.tap()
        let bar = app.navigationBars["完整图文数据"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10))
        let first = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "STRESS_ROW_01_BEGIN")).firstMatch
        waitForHittable(first, "The first row of the comparison table must be readable")
        keepScreenshot(app, named: "Long table full data first row")
        let last = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "R12C6")).firstMatch
        let scroll = app.scrollViews["lectureflow.visual.data.scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        for _ in 0..<20 {
            if last.exists && last.isHittable { break }
            scroll.swipeUp(velocity: .fast)
        }
        waitForHittable(last, "Scrolling the complete table must reach the final cell of row twelve")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "第12行结束")).firstMatch.exists,
                      "The final table cell must preserve its Chinese content as well as the English marker")
        keepScreenshot(app, named: "Long table full data final row")
        let close = bar.buttons["完成"]
        waitForHittable(close, "The long table detail must close back to the gallery")
        close.tap()
        waitForDisappearance(bar, "The long table must remain usable after scrolling to its end")
    }

    @MainActor
    private func requestRealVisualExport(_ app: XCUIApplication, format: String, screenshotName: String) {
        let export = app.buttons["lectureflow.visual.export.\(format)"]
        waitForHittable(export, "The \(format.uppercased()) export must be available")
        export.tap()
        let share = app.descendants(matching: .any)["lectureflow.share.sheet"]
        XCTAssertTrue(share.waitForExistence(timeout: 20), "The actual \(format.uppercased()) exporter must prepare a file and present the system sharing sheet")
        keepScreenshot(app, named: screenshotName)
        // CI separately inspects the generated files with ImageIO/PDFKit, checking
        // dimensions/pages and extracting previews. Opening a sheet alone is not
        // reported as proof that the bytes or page content are correct.
        print("VISUAL_UI_CHECK PASS requested-real-\(format)-export; file decoding checked by CI")
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
        // Capture the physical screen: the app-window snapshot can retain its
        // portrait bounds after the iPad rotates and crop the landscape layout.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
