package src

import "core:fmt"
import "core:math"
import "core:math/linalg"
import glm "core:math/linalg/glsl"

Implicit_Curve_Kind :: enum i32 {
	LINE,
	QUADRATIC,
	CUBIC,
}

Implicit_Curve_Cubic_Type :: enum i32 {
	ERROR,
	SERPENTINE,
	CUSP,
	CUSP_INFINITY,
	LOOP,
	DEGENERATE_QUADRATIC,
	DEGENERATE_LINE,
}

Implicit_Curve_Orientation :: enum i32 {
	BL,
	BR,
	TL,
	TR,
}

Implicit_Curve :: struct {
	box: [4]f32, // bounding box

	hull_vertex: [2]f32,
	hull_padding: [2]f32,
	
	kind: Implicit_Curve_Kind, 
	orientation: Implicit_Curve_Orientation,
	sign: i32,
	winding_increment: i32,

	implicit_matrix: [12]f32,
}

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
