package src

import "core:fmt"
import "core:slice"

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
	res := c3_classify(curve)

	c := [4][2]f32 {
		B[0],
		3.0*(B[1] - B[0]),
		3.0*(B[0] + B[2] - 2*B[1]),
		3.0*(B[1] - B[2]) + B[3] - B[0],
	}

	if res.type == .DEGENERATE_LINE {
		c1_preprocess1({}, roots, ctx)
		return
	} else if res.type == .DEGENERATE_QUADRATIC {
		fmt.eprintln("DO QUAD")
		return
	}

	//NOTE: get the roots of B'(s) = 3.c3.s^2 + 2.c2.s + c1
	rootCount := quadratic_roots(3*c[3].x, 2*c[2].x, c[1].x, roots[:])
	rootCount += quadratic_roots(3*c[3].y, 2*c[2].y, c[1].y, roots[rootCount:])

	// NOTE: add double points and inflection points to roots if finite
	for i in 0..<2 {
		if res.ts[i].y > 0 {
			roots[rootCount] = res.ts[i].x / res.ts[i].y
			rootCount += 1
		}
	}

	//NOTE: sort roots
	for i in 1..<rootCount {
		tmp := roots[i]
		j := i-1
		
		for j >= 0 && roots[j] > tmp {
			roots[j+1] = roots[j]
			j -= 1
		}

		roots[j+1] = tmp
	}

	roots[rootCount] = 1
	rootCount += 1

	if rootCount < MAX_ROOTS {
		roots[rootCount] = max(f32)
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
	ctx: ^Implicizitation_Context,
) {
	c1_split(output, output_index, curve)
}

c2_preprocess2 :: proc(
	output: []Implicit_Curve,
	output_index: ^int,
	curve: Curve,
	roots: ^Roots,
	ctx: ^Implicizitation_Context,
) {
	c2_split(output, output_index, curve, roots)
}

c3_preprocess2 :: proc(
	output: []Implicit_Curve,
	output_index: ^int,
	curve: Curve,
	roots: ^Roots,
	ctx: ^Implicizitation_Context,
) {
	// fmt.eprintln("2", ctx.cubic_type, curve)
	if ctx.cubic_type == .DEGENERATE_QUADRATIC || ctx.cubic_type == .DEGENERATE_LINE {
		c := c1_make(curve.B[0], curve.B[3])
		c1_split(output, output_index, c)
	} else {
		c3_split(output, output_index, curve, roots, ctx)
	}	
}

Preprocess1_Call :: #type proc(Curve, ^Roots, ^Implicizitation_Context)

preprocess1 := [3]Preprocess1_Call {
	c1_preprocess1,
	c2_preprocess1,
	c3_preprocess1,
}

Preprocess2_Call :: #type proc([]Implicit_Curve, ^int, Curve, ^Roots, ^Implicizitation_Context)

// // LUT for process calls
preprocess2 := [3]Preprocess2_Call {
	c1_preprocess2,
	c2_preprocess2,
	c3_preprocess2,
}
