import AppKit
import Foundation
import XCTest
@testable import DynamicIslandMac

final class IslandPetAssetLoaderTests: XCTestCase {
    func testPetAssetFilenameContract() {
        XCTAssertEqual(
            IslandPetAsset.allCases.map(\.filename),
            ["byte.png", "ember.png", "nova.png", "moss.png", "patch.png"]
        )
    }

    func testPackagedResourcePathUsesBundlePetsDirectory() throws {
        let resourceURL = URL(fileURLWithPath: "/Applications/Dynamic Island.app/Contents/Resources", isDirectory: true)
        let url = try XCTUnwrap(
            IslandPetResourceLocator.bundledURL(for: .nova, resourceURL: resourceURL)
        )

        XCTAssertEqual(
            url.path,
            "/Applications/Dynamic Island.app/Contents/Resources/Pets/nova.png"
        )
    }

    func testDevelopmentResourcePathUsesRepositoryResourcesDirectory() {
        let sourcePath = "/workspace/Sources/DynamicIslandMac/Core/IslandPetAssetLoader.swift"
        let url = IslandPetResourceLocator.developmentURL(for: .moss, sourceFilePath: sourcePath)

        XCTAssertEqual(url.path, "/workspace/Resources/Pets/moss.png")
    }

    func testCandidatePathsPreferBundleAndRetainDevelopmentFallback() {
        let resourceURL = URL(fileURLWithPath: "/App/Contents/Resources", isDirectory: true)
        let sourcePath = "/repo/Sources/DynamicIslandMac/Core/IslandPetAssetLoader.swift"
        let candidates = IslandPetResourceLocator.candidateURLs(
            for: .byte,
            bundleResourceURL: resourceURL,
            sourceFilePath: sourcePath
        )

        XCTAssertEqual(
            candidates.map(\.path),
            [
                "/App/Contents/Resources/Pets/byte.png",
                "/repo/Resources/Pets/byte.png"
            ]
        )
    }

    func testCandidatePathsWorkWithoutBundleResources() {
        let sourcePath = "/repo/Sources/DynamicIslandMac/Core/IslandPetAssetLoader.swift"
        let candidates = IslandPetResourceLocator.candidateURLs(
            for: .patch,
            bundleResourceURL: nil,
            sourceFilePath: sourcePath
        )

        XCTAssertEqual(candidates.map(\.path), ["/repo/Resources/Pets/patch.png"])
    }

    func testAllDevelopmentAssetsAreTransparent384PixelPNGs() throws {
        for asset in IslandPetAsset.allCases {
            let url = IslandPetResourceLocator.developmentURL(for: asset)
            let data = try Data(contentsOf: url)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data), asset.rawValue)

            XCTAssertEqual(bitmap.pixelsWide, 384, asset.rawValue)
            XCTAssertEqual(bitmap.pixelsHigh, 384, asset.rawValue)
            XCTAssertTrue(bitmap.hasAlpha, asset.rawValue)

            for point in [(0, 0), (383, 0), (0, 383), (383, 383)] {
                let alpha = try XCTUnwrap(
                    bitmap.colorAt(x: point.0, y: point.1)?.alphaComponent,
                    asset.rawValue
                )
                XCTAssertEqual(alpha, 0, accuracy: 0.001, asset.rawValue)
            }
        }
    }

    func testEveryGroundedSupportFootIsARealOpaqueArtworkPixel() throws {
        for kind in IslandPetKind.allCases {
            let asset = try XCTUnwrap(IslandPetAsset(rawValue: kind.rawValue))
            let url = IslandPetResourceLocator.developmentURL(for: asset)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: url)))
            let sourceX = Int(floor((kind.supportFoot.x + 17) / 34 * 384))
            let sourceY = Int(round((kind.supportFoot.y + 17) / 34 * 384)) - 1
            let alpha = try XCTUnwrap(bitmap.colorAt(x: sourceX, y: sourceY)?.alphaComponent)

            XCTAssertGreaterThanOrEqual(alpha, 16.0 / 255.0, kind.rawValue)
            XCTAssertEqual(kind.supportFoot.y, kind.artworkBounds.maxY, accuracy: 0.001, kind.rawValue)
        }
    }

    func testMossAssetHasNoMagentaChromaSpill() throws {
        let url = IslandPetResourceLocator.developmentURL(for: .moss)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: url)))
        var spillPixelCount = 0

        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0 else { continue }
                let red = color.redComponent
                let green = color.greenComponent
                let blue = color.blueComponent
                if red > 0.27,
                   blue > 0.23,
                   red > green * 1.35,
                   blue > green * 1.25 {
                    spillPixelCount += 1
                }
            }
        }

        XCTAssertEqual(spillPixelCount, 0)
    }
}
