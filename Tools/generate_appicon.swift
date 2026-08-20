#!/usr/bin/env swift
//
//  generate_appicon.swift
//  CityTime
//
//  Draws the 1024x1024 app icon and writes it into the asset catalog:
//
//      swift Tools/generate_appicon.swift
//
//  Same reasoning as generate_xcodeproj.py — keeping the icon as code means a
//  colour tweak shows up as a readable diff instead of an opaque binary blob.
//  The PNG is committed too, since the build needs it and CI shouldn't have to
//  run this.
//
//  The artwork is a geofence ring with a map pin at its centre: the two things
//  the app is about, and both still legible at 40 pt. It deliberately fills
//  the whole square with no alpha — iOS applies its own rounded mask, and an
//  icon with transparency is rejected at submission.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let side = 1024.0
let centre = CGPoint(x: side / 2, y: side / 2)

// Brackets the accent colour in Assets.xcassets (#215C8B): lighter at the top
// left, deeper at the bottom right.
let gradientTop = CGColor(srgbRed: 0.231, green: 0.561, blue: 0.831, alpha: 1)
let gradientBottom = CGColor(srgbRed: 0.071, green: 0.235, blue: 0.369, alpha: 1)

guard let context = CGContext(data: nil,
                              width: Int(side),
                              height: Int(side),
                              bitsPerComponent: 8,
                              bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    fatalError("could not create the bitmap context")
}

// MARK: - Background

let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                          colors: [gradientTop, gradientBottom] as CFArray,
                          locations: [0, 1])!
context.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: side),
                           end: CGPoint(x: side, y: 0),
                           options: [])

// MARK: - Geofence ring

let ringRadius = 370.0
let ringWidth = 26.0

// A faint disc so the ring reads as an enclosed area rather than a bare circle.
context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10))
context.addArc(center: centre, radius: ringRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
context.fillPath()

context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92))
context.setLineWidth(ringWidth)
context.addArc(center: centre, radius: ringRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
context.strokePath()

// MARK: - Pin

let headRadius = 120.0
let tipDistance = 290.0
// Placed so the pin's full extent, head top down to tip, is what sits centred
// in the square — centring the head alone leaves it visibly low.
let head = CGPoint(x: centre.x, y: centre.y + (tipDistance - headRadius) / 2)
let tip = CGPoint(x: head.x, y: head.y - tipDistance)

// Where the two straight edges meet the head: the tangent from the tip touches
// the circle at acos(r/d) either side of the line from centre to tip.
let tangent = acos(headRadius / tipDistance)
let towardsTip = -Double.pi / 2

let pin = CGMutablePath()
pin.addArc(center: head,
           radius: headRadius,
           startAngle: towardsTip - tangent,
           endAngle: towardsTip + tangent,
           clockwise: true)
pin.addLine(to: tip)
pin.closeSubpath()

// Second subpath punched out with the even-odd rule, so the hole shows the
// gradient rather than a flat colour approximating it.
pin.addArc(center: head, radius: 46, startAngle: 0, endAngle: .pi * 2, clockwise: false)

context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
context.addPath(pin)
context.fillPath(using: .evenOdd)

// MARK: - Write

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let destination = root.appending(path: "RegionMonitor/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")

guard let image = context.makeImage(),
      let writer = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("could not encode \(destination.path)")
}
CGImageDestinationAddImage(writer, image, nil)
guard CGImageDestinationFinalize(writer) else {
    fatalError("could not write \(destination.path)")
}

print("Wrote \(destination.path) (\(Int(side))x\(Int(side)))")
