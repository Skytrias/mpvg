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

// cubic_setup :: proc(using curve: Curve, icurves: []Implicit_Curve, curve_index: ^int) {
// 	c := [4][2]f32 {
// 		B[0],
// 		3.0*(B[1] - B[0]),
// 		3.0*(B[0] + B[2] - 2*B[1]),
// 		3.0*(B[1] - B[2]) + B[3] - B[0],
// 	}

// 	res := c3_classify(curve)

// 	if res.type == .DEGENERATE_LINE {
// 		c := c1_make(B[0], B[3])
// 		line_setup(c, icurves, curve_index)
// 		return
// 	} else if res.type == .DEGENERATE_QUADRATIC {
// 		quad_point := [2]f32 {
// 			1.5*B[1].x - 0.5*B[0].x, 
// 			1.5*B[1].y - 0.5*B[0].y,
// 		}
// 		temp := c2_make(B[0], quad_point, B[3])
// 		quadratic_setup(temp, icurves, curve_index)
// 		return
// 	}

// 	roots: [6]f32
// 	//NOTE: get the roots of B'(s) = 3.c3.s^2 + 2.c2.s + c1
// 	root_count := quadratic_roots(3*c[3].x, 2*c[2].x, c[1].x, roots[:])
// 	root_count += quadratic_roots(3*c[3].y, 2*c[2].y, c[1].y, roots[root_count:])

// 	// NOTE: add double points and inflection points to roots if finite
// 	for i in 0..<2 {
// 		if res.ts[i].y > 0 {
// 			roots[root_count] = res.ts[i].x / res.ts[i].y
// 			root_count += 1
// 		}
// 	}

// 	//NOTE: sort roots
// 	for i in 1..<root_count {
// 		tmp := roots[i]
// 		j := i-1
		
// 		for j >= 0 && roots[j] > tmp {
// 			roots[j+1] = roots[j]
// 			j -= 1
// 		}

// 		roots[j+1] = tmp
// 	}	

// 	// compute split points
// 	splits: [8]f32
// 	split_count := 1
// 	for i in 0..<root_count {
// 		value := roots[i]
		
// 		if value > 0 && value < 1 {
// 			splits[split_count] = roots[i]
// 			split_count += 1
// 		}
// 	}
// 	splits[split_count] = 1
// 	split_count += 1

// 	for i in 0..<split_count - 1 {
// 		s0 := splits[i]
// 		s1 := splits[i + 1]
// 		sp: Curve_Cubic
// 		c3_slice(curve, s0, s1, &sp)
// 		cubic_emit(curve, res, s0, s1, sp, icurves, curve_index)
// 	}
// }

// cubic_emit :: proc(
// 	using curve: Curve, 
// 	info: Cubic_Info, 
// 	s0, s1: f32, 
// 	sp: Curve_Cubic, 
// 	icurves: []Implicit_Curve,
// 	curve_index: ^int,
// ) {
// 	// TODO temp!
// 	temp := Curve { sp, 2, 0, 0, 0 }
// 	icurve := icurve_make(temp)

// 	v0 := B[0]
// 	v1 := B[3]
// 	v2: [2]f32
// 	K: glm.mat3

// 	sqr_norm0 := linalg.vector_length(B[1] - B[0])
// 	sqr_norm1 := linalg.vector_length(B[2] - B[3])

// 	if linalg.vector_length(B[0] - B[3]) > 1e-5 {
// 		if sqr_norm0 >= sqr_norm1 {
// 			v2 = B[1]
// 			K = { 
// 				info.K[0].x, info.K[0].y, info.K[0].z,
// 				info.K[3].x, info.K[3].y, info.K[3].z,
// 				info.K[1].x, info.K[1].y, info.K[1].z,
// 			}
// 		} else {
// 			v2 = B[2]
// 			K = { 
// 				info.K[0].x, info.K[0].y, info.K[0].z,
// 				info.K[3].x, info.K[3].y, info.K[3].z,
// 				info.K[2].x, info.K[2].y, info.K[2].z,
// 			}
// 		}
// 	} else {
// 		v1 = B[1]
// 		v2 = B[2]
// 		K = {
// 			info.K[0].x, info.K[0].y, info.K[0].z,
// 			info.K[1].x, info.K[1].y, info.K[1].z,
// 			info.K[2].x, info.K[2].y, info.K[2].z,
// 		}
// 	}

