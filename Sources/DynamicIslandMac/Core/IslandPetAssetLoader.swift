import AppKit
import Foundation

enum IslandPetAsset: String, CaseIterable, Hashable {
    case byte
    case ember
    case nova
    case moss
    case patch

    var filename: String {
        "\(rawValue).png"
    }
}

enum IslandPetResourceLocator {
    static let resourceDirectory = "Pets"
    private static let loaderSourceFilePath = #filePath

    static func bundledURL(
        for asset: IslandPetAsset,
        resourceURL: URL?
    ) -> URL? {
        resourceURL?
            .appendingPathComponent(resourceDirectory, isDirectory: true)
            .appendingPathComponent(asset.filename, isDirectory: false)
    }

    static func developmentURL(
        for asset: IslandPetAsset,
        sourceFilePath: String? = nil
    ) -> URL {
        let sourceFileURL = URL(
            fileURLWithPath: sourceFilePath ?? loaderSourceFilePath,
            isDirectory: false
        )
        let projectRoot = sourceFileURL
            .deletingLastPathComponent() // IslandPetAssetLoader.swift
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // DynamicIslandMac
            .deletingLastPathComponent() // Sources

        return projectRoot
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(resourceDirectory, isDirectory: true)
            .appendingPathComponent(asset.filename, isDirectory: false)
    }

    static func candidateURLs(
        for asset: IslandPetAsset,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        sourceFilePath: String? = nil
    ) -> [URL] {
        var candidates: [URL] = []
        if let bundled = bundledURL(for: asset, resourceURL: bundleResourceURL) {
            candidates.append(bundled)
        }

        let development = developmentURL(for: asset, sourceFilePath: sourceFilePath)
        if !candidates.contains(development) {
            candidates.append(development)
        }
        return candidates
    }
}

/// Loads each pet bitmap at most once for the lifetime of the process. Missing
/// resources are cached as misses so SwiftUI animation frames never repeat disk
/// access or image decoding.
@MainActor
final class IslandPetAssetLoader {
    static let shared = IslandPetAssetLoader()

    private var decodedImages: [IslandPetAsset: NSImage] = [:]
    private var resolvedAssets: Set<IslandPetAsset> = []

    private init() {}

    func image(for asset: IslandPetAsset) -> NSImage? {
        if resolvedAssets.contains(asset) {
            return decodedImages[asset]
        }

        resolvedAssets.insert(asset)
        for url in IslandPetResourceLocator.candidateURLs(for: asset) {
            guard let image = NSImage(contentsOf: url) else { continue }

            // Force AppKit to decode the bitmap now instead of lazily during a
            // TimelineView frame. NSImage keeps the decoded representation.
            var proposedRect = CGRect(origin: .zero, size: image.size)
            _ = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
            image.isTemplate = false
            decodedImages[asset] = image
            return image
        }

        return nil
    }
}
