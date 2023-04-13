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