// 	bary := barycentric_matrix(v0, v1, v2)
// 	m := K * bary
// 	// icurve.implicit_matrix = {
// 	// 	m[0, 0], m[1, 0], m[2, 0], 0,
// 	// 	m[0, 1], m[1, 1], m[2, 1], 0,
// 	// 	m[0, 2], m[1, 2], m[2, 2], 0,
// 	// }
// 	icurve.implicit_matrix = {
// 		m[0, 0], m[0, 1], m[0, 2], 0,
// 		m[1, 0], m[1, 1], m[1, 2], 0,
// 		m[2, 0], m[2, 1], m[2, 2], 0,
// 	}

// 	icurve.hull_vertex = select_hull_vertex(sp[0], sp[1], sp[2], sp[3])
// 	icurve.sign = 1

// 	if info.type == .SERPENTINE || info.type == .CUSP {
// 		icurve.sign = info.d1 < 0 ? -1 : 1
// 	} else if info.type == .CUBIC_LOOP {
// 		d1 := info.d1
// 		d2 := info.d2
// 		d3 := info.d3

// 		H0 := d3*d1-square(d2) + d1*d2*s0 - square(d1)*square(s0)
// 		H1 := d3*d1-square(d2) + d1*d2*s1 - square(d1)*square(s1)
// 		H := (abs(H0) > abs(H1)) ? H0 : H1
// 		icurve.sign = H*d1 > 0 ? -1 : 1
// 	}

// 	if sp[3].y > sp[0].y {
// 		icurve.sign *= -1
// 	}

// 	icurves[curve_index^] = icurve
// 	curve_index^ += 1
// }

// select_hull_vertex :: proc(p0, p1, p2, p3: [2]f32) -> (pm: [2]f32) {
// 	/*NOTE: check intersection of lines (p1-p0) and (p3-p2)
// 		P = p0 + u(p1-p0)
// 		P = p2 + w(p3-p2)

// 		control points are inside a right triangle so we should always find an intersection
// 	*/
// 	det := (p1.x - p0.x)*(p3.y - p2.y) - (p1.y - p0.y)*(p3.x - p2.x)
// 	sqr_norm0 := linalg.vector_length(p1-p0)
// 	sqr_norm1 := linalg.vector_length(p2-p3)

// 	if abs(det) < 1e-3 || sqr_norm0 < 0.1 || sqr_norm1 < 0.1 {
// 		sqr_norm0 := linalg.vector_length(p1-p0)
// 		sqr_norm1 := linalg.vector_length(p2-p3)

// 		if sqr_norm0 < sqr_norm1 {
// 			pm = p2
// 		} else {
// 			pm = p1
// 		}
// 	} else {
// 		u := ((p0.x - p2.x)*(p2.y - p3.y) - (p0.y - p2.y)*(p2.x - p3.x))/det
// 		pm = p0 + u*(p1-p0)
// 	}

// 	return
// }

// barycentric_matrix :: proc(v0, v1, v2: [2]f32) -> (B: glm.mat3) {
// 	det := v0.x*(v1.y-v2.y) + v1.x*(v2.y-v0.y) + v2.x*(v0.y - v1.y)
// 	// TODO do these better on gpu
//  	B = {
//  		v1.y - v2.y, v2.y-v0.y, v0.y-v1.y,
// 		v2.x - v1.x, v0.x-v2.x, v1.x-v0.x,
// 		v1.x*v2.y-v2.x*v1.y, v2.x*v0.y-v0.x*v2.y, v0.x*v1.y-v1.x*v0.y,
// 	}
//  	B = linalg.matrix_mul(B, 1.0 / det)
//  	return
// }

// Cubic_Type :: enum {
// 	UNKOWN,
// 	SERPENTINE,
// 	CUSP,
// 	CUSP_AT_INFINITY,
// 	CUBIC_LOOP,
// 	DEGENERATE_QUADRATIC,
// 	DEGENERATE_LINE,
// }

// Cubic_Info :: struct {
// 	type: Cubic_Type,
// 	K: glm.mat4,
// 	ts: [2][2]f32,
// 	d1: f32,
// 	d2: f32,
// 	d3: f32,
// }

// square :: #force_inline proc(a: f32) -> f32 {
// 	return a*a 
// }

// cube :: #force_inline proc(a: f32) -> f32 {
// 	return a*a*a 
// }

