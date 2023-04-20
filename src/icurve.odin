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
	// if right {
	// 	return up ? .BR : .TR
	// } else {
	// 	return up ? .BL : .TL
	// }

	if right {
		return up ? .BR : .BL
	} else {
		return up ? .TR : .TL
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

Box :: struct #packed {
	bmin, bmax: [2]f32,
}
