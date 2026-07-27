import XCTest
import SwiftUI
@testable import NeutrinoNotes

final class ContentViewTests: XCTestCase {

    func test_contentView_instantiates() {
        let view = ContentView()
        XCTAssertNotNil(view.body)
    }
}
