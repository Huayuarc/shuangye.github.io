import Foundation

func require(_ condition: Bool, _ message: String, line: Int = #line) {
    guard condition else { fatalError("Line \(line): \(message)") }
}

let albums: [[CGFloat]] = [
    [], [1], [16 / 9], [9 / 16], [1, 1], [2, 2],
    [0.6, 1.7, 1], [1.7, 0.6, 1], [1, 1, 1, 1], [1.7, 1, 0.7, 1.3],
    [0, .nan, .infinity, -1],
] + (5 ... 20).map { count in (0 ..< count).map { [CGFloat(0.6), 1, 1.7][$0 % 3] } }

for width: CGFloat in [1, 60, 320, 540] {
    for ratios in albums {
        let frames = MessageImageLayout.frames(aspectRatios: ratios, width: width)
        require(frames.count == ratios.count, "Every image must appear exactly once")
        for (index, frame) in frames.enumerated() {
            require(frame.width.isFinite && frame.height.isFinite && frame.width > 0 && frame.height > 0, "Tiles must have finite positive sizes")
            require(frame.minX >= 0 && frame.minY >= 0 && frame.maxX <= width + 0.0001, "Tiles must stay inside the album")
            for previous in frames.prefix(index) {
                let overlap = frame.intersection(previous)
                require(overlap.isNull || overlap.width < 0.0001 || overlap.height < 0.0001, "Tiles must not overlap")
            }
        }
    }
}

require(MessageImageLayout.frames(aspectRatios: [1], width: 0).isEmpty, "No layout before a width exists")
let single = MessageImageLayout.frames(aspectRatios: [2], width: 320)[0]
require(single.size == CGSize(width: 320, height: 160), "A single image keeps its aspect ratio")
let portrait = MessageImageLayout.frames(aspectRatios: [0.6, 1.5, 1], width: 320)
require(portrait[0].height > portrait[1].height && portrait[1].minX == portrait[2].minX, "A leading portrait spans the two stacked neighbors")
for ratios in albums where !ratios.isEmpty {
    let natural = MessageImageLayout.frames(aspectRatios: ratios, width: 320)
    let limited = MessageImageLayout.frames(aspectRatios: ratios, width: 320, maximumHeight: 120)
    require(limited.count == ratios.count, "Height limits retain every attachment")
    require(limited.allSatisfy { $0.maxX <= 320.0001 && $0.maxY <= 120.0001 }, "The whole album fits its width and height limits")
    for (original, fitted) in zip(natural, limited) {
        require(abs(original.width / original.height - fitted.width / fitted.height) < 0.0001, "Fitting preserves tile proportions")
    }
}

/// Albums no larger than their images (issue #20).
func fitted(_ naturals: [CGSize?], width: CGFloat = 320, maximumHeight: CGFloat = .greatestFiniteMagnitude) -> [CGRect] {
    let ratios = naturals.map { $0.map { $0.width / $0.height } ?? 1 }
    return MessageImageLayout.frames(aspectRatios: ratios, naturalSizes: naturals, width: width, maximumHeight: maximumHeight)
}

func near(_ size: CGSize, _ expected: CGSize) -> Bool {
    abs(size.width - expected.width) < 0.001 && abs(size.height - expected.height) < 0.001
}

require(near(fitted([CGSize(width: 40, height: 40)])[0].size, CGSize(width: 40, height: 40)), "A small image is drawn at its own size")
require(near(fitted([CGSize(width: 80, height: 40)])[0].size, CGSize(width: 80, height: 40)), "A small image keeps its aspect ratio")
require(near(fitted([CGSize(width: 60, height: 30)])[0].size, CGSize(width: 64, height: 32)), "A short image grows to the minimum, its aspect ratio kept")
require(near(fitted([CGSize(width: 16, height: 16)])[0].size, CGSize(width: 32, height: 32)), "A tiny image is drawn at the minimum size")
require(near(fitted([CGSize(width: 29, height: 29)])[0].size, CGSize(width: 32, height: 32)), "An icon under the minimum is drawn at it")
require(near(fitted([CGSize(width: 10, height: 100)])[0].size, CGSize(width: 32, height: 320)), "A thin image's shorter side reaches the minimum")
require(near(fitted([CGSize(width: 10, height: 100)], maximumHeight: 200)[0].size, CGSize(width: 20, height: 200)), "The limits win over the minimum")
let screenshot = CGSize(width: 1290 / 3, height: 2796 / 3)
require(
    fitted([screenshot], maximumHeight: 280) == MessageImageLayout.frames(aspectRatios: [screenshot.width / screenshot.height], width: 320, maximumHeight: 280),
    "A large image is drawn as large as the limits allow",
)
require(fitted([nil]) == MessageImageLayout.frames(aspectRatios: [1], width: 320), "An image of unknown size keeps the album as it was")
require(
    fitted([CGSize(width: 40, height: 40), nil]) == MessageImageLayout.frames(aspectRatios: [1, 1], width: 320),
    "One image of unknown size keeps the whole album",
)
require(
    fitted([CGSize(width: 2000, height: 1500), CGSize(width: 40, height: 40)]) == MessageImageLayout.frames(aspectRatios: [2000 / 1500, 1], width: 320),
    "A large image keeps its album as large, a small one beside it too",
)
let icons = fitted([CGSize(width: 40, height: 40), CGSize(width: 40, height: 40)])
require(
    icons.allSatisfy { $0.width <= 40.001 && $0.width >= 40 - MessageImageLayout.spacing && abs($0.width - $0.height) < 0.001 },
    "An album of small images is drawn near their own size, its gutter kept",
)
for count in 2 ... 9 {
    for side: CGFloat in [4, 8, 16, 31] {
        let album = fitted(Array(repeating: CGSize(width: side, height: side), count: count))
        require(
            album.allSatisfy { min($0.width, $0.height) >= MessageImageLayout.minimumSide - 0.001 },
            "Every tile of an album of tiny images reaches the minimum, its gutters kept",
        )
    }
}

for naturals: [CGSize?] in [
    [CGSize(width: 12, height: 300)], [CGSize(width: 300, height: 12)], [CGSize(width: 3000, height: 20)],
    [CGSize(width: 8, height: 8), CGSize(width: 900, height: 600), CGSize(width: 20, height: 50)],
    (0 ..< 7).map { CGSize(width: 24 + CGFloat($0) * 30, height: 64) },
] {
    for (width, height): (CGFloat, CGFloat) in [(320, 280), (60, 40), (540, .greatestFiniteMagnitude)] {
        let ratios = naturals.map { $0.map { $0.width / $0.height } ?? 1 }
        let full = MessageImageLayout.frames(aspectRatios: ratios, width: width, maximumHeight: height)
        let small = fitted(naturals, width: width, maximumHeight: height)
        require(small.count == naturals.count, "Fitting keeps every image")
        let fullWidth = full.map(\.maxX).max() ?? 0, fullHeight = full.map(\.maxY).max() ?? 0
        require(
            small.allSatisfy { $0.maxX <= fullWidth + 0.001 && $0.maxY <= fullHeight + 0.001 && $0.width > 0 && $0.height > 0 },
            "A fitted album is never larger than the limits allow",
        )
    }
}

print("ok: image album geometry (empty, single, 2–20 images, invalid ratios, narrow widths, images at their own size)")
