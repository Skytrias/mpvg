package src

import "core:math"

// Curve1 == Curve count = 0 + 1
// Curve2 == Curve count = 1 + 1
// Curve3 == Curve count = 2 + 1

Curve :: struct {
	B: [4][2]f32,
	count: i32, // 0-2 + 1
	pad1: i32,
	pad2: i32,
	pad3: i32,
}

Curve_Linear :: [2][2]f32
Curve_Quadratic :: [3][2]f32
Curve_Cubic :: [4][2]f32

c1_make :: proc(a, b: [2]f32) -> (res: Curve) {
	c1_init(&res, a, b)
	return
}

c1_init :: proc(curve: ^Curve, a, b: [2]f32) {
	curve.B[0] = a
	curve.B[1] = b
	curve.count = 0
}

c1_eval :: proc(using curve: Curve, t: f32) -> [2]f32 {
	return (1-t)*B[0] + t*B[1]
}

c1_subcurve  :: proc(using curve: Curve, u, v: f32) -> (out: Curve) {
	out.count = curve.count
	out.B[0] = math.lerp(B[0], B[1], u)
	out.B[1] = math.lerp(B[0], B[1], v)
	return
}

c2_make :: proc(a, b, c: [2]f32) -> (res: Curve) {
	c2_init(&res, a, b, c)
	return
}

c2_init :: proc(curve: ^Curve, a, b, c: [2]f32) {
	curve.B[0] = a
	curve.B[1] = b
	curve.B[2] = c
	curve.count = 1
}

c2_blossom :: proc(using curve: Curve, u, v: f32) -> [2]f32 {
	b10 := u*B[1] + (1-u)*B[0]
	b11 := u*B[2] + (1-u)*B[1]
	b20 := v*b11 + (1-v)*b10
	return b20
}

c2_slice :: proc(using curve: Curve, s0, s1: f32) -> (sp: Curve_Quadratic) {
	sp = {
		s0 == 0 ? B[0] : c2_blossom(curve, s0, s0),
		c2_blossom(curve, s0, s1),
		s1 == 1 ? B[2] : c2_blossom(curve, s1, s1),
	}
	return
}

c3_make :: proc(a, b, c, d: [2]f32) -> (res: Curve) {
	c3_init(&res, a, b, c, d)
	return
}

c3_init :: proc(curve: ^Curve, a, b, c, d: [2]f32) {
	curve.B[0] = a
	curve.B[1] = b
	curve.B[2] = c
	curve.B[3] = d
	curve.count = 2
}

c3_blossom :: proc(using curve: Curve, u, v, w: f32) -> [2]f32 {
	b10 := u*B[1] + (1-u)*B[0]
	b11 := u*B[2] + (1-u)*B[1]
	b12 := u*B[3] + (1-u)*B[2]
	b20 := v*b11 + (1-v)*b10
	b21 := v*b12 + (1-v)*b11
	b30 := w*b21 + (1-w)*b20
	return b30
}

c3_slice :: proc(using curve: Curve, u, v: f32, sp: ^Curve_Cubic) {
	sp[0] = u == 0 ? B[0] : c3_blossom(curve, u, u, u)
	sp[1] = c3_blossom(curve, u, u, v)
	sp[2] = c3_blossom(curve, u, v, v)
	sp[3] = v == 0 ? B[3] : c3_blossom(curve, v, v, v)
}
