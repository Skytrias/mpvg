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

orientation_get :: proc(
	going_right, going_up: bool, 
	dx, dy: f32,
	ofs: f32,
	alpha: f32,
) -> Implicit_Curve_Orientation {
	if going_right == going_up {
		return dy > alpha * dx ? .TL : .BR
	} else {
		return dy < ofs - alpha * dx ? .BL : .TR
	}
}

Implicit_Curve :: struct {
	box: Box,
	
	M: glm.mat4,
	
	base: [2]f32,
	E: [2]f32,
	
	kind: Implicit_Curve_Kind, 
	orientation: Implicit_Curve_Orientation,
	negative: b32,
	going_up: b32,

	winding_increment: i32,
	pad1: b32,
	pad2: i32,
	pad3: i32,
}

Box :: [4]f32

ccw :: proc(a, b, c: [2]f32) -> f32 {
	return ((b.x-a.x)*(c.y-a.y) - (b.y-a.y)*(c.x-a.x));
}

curve_eval :: proc(curve: Implicit_Curve, pt: [2]f32) -> (side: int) {
	if pt.y > curve.box.w || pt.y <= curve.box.y {
		if pt.x > curve.box.x && pt.x <= curve.box.z {
			if pt.y > curve.box.w {
				side = (curve.orientation == .TL || curve.orientation == .BR) ? -1 : 1
			}	else {
				side = (curve.orientation == .TL || curve.orientation == .BR) ? 1 : -1
			}
		}
	} else if pt.x > curve.box.z {
		side = 1
	} else if pt.x <= curve.box.x {
		side = -1
	} else {
		a, b: [2]f32

		switch curve.orientation {
		case .TL:
			a = curve.box.xy
			b = curve.box.zw

		case .BR:
			a = curve.box.zw
			b = curve.box.xy

		case .TR:
			a = curve.box.xw
			b = curve.box.zy

		case .BL:
			a = curve.box.zy
			b = curve.box.xw
		}

		c := curve.E

		if ccw(a, b, pt) < 0 {
			// other side of the diagonal
			side = (curve.orientation == .BR || curve.orientation == .TR) ? -1 : 1
		}	else if(ccw(b, c, pt) < 0 || ccw(c, a, pt) < 0) {
			// same side of the diagonal, but outside curve hull
			side = (curve.orientation == .BL || curve.orientation == .TL) ? -1 : 1
		}	else {
			// inside curve hull
			switch curve.kind {
			case .LINE:
				side = 1

			case .QUADRATIC:
				ph := [4]f32 { pt.x, pt.y, 1, 1 }
				klm := curve.M * ph
				side = ((klm.x*klm.x - klm.y)*klm.z < 0) ? -1 : 1

			case .CUBIC:
				ph := [4]f32 { pt.x, pt.y, 1, 1 }
				klm := curve.M * ph
				sign: f32 = curve.negative ? 1 : 0
				side = (sign * (klm.x*klm.x*klm.x - klm.y*klm.z) < 0)? -1 : 1
			}
		}
	}

	return
}