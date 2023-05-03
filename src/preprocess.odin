package src

import "core:fmt"
import "core:slice"

illustration_to_image :: proc(using curve: Curve, scale, offset: [2]f32) -> (res: Curve) {
	res.count = curve.count

	for i in 0..=curve.count + 1 {
		res.B[i] = B[i] * scale + offset
	}

	return
}

c1_preprocess1 :: proc(curve: Curve, roots: ^Roots, ctx: ^Implicizitation_Context) {
	roots[0] = 1
	roots[1] = max(f32)
}

c2_preprocess1 :: proc(curve: Curve, roots: ^Roots, ctx: ^Implicizitation_Context) {
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
	// fmt.eprintln("1 TYPE", curve)
	res := c3_classify_with_ctx(curve, ctx)
	ctx.cubic_type = type

	if 

	#partial switch ctx.cubic_type {
	case .DEGENERATE_QUADRATIC, .DEGENERATE_LINE: 
		// temp: Curve
		fmt.eprintln("called")
		// c1_init(&temp, B[0], B[3])
		c1_preprocess1({}, roots, ctx)
		return

	// case .POINT:
	// 	roots[0] = max(f32)
	// 	return
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

	// if nroots > 1 {
		// fmt.eprintln("BEFORE", roots[:nroots])
		slice.stable_sort(roots[:nroots])
		// fmt.eprintln("AFTER", roots[:nroots])
	// }

	roots[nroots] = 1
	nroots += 1

	if nroots < MAX_ROOTS {
		roots[nroots] = max(f32)
	}
}

c1_split :: proc(
	output: []Implicit_Curve, 
	output_index: ^int,
	curve: Curve,
) {
	output[output_index^] = c1_implicitize(c1_subcurve(curve, 0, 1))
	output_index^ += 1
}

c2_split :: proc(
	output: []Implicit_Curve, 
	output_index: ^int,
	curve: Curve, 
	roots: ^Roots,
) {
	assert(curve.count == 1)
	last_root: f32

	for i := 0; i < MAX_ROOTS && roots[i] < max(f32); i += 1 {
		root := roots[i]
		output[output_index^] = c2_implicitize(c2_subcurve(curve, last_root, root), last_root, root)
		output_index^ += 1
		last_root = root
	}
}

c3_split :: proc(
	output: []Implicit_Curve, 
	output_index: ^int,
	curve: Curve, 
	roots: ^Roots, 
	ctx: ^Implicizitation_Context,
) {
	assert(curve.count == 2)
	last_root: f32

	for i := 0; i < MAX_ROOTS && roots[i] < max(f32); i += 1 {
		root := roots[i]
		output[output_index^] = c3_implicitize(c3_subcurve(curve, last_root, root), last_root, root, ctx)
		output_index^ += 1
		last_root = root
	}
}

c1_preprocess2 :: proc(
	output: []Implicit_Curve,
	output_index: ^int,
	curve: Curve,
	roots: ^Roots,
	scale: [2]f32,
	offset: [2]f32,
	ctx: ^Implicizitation_Context,
) {
	c1_split(output, output_index, illustration_to_image(curve, scale, offset))
}

c2_preprocess2 :: proc(
	output: []Implicit_Curve,
	output_index: ^int,
	curve: Curve,
	roots: ^Roots,
	scale: [2]f32,
	offset: [2]f32,
	ctx: ^Implicizitation_Context,
) {
	c2_split(output, output_index, illustration_to_image(curve, scale, offset), roots)
}

c3_preprocess2 :: proc(
	output: []Implicit_Curve,
	output_index: ^int,
	curve: Curve,
	roots: ^Roots,
	scale: [2]f32,
	offset: [2]f32,
	ctx: ^Implicizitation_Context,
) {
	// fmt.eprintln("2", ctx.cubic_type, curve)
	if ctx.cubic_type == .DEGENERATE_QUADRATIC || ctx.cubic_type == .DEGENERATE_LINE {
		c := c1_make(curve.B[0], curve.B[3])
		temp := illustration_to_image(c, scale, offset)
		c1_split(output, output_index, temp)
	} else {
		temp := illustration_to_image(curve, scale, offset)
		c3_split(output, output_index, temp, roots, ctx)
	}	
}

Preprocess1_Call :: #type proc(Curve, ^Roots, ^Implicizitation_Context)

preprocess1 := [3]Preprocess1_Call {
	c1_preprocess1,
	c2_preprocess1,
	c3_preprocess1,
}

Preprocess2_Call :: #type proc([]Implicit_Curve, ^int, Curve, ^Roots, [2]f32, [2]f32, ^Implicizitation_Context)

// // LUT for process calls
preprocess2 := [3]Preprocess2_Call {
	c1_preprocess2,
	c2_preprocess2,
	c3_preprocess2,
}
