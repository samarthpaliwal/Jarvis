import XCTest
import SwiftUI
@testable import JarvisCore

final class NotchGeometryTests: XCTestCase {
    func testFallbackIsAPill() {
        let g = NotchGeometry.fallback
        XCTAssertFalse(g.hasNotch)
        XCTAssertGreaterThan(g.notchWidth, 0)
        XCTAssertGreaterThan(g.notchHeight, 0)
    }

    @MainActor
    func testDetectOnRealScreensNeverReturnsZeroSize() {
        for screen in NSScreen.screens {
            let g = NotchGeometry.detect(on: screen)
            XCTAssertGreaterThan(g.notchWidth, 0)
            XCTAssertGreaterThan(g.notchHeight, 0)
            if g.hasNotch { XCTAssertEqual(g.notchHeight, screen.safeAreaInsets.top) }
        }
    }

    func testNotchShapeStaysInsideItsRect() {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 80)
        let path = NotchShape(topRadius: 10, bottomRadius: 20).path(in: rect)
        let bounds = path.boundingRect
        XCTAssertEqual(bounds.minX, 0, accuracy: 0.01)
        XCTAssertEqual(bounds.maxX, 300, accuracy: 0.01)
        XCTAssertEqual(bounds.minY, 0, accuracy: 0.01)
        XCTAssertEqual(bounds.maxY, 80, accuracy: 0.01)
    }

    func testNotchShapeWithZeroRadiiIsARectangle() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 32)
        let path = NotchShape(topRadius: 0, bottomRadius: 0).path(in: rect)
        XCTAssertEqual(path.boundingRect, rect)
    }

    @MainActor
    func testViewModelPhaseFlow() async {
        let vm = NotchViewModel()
        XCTAssertEqual(vm.phase, .idle)
        vm.listen()
        vm.pushAudioLevel(0.5)
        XCTAssertEqual(vm.audioLevels.last, 0.5)
        vm.think()
        XCTAssertEqual(vm.phase, .thinking)
        vm.respond("hi", collapseAfter: 0.2)
        XCTAssertEqual(vm.phase, .responding)
        try? await Task.sleep(for: .seconds(0.6))
        XCTAssertEqual(vm.phase, .idle)
    }
}