// c3_classify :: proc(using curve: Curve) -> (res: Cubic_Info) #no_bounds_check {
// 	F: glm.mat4

// 	d1 := -(B[3].y*B[2].x - B[3].x*B[2].y)
// 	d2 := -(B[3].x*B[1].y - B[3].y*B[1].x)
// 	d3 := -(B[2].y*B[1].x - B[2].x*B[1].y)

// 	discr_factor2 := 3.0 * square(d2) - 4.0*d3*d1

// 	if abs(d1) <= 1e-6 && abs(d2) <= 1e-6 && abs(3) > 1e-6 {
// 		res.type = .DEGENERATE_QUADRATIC
// 	} else if (discr_factor2 > 0 && abs(d1) > 1e-6) || (discr_factor2 == 0 && abs(d1) > 1e-6) {
// 		fmt.eprintln("cusp or serpentine")

// 		tmtl: [4]f32
// 		n := quadratic_roots_with_det(1, -2*d2, (4. / 3.)*d1*d3, (1. / 3.)*discr_factor2, tmtl[:])

// 		tm := tmtl[0]
// 		sm := 2*d1
// 		tl := tmtl[1]
// 		sl := 2*d1

// 		invNorm := 1/math.sqrt(square(tm) + square(sm))
// 		tm *= invNorm
// 		sm *= invNorm

// 		invNorm = 1/math.sqrt(square(tl) + square(sl))
// 		tl *= invNorm
// 		sl *= invNorm

// 		res.type = (discr_factor2 > 0 && d1 != 0) ? .SERPENTINE : .CUSP

// 		F = {
// 			tl*tm, -sm*tl-sl*tm, sl*sm, 0,
// 			cube(tl), -3*sl*square(tl), 3*square(sl)*tl, -cube(sl),
// 			cube(tm), -3*sm*square(tm), 3*square(sm)*tm, -cube(sm),
// 			1, 0, 0, 0,
// 		}

// 		res.ts[0] = {tm, sm}
// 		res.ts[1] = {tl, sl}

// 	} else if discr_factor2 < 0 && abs(d1) > 1e-6 {
// 		fmt.eprintln("loop")
// 		res.type = .CUBIC_LOOP

// 		tmtl: [4]f32
// 		n := quadratic_roots_with_det(1, -2*d2, 4*(square(d2)-d1*d3), -discr_factor2, tmtl[:])

// 		td := tmtl[1]
// 		sd := 2*d1
// 		te := tmtl[0]
// 		se := 2*d1

// 		invNorm := 1/math.sqrt(square(td) + square(sd))
// 		td *= invNorm
// 		sd *= invNorm

// 		invNorm = 1/math.sqrt(square(te) + square(se))
// 		te *= invNorm
// 		se *= invNorm

// 		F = {
// 			td*te, -se*td-sd*te, sd*se, 0,
// 			square(td)*te, -se*square(td)-2*sd*te*td, te*square(sd)+2*se*td*sd, -square(sd)*se,
// 			td*square(te), -sd*square(te)-2*se*td*te, td*square(se)+2*sd*te*se, -sd*square(se),
// 			1, 0, 0, 0,
// 		}

// 		res.ts[0] = {td, sd}
// 		res.ts[1] = {te, se}
// 	} else if d2 != 0 {
// 		tl := d3
// 		sl := 3*d2

// 		invNorm := 1/math.sqrt(square(tl)+square(sl))
// 		tl *= invNorm
// 		sl *= invNorm

// 		res.type = .CUSP_AT_INFINITY

// 		F = {
// 			tl, -sl, 0, 0,
// 		  cube(tl), -3*sl*square(tl), 3*square(sl)*tl, -cube(sl),
// 		  1, 0, 0, 0,
// 		  1, 0, 0, 0,
// 		}

// 		res.ts[0] = {tl, sl}
// 		res.ts[1] = {0, 0}
// 	} else {
// 		res.type = .DEGENERATE_LINE
// 	}

// 	inv_M3 := glm.mat4 {
// 		1, 1, 1, 1,
// 		0, 1./3., 2./3., 1,
// 		0, 0, 1./3., 1,
// 		0, 0, 0, 1,
// 	};

// 	// TODO double check transpose?
// 	res.K = glm.transpose(inv_M3 * F)
// 	return
// }
