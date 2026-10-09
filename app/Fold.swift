// Origami's sheet: a page of notebook paper folding into the start of a paper
// airplane, the dart the rest of the family flies. The fold is real geometry:
// four flat pieces (two halves, two corner flaps) turned about their creases,
// so every frame is the same sheet. The startup animation and the icon both
// draw from here, and the animation's last frame is the icon.
//
// Everything is drawn into a CGContext whose y axis points down (SwiftUI's
// Canvas gives one; make-icon flips its bitmap to match).

import CoreGraphics
import Foundation

enum Fold {
    // A US letter page, in inches, ruled the way loose-leaf paper is.
    static let W: Double = 8.5
    static let H: Double = 11
    static let ruleTop: Double = 1.6        // first rule, down from the top
    static let ruleGap: Double = 0.34
    static let margin: Double = 1.25        // the red line, in from the left
    static let holes: [Double] = [1.7, 5.5, 9.3]   // up from the bottom
    static let holeX: Double = 0.42
    static let holeR: Double = 0.15

    struct V3 { var x, y, z: Double }
    typealias P2 = (u: Double, v: Double)

    static func add(_ a: V3, _ b: V3) -> V3 { V3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
    static func sub(_ a: V3, _ b: V3) -> V3 { V3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
    static func mul(_ a: V3, _ s: Double) -> V3 { V3(x: a.x * s, y: a.y * s, z: a.z * s) }
    static func dot(_ a: V3, _ b: V3) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
    static func cross(_ a: V3, _ b: V3) -> V3 { V3(x: a.y * b.z - a.z * b.y, y: a.z * b.x - a.x * b.z, z: a.x * b.y - a.y * b.x) }
    static func unit(_ a: V3) -> V3 { mul(a, 1 / max(1e-9, sqrt(dot(a, a)))) }

    /// Rodrigues: p turned by th about the axis through o along unit k.
    static func turn(_ p: V3, _ o: V3, _ k: V3, _ th: Double) -> V3 {
        let v = sub(p, o), c = cos(th), s = sin(th)
        let r = add(add(mul(v, c), mul(cross(k, v), s)), mul(k, dot(k, v) * (1 - c)))
        return add(o, r)
    }

    /// The page on the table: x across, y up the page, z out of the table, centred.
    static func flat(_ p: P2) -> V3 { V3(x: p.u - W / 2, y: p.v - H / 2, z: 0) }

    // The pieces, in page coordinates. The corner creases run from the top
    // centre to the sides, W/2 down: the dart's first two folds.
    static let L: P2 = (0, H - W / 2), R: P2 = (W, H - W / 2), N: P2 = (W / 2, H)
    enum Side { case left, right }
    struct Piece { let poly: [P2]; let side: Side; let flap: Bool }
    static let pieces: [Piece] = [
        Piece(poly: [(0, 0), (W / 2, 0), N, L], side: .left, flap: false),
        Piece(poly: [(W / 2, 0), (W, 0), R, N], side: .right, flap: false),
        Piece(poly: [L, N, (0, H)], side: .left, flap: true),
        Piece(poly: [N, R, (W, H)], side: .right, flap: true),
    ]

    /// Where a point of a piece is when the corners are folded by `corner`
    /// (0 flat, 1 folded down onto the page) and the halves turned up by
    /// `keel` radians about the centre line.
    static func place(_ p: P2, _ piece: Piece, corner: Double, keel: Double) -> V3 {
        var q = flat(p)
        if piece.flap {
            let a = flat(piece.side == .left ? L : R), b = flat(N)
            let k = unit(sub(b, a))
            // Up and over: the sign that lifts the flap off the table.
            let sign: Double = piece.side == .left ? 1 : -1
            q = turn(q, a, k, sign * Double.pi * corner)
            // A hair above the page once it lies on it, so it draws on top.
            q.z += 0.02 * smooth(corner)
        }
        if keel != 0 {
            let s: Double = piece.side == .left ? 1 : -1
            q = turn(q, V3(x: 0, y: 0, z: 0), V3(x: 0, y: 1, z: 0), s * keel)
        }
        return q
    }

    // MARK: the startup

    /// Where the fold stands t seconds into the startup. The last moment is the icon.
    struct Moment { var corner, cornerRight, keel, lift, opacity: Double }
    static let restKeel = 0.22, restLift = 0.5
    static let wordsAt = 2.35, end = 3.3
    static func span(_ t: Double, _ a: Double, _ b: Double) -> Double { smooth((t - a) / (b - a)) }
    static func moment(_ t: Double) -> Moment {
        // The page drifts down onto the table like a dropped sheet,
        let drop = 1 - span(t, 0.0, 0.6)
        // the left corner folds in, then the right,
        let left = span(t, 0.6, 1.3), right = span(t, 1.05, 1.75)
        // and the centre crease sets as the page gives a small hop.
        let keel = restKeel * span(t, 1.75, 2.3)
        let hop = sin(Double.pi * min(1, max(0, (t - 1.85) / 0.5))) * 0.35
        return Moment(corner: left, cornerRight: right, keel: keel, lift: restLift + drop * 2.4 + hop, opacity: span(t, 0, 0.3))
    }

    /// The scene both the startup and the icon draw: the page, turned so its
    /// nose points up and to the right, seen from above the table.
    static let yaw = -60.0
    static func camera(width: Double, height: Double, dist: Double = 40) -> Camera {
        Camera(width: width, height: height, target: V3(x: 0, y: 0, z: 0.3), az: -20, el: 60, dist: dist, fov: 30)
    }

    static func smooth(_ t: Double) -> Double { let x = min(1, max(0, t)); return x * x * (3 - 2 * x) }

    // MARK: the camera

    struct Camera {
        var eye: V3, f: V3, s: V3, u: V3, focal: Double, cx: Double, cy: Double
        init(width: Double, height: Double, target: V3, az: Double, el: Double, dist: Double, fov: Double) {
            let a = az * .pi / 180, e = el * .pi / 180
            let off = V3(x: dist * cos(e) * sin(a), y: -dist * cos(e) * cos(a), z: dist * sin(e))
            eye = add(target, off)
            f = unit(mul(off, -1))
            s = unit(cross(f, V3(x: 0, y: 0, z: 1)))
            u = cross(s, f)
            focal = (min(width, height) / 2) / tan(fov * .pi / 360)
            cx = width / 2; cy = height / 2
        }
        func p(_ q: V3) -> CGPoint {
            let d = sub(q, eye)
            let z = max(0.01, dot(d, f))
            return CGPoint(x: cx + focal * dot(d, s) / z, y: cy - focal * dot(d, u) / z)
        }
        func depth(_ q: V3) -> Double { dot(sub(q, eye), f) }
    }

    // MARK: drawing

    struct Ink {
        var paper = (r: 1.0, g: 0.995, b: 0.975)
        var back = (r: 0.965, g: 0.96, b: 0.945)
        var rule = (r: 0.55, g: 0.70, b: 0.88)
        var marginLine = (r: 0.88, g: 0.36, b: 0.36)
        var outline = (r: 0.10, g: 0.09, b: 0.12)
        var hole = (r: 0.42, g: 0.24, b: 0.30)
        var shadow = (r: 0.16, g: 0.05, b: 0.10)
    }

    /// The family's sky behind the page: coral at the top to plum at the bottom.
    static let skyTop = (r: 0.86, g: 0.45, b: 0.35), skyBottom = (r: 0.40, g: 0.15, b: 0.27)
    static func sky(_ ctx: CGContext, top: CGFloat, bottom: CGFloat) {
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(skyTop), color(skyBottom)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    static let light = unit(V3(x: -0.35, y: -0.45, z: 0.82))

    /// Clip the line u=c (vertical) or v=c (horizontal) to a convex polygon.
    static func clip(_ poly: [P2], vertical: Bool, at c: Double) -> (P2, P2)? {
        var hits: [P2] = []
        for i in 0..<poly.count {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            let av = vertical ? a.u : a.v, bv = vertical ? b.u : b.v
            if (av - c) * (bv - c) > 0 || av == bv { continue }
            let t = (c - av) / (bv - av)
            hits.append((a.u + (b.u - a.u) * t, a.v + (b.v - a.v) * t))
        }
        guard hits.count >= 2 else { return nil }
        let sorted = hits.sorted { vertical ? $0.v < $1.v : $0.u < $1.u }
        let p = sorted.first!, q = sorted.last!
        if abs(p.u - q.u) + abs(p.v - q.v) < 1e-6 { return nil }
        return (p, q)
    }

    static func inside(_ poly: [P2], _ p: P2) -> Bool {
        var sign = 0.0
        for i in 0..<poly.count {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            let c = (b.u - a.u) * (p.v - a.v) - (b.v - a.v) * (p.u - a.u)
            if c != 0 { if sign == 0 { sign = c } else if sign * c < 0 { return false } }
        }
        return true
    }

    static func color(_ c: (r: Double, g: Double, b: Double), _ k: Double = 1, alpha: Double = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(min(1, c.r * k)), green: CGFloat(min(1, c.g * k)), blue: CGFloat(min(1, c.b * k)), alpha: CGFloat(alpha))
    }

    /// Draw the sheet. `lift` raises it off the table (its shadow stays down);
    /// `yaw` (degrees) turns it on the table, so the nose can point the way
    /// the family's darts fly.
    static func draw(_ ctx: CGContext, cam: Camera, corner: Double, cornerRight: Double? = nil, keel: Double, lift: Double = 0, yaw: Double = 0, scale: Double = 1, ink: Ink = Ink()) {
        // The left corner folds by `corner`, the right by `cornerRight` (the same, if not given).
        let cr = cornerRight ?? corner
        func amount(_ pc: Piece) -> Double { pc.side == .left ? corner : cr }
        let up = V3(x: 0, y: 0, z: lift)
        let cy = cos(yaw * .pi / 180), sy = sin(yaw * .pi / 180)
        func world(_ p: P2, _ pc: Piece) -> V3 {
            let q = place(p, pc, corner: amount(pc), keel: keel)
            return add(V3(x: q.x * cy - q.y * sy, y: q.x * sy + q.y * cy, z: q.z), up)
        }

        // The shadow, straight down onto the table, softer the higher the page.
        ctx.saveGState()
        let blur = 6 * scale + lift * 10 * scale
        ctx.setShadow(offset: .zero, blur: CGFloat(blur), color: color(ink.shadow, alpha: 0.55))
        for pc in pieces {
            let pts = pc.poly.map { p -> CGPoint in var q = world(p, pc); q.z = 0; return cam.p(q) }
            ctx.beginPath(); ctx.addLines(between: pts); ctx.closePath()
            ctx.setFillColor(color(ink.shadow, alpha: max(0.12, 0.32 - lift * 0.1)))
            ctx.fillPath()
        }
        ctx.restoreGState()

        // The far half first; in each half the page, then its flap, which
        // always lies on the page's upper side.
        func depth(_ side: Side) -> Double {
            let ps = pieces.filter { $0.side == side }
            let all = ps.flatMap { pc in pc.poly.map { cam.depth(world($0, pc)) } }
            return all.reduce(0, +) / Double(all.count)
        }
        let sides: [Side] = depth(.left) > depth(.right) ? [.left, .right] : [.right, .left]
        let order = sides.flatMap { side in pieces.filter { $0.side == side && !$0.flap } + pieces.filter { $0.side == side && $0.flap } }
        let lineW = CGFloat(max(1, 1.6 * scale))
        for pc in order {
            let w = pc.poly.map { world($0, pc) }
            let pts = w.map(cam.p)
            var n = unit(cross(sub(w[1], w[0]), sub(w[2], w[0])))
            let towards = dot(n, sub(cam.eye, w[0])) > 0
            if !towards { n = mul(n, -1) }
            // Which side of the paper faces the camera: the front is the side
            // facing up on the table, and a flap folded over shows its back.
            let pageUp = V3(x: 0, y: 0, z: 1)
            let facingFront: Bool = {
                let fn = unit(cross(sub(world(pc.poly[1], pc), world(pc.poly[0], pc)), sub(world(pc.poly[2], pc), world(pc.poly[0], pc))))
                let flatN = unit(cross(sub(flat(pc.poly[1]), flat(pc.poly[0])), sub(flat(pc.poly[2]), flat(pc.poly[0]))))
                let flatUp = dot(flatN, pageUp) > 0
                return (dot(fn, sub(cam.eye, w[0])) > 0) == flatUp
            }()
            let shade = 0.80 + 0.22 * max(0, dot(n, light))
            ctx.beginPath(); ctx.addLines(between: pts); ctx.closePath()
            ctx.setFillColor(color(facingFront ? ink.paper : ink.back, shade))
            ctx.fillPath()

            // The rules, the margin, the holes: clipped to the piece in page
            // coordinates, then carried by the piece's own placement.
            ctx.saveGState()
            ctx.beginPath(); ctx.addLines(between: pts); ctx.closePath(); ctx.clip()
            ctx.setLineCap(.butt)
            ctx.setLineWidth(CGFloat(max(0.6, 1.1 * scale)))
            ctx.setStrokeColor(color(ink.rule, facingFront ? 1 : 1.05, alpha: facingFront ? 1 : 0.8))
            // Too small to see one by one (the smallest icons), the rules
            // would only tint the page blue.
            var v = scale >= 0.15 ? H - ruleTop : 0
            while v > 0.3 {
                if let (a, b) = clip(pc.poly, vertical: false, at: v) {
                    ctx.move(to: cam.p(world(a, pc))); ctx.addLine(to: cam.p(world(b, pc)))
                }
                v -= ruleGap
            }
            ctx.strokePath()
            if facingFront, let (a, b) = clip(pc.poly, vertical: true, at: margin) {
                ctx.setStrokeColor(color(ink.marginLine))
                ctx.setLineWidth(CGFloat(max(0.8, 1.4 * scale)))
                ctx.move(to: cam.p(world(a, pc))); ctx.addLine(to: cam.p(world(b, pc)))
                ctx.strokePath()
            }
            for hv in holes where scale >= 0.15 && inside(pc.poly, (holeX, hv)) {
                let ring = (0..<20).map { i -> CGPoint in
                    let t = Double(i) / 20 * 2 * .pi
                    return cam.p(world((holeX + holeR * cos(t), hv + holeR * sin(t)), pc))
                }
                ctx.beginPath(); ctx.addLines(between: ring); ctx.closePath()
                ctx.setFillColor(color(ink.hole, alpha: 0.85))
                ctx.fillPath()
            }
            ctx.restoreGState()

            // The outline: the page's edges always; a crease only as it folds.
            ctx.setLineWidth(lineW)
            ctx.setLineCap(.round)
            for i in 0..<pc.poly.count {
                let a = pc.poly[i], b = pc.poly[(i + 1) % pc.poly.count]
                let onKeel = abs(a.u - W / 2) < 1e-9 && abs(b.u - W / 2) < 1e-9
                let isCorner = [L, R, N].contains { abs($0.u - a.u) + abs($0.v - a.v) < 1e-9 } && [L, R, N].contains { abs($0.u - b.u) + abs($0.v - b.v) < 1e-9 }
                let alpha = onKeel ? smooth(keel * 4) * 0.9 : isCorner ? smooth(amount(pc) * 2.5) : 1
                if alpha <= 0.01 { continue }
                ctx.setStrokeColor(color(ink.outline, alpha: alpha))
                ctx.move(to: pts[i]); ctx.addLine(to: pts[(i + 1) % pts.count])
                ctx.strokePath()
            }
        }
    }
}
