package src

illustration_to_image :: proc(using curve: Curve, scale, offset: [2]f32) -> (res: Curve) {
	res.count = curve.count

	for i in 0..=curve.count + 1 {
		res.B[i] = B[i] * scale + offset
	}

	return
}

c1_preprocess1 :: proc(curve: Curve, roots: ^Roots) {
	roots[0] = 1
	roots[1] = max(f32)
}

c2_preprocess1 :: proc(curve: Curve, roots: ^Roots) {
	nroots := c2_calc_roots(curve, roots)
	roots[nroots] = 1
	nroots += 1
	roots[nroots] = max(f32)
}

c3_preprocess1 :: proc(
	using curve: Curve, 
	roots: ^Roots, 
	ctx: ^Implicizitation_Context,
) {
	ts, type := c3_classify_with_ctx(curve, ctx)
	ctx.cubic_type = type

	#partial switch ctx.cubic_type {
	case .QUADRATIC, .LINE: 
		temp: Curve
		c1_init(&temp, B[0], B[3])
		c1_preprocess1(temp, roots)
		return

	case .POINT:
		roots[0] = max(f32)
		return
	}

	nroots := c3_calc_roots(curve, roots)

	{
		r := ts[0].x / ts[0].y
		if 0 < r && r < 1 {
			roots[nroots] = r
			nroots += 1
		}

		r = ts[1].x / ts[1].y
		if 0 < r && r < 1 {
			roots[nroots] = r
			nroots += 1
		}
	}

	// TODO sort
	// sort()

	roots[nroots] = 1
	nroots += 1

	if nroots < MAX_ROOTS {
		roots[nroots] = max(f32)
	}
}

import "core:fmt"
c1_split :: proc(output: ^[dynamic]Implicit_Curve, curve: Curve, roots: ^Roots) {
	assert(curve.count == 0)
	last_root: f32

	for i := 0; i < MAX_ROOTS && roots[i] < max(f32); i += 1 {
		root := roots[i]
		// append(output, c1_implicitize(c1_subcurve(curve, last_root, root), last_root, root))
		append(output, c1_implicitize(c1_subcurve(curve, last_root, root), last_root, root))
		last_root = root
	}
}

c1_process :: proc(
	output: ^[dynamic]Implicit_Curve,
	curve: Curve, 
	scale: [2]f32,
	offset: [2]f32,
) {
	roots: Roots
	c1_preprocess1(curve, &roots)
	temp := illustration_to_image(curve, scale, offset)
	c1_split(output, temp, &roots)
}

c2_split :: proc(output: ^[dynamic]Implicit_Curve, curve: Curve, roots: ^Roots) {
	assert(curve.count == 1)
	last_root: f32

	for i := 0; i < MAX_ROOTS && roots[i] < max(f32); i += 1 {
		root := roots[i]
		append(output, c2_implicitize(c2_subcurve(curve, last_root, root), last_root, root))
		last_root = root
	}
}

c2_process :: proc(
	output: ^[dynamic]Implicit_Curve,
	curve: Curve, 
	scale: [2]f32,
	offset: [2]f32,
) {
	roots: Roots
	c2_preprocess1(curve, &roots)
	temp := illustration_to_image(curve, scale, offset)
	c2_split(output, temp, &roots)
}

c3_split :: proc(output: ^[dynamic]Implicit_Curve, curve: Curve, roots: ^Roots, ctx: ^Implicizitation_Context) {
	assert(curve.count == 2)
	last_root: f32

	for i := 0; i < MAX_ROOTS && roots[i] < max(f32); i += 1 {
		root := roots[i]
		append(output, c3_implicitize(c3_subcurve(curve, last_root, root), last_root, root, ctx))
		last_root = root
	}
}

c3_process :: proc(
	output: ^[dynamic]Implicit_Curve,
	curve: Curve, 
	scale: [2]f32,
	offset: [2]f32,
) {
	roots: Roots
	ctx: Implicizitation_Context
	c3_preprocess1(curve, &roots, &ctx)
	
	if ctx.cubic_type == .QUADRATIC || ctx.cubic_type == .LINE {
		c := c1_make(curve.B[0], curve.B[3])
		temp := illustration_to_image(c, scale, offset)
		c1_split(output, temp, &roots)
	} else {
		temp := illustration_to_image(curve, scale, offset)
		c3_split(output, temp, &roots, &ctx)
	}
}

Process_Call :: #type proc(
	output: ^[dynamic]Implicit_Curve,
	curve: Curve, 
	scale: [2]f32,
	offset: [2]f32,
)

process := [3]Process_Call {
	c1_process,
	c2_process,
	c3_process,
}

curves_preprocess :: proc(
	output: ^[dynamic]Implicit_Curve,
	curves: []Curve, 
	scale: [2]f32,
	offset: [2]f32,
) {
	for c in curves {
		process[c.count](output, c, scale, offset)
	}
}