#!/usr/bin/env bash
# Regenerate AppIcon.icns from the 🎉 emoji. Run before build.sh.
set -euo pipefail

cd "$(dirname "$0")"
emoji="🎉"
name="AppIcon"
out_dir="Resources"
mkdir -p "$out_dir"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

iconset="$work/${name}.iconset"
mkdir -p "$iconset"

for size in 16 32 64 128 256 512 1024; do
  /usr/bin/swift - "$emoji" "$size" "$iconset/icon_${size}x${size}.png" <<'SWIFT'
import AppKit
let args = CommandLine.arguments
let emoji = args[1]
let size = Int(args[2])!
let out = args[3]
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let attrs: [NSAttributedString.Key: Any] = [
  .font: NSFont(name: "Apple Color Emoji", size: CGFloat(size) * 0.85)!
]
let str = NSAttributedString(string: emoji, attributes: attrs)
let strSize = str.size()
let origin = NSPoint(
  x: (CGFloat(size) - strSize.width) / 2,
  y: (CGFloat(size) - strSize.height) / 2
)
str.draw(at: origin)
image.unlockFocus()
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
  exit(1)
}
try png.write(to: URL(fileURLWithPath: out))
SWIFT
done

# Apple's iconutil expects @2x variants.
for size in 16 32 128 256 512; do
  double=$((size * 2))
  cp "$iconset/icon_${double}x${double}.png" "$iconset/icon_${size}x${size}@2x.png"
done

/usr/bin/iconutil -c icns -o "$out_dir/${name}.icns" "$iconset"
echo "wrote $out_dir/${name}.icns"
