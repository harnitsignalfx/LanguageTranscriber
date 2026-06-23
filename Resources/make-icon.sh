#!/usr/bin/env bash
# Generate Resources/AppIcon.icns from scratch using Swift + sips + iconutil.
# Re-run only when you want to change the icon design.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT_DIR/Resources/AppIcon.icns"
WORK="$(mktemp -d)"
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"

# 1. Render the 1024x1024 master PNG with an inline Swift program.
cat > "$WORK/gen.swift" <<'SWIFTEOF'
import AppKit

let s = 1024

// Draw directly into a bitmap rep so we never go through NSImage.tiffRepresentation,
// which can fail intermittently in headless swift-cli contexts.
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: s, pixelsHigh: s,
    bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: s * 4, bitsPerPixel: 32
) else {
    FileHandle.standardError.write("bitmap rep failed\n".data(using: .utf8)!)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
    FileHandle.standardError.write("ctx failed\n".data(using: .utf8)!)
    exit(1)
}
NSGraphicsContext.current = ctx

let sf = CGFloat(s)
let rect = CGRect(x: 0, y: 0, width: sf, height: sf)
let cornerRadius: CGFloat = 224
NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).addClip()

// Diagonal gradient: indigo → bright blue
let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.43, green: 0.18, blue: 0.85, alpha: 1.0),
    NSColor(srgbRed: 0.10, green: 0.44, blue: 0.96, alpha: 1.0)
])!
gradient.draw(in: rect, angle: 120)

// Highlight stripe for depth
let highlight = NSGradient(colors: [
    NSColor(white: 1.0, alpha: 0.18),
    NSColor(white: 1.0, alpha: 0.0)
])!
highlight.draw(in: rect, angle: 90)

// Speech-bubble helper
func drawBubble(center: CGPoint, size bubbleSize: CGSize,
                tailOnLeft: Bool, fill: NSColor) {
    let body = CGRect(x: center.x - bubbleSize.width / 2,
                      y: center.y - bubbleSize.height / 2,
                      width: bubbleSize.width,
                      height: bubbleSize.height)
    let p = NSBezierPath(roundedRect: body, xRadius: 90, yRadius: 90)

    let tail = NSBezierPath()
    if tailOnLeft {
        tail.move(to: NSPoint(x: body.minX + 90, y: body.minY + 10))
        tail.line(to: NSPoint(x: body.minX - 30, y: body.minY - 60))
        tail.line(to: NSPoint(x: body.minX + 200, y: body.minY + 30))
    } else {
        tail.move(to: NSPoint(x: body.maxX - 90, y: body.minY + 10))
        tail.line(to: NSPoint(x: body.maxX + 30, y: body.minY - 60))
        tail.line(to: NSPoint(x: body.maxX - 200, y: body.minY + 30))
    }
    p.append(tail)
    p.windingRule = .nonZero
    fill.setFill()
    p.fill()
}

// Bottom (translucent) bubble — the "other language"
drawBubble(center: CGPoint(x: 560, y: 360),
           size: CGSize(width: 620, height: 280),
           tailOnLeft: false,
           fill: NSColor(white: 1.0, alpha: 0.30))

// Top (solid white) bubble — English
drawBubble(center: CGPoint(x: 460, y: 680),
           size: CGSize(width: 620, height: 280),
           tailOnLeft: true,
           fill: NSColor.white)

// Glyphs
let topAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 180, weight: .heavy),
    .foregroundColor: NSColor(srgbRed: 0.18, green: 0.20, blue: 0.48, alpha: 1.0)
]
let topStr = NSAttributedString(string: "A", attributes: topAttrs)
let topSize = topStr.size()
topStr.draw(at: NSPoint(x: 460 - topSize.width / 2,
                        y: 680 - topSize.height / 2))

let botAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 180, weight: .heavy),
    .foregroundColor: NSColor.white
]
let botStr = NSAttributedString(string: "文", attributes: botAttrs)
let botSize = botStr.size()
botStr.draw(at: NSPoint(x: 560 - botSize.width / 2,
                        y: 360 - botSize.height / 2))

ctx.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("PNG export failed\n".data(using: .utf8)!)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("Master PNG written: \(CommandLine.arguments[1])")
SWIFTEOF

swift "$WORK/gen.swift" "$WORK/icon_1024.png"

# 2. Generate all required iconset sizes via sips.
declare -a SPEC=(
    "16:icon_16x16.png"
    "32:icon_16x16@2x.png"
    "32:icon_32x32.png"
    "64:icon_32x32@2x.png"
    "128:icon_128x128.png"
    "256:icon_128x128@2x.png"
    "256:icon_256x256.png"
    "512:icon_256x256@2x.png"
    "512:icon_512x512.png"
    "1024:icon_512x512@2x.png"
)
for entry in "${SPEC[@]}"; do
    size="${entry%%:*}"
    name="${entry##*:}"
    sips -z "$size" "$size" "$WORK/icon_1024.png" --out "$ICONSET/$name" >/dev/null
done

# 3. Pack into .icns.
iconutil --convert icns "$ICONSET" --output "$OUT"
rm -rf "$WORK"
echo "Wrote $OUT"
