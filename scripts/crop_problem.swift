// Crop normalized figure regions from a screencapture and compose one PNG.
// Usage: swift crop_problem.swift screenshot.png analysis.json output.png
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    fputs("crop_problem: \(message)\n", stderr)
    exit(1)
}

guard CommandLine.arguments.count == 4 else {
    fail("expected screenshot, analysis JSON, and output paths")
}

let screenshot = URL(fileURLWithPath: CommandLine.arguments[1])
let analysis = URL(fileURLWithPath: CommandLine.arguments[2])
let output = URL(fileURLWithPath: CommandLine.arguments[3])

guard let source = CGImageSourceCreateWithURL(screenshot as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fail("could not read the screenshot")
}

let object: [String: Any]
do {
    let data = try Data(contentsOf: analysis)
    guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        fail("analysis is not a JSON object")
    }
    object = decoded
} catch {
    fail("could not parse analysis: \(error)")
}

guard let regions = object["figure_regions"] as? [[String: Double]],
      !regions.isEmpty, regions.count <= 8 else {
    fail("expected between one and eight figure regions")
}

var crops: [CGImage] = []
for region in regions {
    guard let x = region["x"], let y = region["y"],
          let width = region["width"], let height = region["height"],
          x.isFinite, y.isFinite, width.isFinite, height.isFinite,
          x >= 0, y >= 0, width > 0, height > 0,
          x + width <= 1.001, y + height <= 1.001 else {
        fail("invalid normalized figure coordinates")
    }
    let left = max(0, Int(floor(x * Double(image.width))))
    let top = max(0, Int(floor(y * Double(image.height))))
    let right = min(image.width, Int(ceil((x + width) * Double(image.width))))
    let bottom = min(image.height, Int(ceil((y + height) * Double(image.height))))
    guard right - left >= 16, bottom - top >= 16,
          let crop = image.cropping(to: CGRect(x: left, y: top,
                                               width: right - left,
                                               height: bottom - top)) else {
        fail("figure region is too small or outside the screenshot")
    }
    crops.append(crop)
}

let layout = object["layout"] as? String ?? "vertical"
guard ["horizontal", "vertical", "grid"].contains(layout) else {
    fail("unknown figure layout")
}
let columns = layout == "horizontal" ? crops.count : (layout == "grid" ? 2 : 1)
let rows = (crops.count + columns - 1) / columns
let gap = 20
var widths = Array(repeating: 0, count: columns)
var heights = Array(repeating: 0, count: rows)
for (index, crop) in crops.enumerated() {
    widths[index % columns] = max(widths[index % columns], crop.width)
    heights[index / columns] = max(heights[index / columns], crop.height)
}
let totalWidth = widths.reduce(0, +) + gap * (columns - 1)
let totalHeight = heights.reduce(0, +) + gap * (rows - 1)
guard totalWidth > 0, totalHeight > 0,
      totalWidth <= 20000, totalHeight <= 20000,
      totalWidth * totalHeight <= 100_000_000 else {
    fail("composite figure is too large")
}

guard let canvas = CGContext(data: nil, width: totalWidth, height: totalHeight,
                             bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fail("could not allocate output image")
}
canvas.setFillColor(CGColor(gray: 1, alpha: 1))
canvas.fill(CGRect(x: 0, y: 0, width: totalWidth, height: totalHeight))
for (index, crop) in crops.enumerated() {
    let column = index % columns
    let row = index / columns
    let left = widths.prefix(column).reduce(0, +) + gap * column
    let top = heights.prefix(row).reduce(0, +) + gap * row
    let x = left + (widths[column] - crop.width) / 2
    let y = totalHeight - top - crop.height
    canvas.draw(crop, in: CGRect(x: x, y: y, width: crop.width, height: crop.height))
}
guard let result = canvas.makeImage(),
      let destination = CGImageDestinationCreateWithURL(output as CFURL,
          UTType.png.identifier as CFString, 1, nil) else {
    fail("could not create output PNG")
}
CGImageDestinationAddImage(destination, result, nil)
guard CGImageDestinationFinalize(destination) else {
    fail("could not write output PNG")
}
