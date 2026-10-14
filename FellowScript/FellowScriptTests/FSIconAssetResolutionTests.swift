// FSIconAssetResolutionTests.swift — testing gate for task
// 20261013-ios-custom-icon-set-v3. Every FSIcon case must resolve to a real
// asset in the catalog, so a renamed/missing image set fails here instead of
// rendering as a silent blank image.

import XCTest
import UIKit
@testable import FellowScript

final class FSIconAssetResolutionTests: XCTestCase {

    func testEveryFSIconCaseResolvesToARealAsset() {
        XCTAssertEqual(FSIcon.allCases.count, 3)
        for icon in FSIcon.allCases {
            let img = UIImage(named: icon.rawValue, in: Bundle(for: AppState.self), compatibleWith: nil)
            XCTAssertNotNil(img, "FSIcon.\(icon) (\(icon.rawValue)) has no matching image set")
        }
    }

    func testAssetsAreAtLeastAsLargeAsDeclaredPointSize() {
        for icon in FSIcon.allCases {
            guard let img = UIImage(named: icon.rawValue, in: Bundle(for: AppState.self), compatibleWith: nil) else {
                XCTFail("missing \(icon.rawValue)"); continue
            }
            XCTAssertGreaterThanOrEqual(img.size.width, icon.pointSize - 0.5, "\(icon.rawValue) smaller than its declared point size")
        }
    }
}

final class FSIconRemovedAssetsTests: XCTestCase {
    func testRescopedOutIconsAreGoneFromCatalog() {
        for name in ["check-in", "check-in-sent", "plus", "ai-agent"] {
            XCTAssertNil(UIImage(named: name, in: Bundle(for: AppState.self), compatibleWith: nil), "\(name) should be removed")
        }
    }
}
