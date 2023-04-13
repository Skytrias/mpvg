package src

import "core:math"
import glm "core:math/linalg/glsl"

Implicit_Curve_Kind :: enum i32 {
	LINE,
	QUADRATIC,
	CUBIC,
}

Implicit_Curve_Orientation :: enum i32 {
	BL,
	BR,
	TL,
	TR,
}

orientation_get :: proc(right, up: bool) -> Implicit_Curve_Orientation {
	if right {
		return up ? .TR : .BR
	} else {
		return up ? .TL : .BL
	}
}

Implicit_Curve :: struct #align 16 {
	box: Box,
	
	M: glm.mat4,
	
	base: [2]f32,
	E: [2]f32,
	
	kind: Implicit_Curve_Kind, 
	orientation: Implicit_Curve_Orientation,
	negative: b32,
	geom_to_left: b32,
	
	out_is_left: b32,
	pad1: i32,
	pad2: i32,
	pad3: i32,
}

IC :: Implicit_Curve

Box :: struct #packed {
	bmin, bmax: [2]f32,
}

ccw :: proc(p, a, b: [2]f32) -> f32 {
	d00 := p.x - a.x
	d01 := p.y - a.y
	d10 := b.x - a.x
	d11 := b.y - a.y
	return d00 * d11 - d01 * d10
}

// box_contains :: proc(box: Box, sample: [2]f32) -> bool {
// 	return box.bmin.x <= sample.x && 
// 		sample.x <= box.bmax.x && 
// 		box.bmin.y <= sample.y && 
// 		sample.y <= box.bmax.y
// }

// box_merge :: proc(using box: ^Box, sample: [2]f32) {
// 	bmin.x = min(bmin.x, sample.x)
// 	bmin.y = min(bmin.y, sample.y)
// 	bmax.x = max(bmax.x, sample.x)
// 	bmax.y = max(bmax.y, sample.y)
// }

// box_reset :: proc(using box: ^Box) {
// 	bmin = { max(f32), max(f32) }
// 	bmax = { -max(f32), -max(f32) }
// }

// box_center :: proc(using box: ^Box) -> [2]f32 {
// 	return (bmax + bmin) * 0.5
// }

// box_hit :: proc(using box: Box, ray: [2]f32) -> int {
// 	if ray.x < bmin.y {
// 		return 0
// 	}

// 	if ray.y >= bmax.y {
// 		return 0
// 	}

// 	if ray.x >= bmax.x {
// 		return 0
// 	}

// 	if ray.x < bmin.x {
// 		return 1
// 	}

// 	return -1
// }

// implicit_curve_base_begin_point :: proc(using base: Implicit_Curve_Base) -> [2]f32 {
// 	return {
// 		(.GOING_RIGHT in flags) ? box.bmin.x : box.bmax.x,
// 		(.GOING_UP in flags) ? box.bmin.y : box.bmax.y,
// 	}
// }

// implicit_curve_base_end_point :: proc(using base: Implicit_Curve_Base) -> [2]f32 {
// 	return {
// 		(.GOING_RIGHT in flags) ? box.bmax.x : box.bmin.x,
// 		(.GOING_UP in flags) ? box.bmax.y : box.bmin.y,
// 	}
// }

// ic1_eval :: proc(using curve: IC1, pt: [2]f32) -> f32 {
// 	b := implicit_curve_base_begin_point(curve)
// 	e := implicit_curve_base_end_point(curve)

// 	A := e.y - b.y
// 	B := b.x - e.x
// 	C := -b.y*B - b.x*A
// 	u := A*pt.x + B*pt.y + C

// 	// If b.y < e.y then the ccw-left is the global left and we are OK.
// 	// Otherwise, we need to change the sign of the function
// 	if A > 0 {
// 		return u
// 	}	else {
// 		return -u
// 	}
// }

// ic1_hit_chull :: proc(using curve: IC1, pt: [2]f32) -> int {
// 	return -1
// }

// ic1_hit :: proc(using curve: IC1, pt: [2]f32) -> int {
// 	check := box_hit(box, pt)
	
// 	if check == 0 {
// 		return 0
// 	}

// 	if check == 1 || ic1_eval(curve, pt) < 0 { // < 0 ? hit
// 		return (.GOING_UP in flags) ? 1 : -1
// 	}

// 	return 0
// }

// ic2_eval :: proc(using curve: IC2, pt, b, e: [2]f32) -> f32 {
// 	p := pt - b

// 	u := M[0][0]*p.x + M[0][1]*p.y
// 	v := M[1][0]*p.x + M[1][1]*p.y

// 	f := u*u - v
// 	if (.NEGATIVE in flags) {
// 		return -f
// 	} else {
// 		return f
// 	}
// }

// ic2_eval_simple :: proc(curve: IC2, pt: [2]f32) -> f32 {
// 	return ic2_eval(curve, pt, implicit_curve_base_begin_point(curve), implicit_curve_base_end_point(curve))
// }

// ic2_hit_chull :: proc(using curve: IC2, pt, b, e: [2]f32) -> int {
// 	sample_to_the_left := ccw(pt, b, e) < 0

// 	if sample_to_the_left == (.GEOMETRY_TO_LEFT in flags) {
// 		return -1
// 	}

// 	// sample is on the opposite side of geometry
// 	if (.OUT_IS_LEFT in flags) {
// 		return 1
// 	} else {
// 		return 0
// 	}
// }

// ic2_hit_chull_simple :: proc(curve: IC2, pt: [2]f32) -> int {
// 	return ic2_hit_chull(curve, pt, implicit_curve_base_begin_point(curve), implicit_curve_base_end_point(curve))
// }

// ic2_hit :: proc(using curve: IC2, pt: [2]f32) -> int {
// 	check := box_hit(curve.box, pt)
	
// 	if check == 0 {
// 		return 0 //above, bellow or to the right
// 	} else if check == 1 { // to the left
// 		return (.GOING_UP in flags) ? 1 : -1
// 	} else {
// 		b := implicit_curve_base_begin_point(curve)
// 		e := implicit_curve_base_end_point(curve)
// 		check = ic2_hit_chull(curve, pt, b, e)
		
// 		if check == 0 {
// 			return 0
// 		}	else if check == 1 {
// 			return (.GOING_UP in flags) ? 1 : -1
// 		}	else {
// 			if ic2_eval(curve, pt, b, e) < 0 {
// 				return (.GOING_UP in flags) ? 1 : -1
// 			}
// 		}
// 	}

// 	return 0
// }

// ic3_eval :: proc(using curve: IC3, pt: [2]f32) -> f32 {
// 	s := pt - base

// 	k := M[0][0]*s.x + M[0][1]*s.y + M[0][2]
// 	l := M[1][0]*s.x + M[1][1]*s.y + M[1][2]
// 	m := M[2][0]*s.x + M[2][1]*s.y + M[2][2]
// 	f := k*k*k - l*m

// 	return (.NEGATIVE in flags) ? -f : f
// }

// ic3_hit_chull :: proc(using curve: IC3, pt: [2]f32) -> int {
// 	b := implicit_curve_base_begin_point(curve)
// 	e := implicit_curve_base_end_point(curve)

// 	sample_to_the_left := ccw(pt, b, e) < 0

// 	if sample_to_the_left == (.GEOMETRY_TO_LEFT in flags) {
// 		if (ccw(pt, e, E) < 0) == sample_to_the_left {
// 			if (ccw(pt, E, b) < 0) == sample_to_the_left {
// 				return -1
// 			}
// 		}

// 		// TODO maybe reversed?
// 		return int(.OUT_IS_LEFT not_in flags)
// 	}

// 	return int(.OUT_IS_LEFT in flags)
// }

// ic3_hit :: proc(using curve: IC3, pt: [2]f32) -> int {
// 	check := box_hit(box, pt)

// 	if check == 0 {
// 		return 0
// 	} else if check == 1 {
// 		return (.GOING_UP in flags) ? 1 : -1
// 	} else {
// 		check = ic3_hit_chull(curve, pt)

// 		if check == 0 {
// 			return 0
// 		} else if check == 1 {
// 			return (.GOING_UP in flags) ? 1 : -1
// 		} else {
// 			if ic3_eval(curve, pt) < 0 {
// 				return (.GOING_UP in flags) ? 1 : -1 
// 			}
// 		}
// 	} 

// 	return 0
// }
