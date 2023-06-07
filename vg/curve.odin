package vg

import "core:fmt"
import "core:math"

V2 :: [2]f32

v2_angle_between :: proc(a, b: V2, face_normalize: bool) -> f32 {
	theta := face_normalize ? v2_dot(v2_normalize(a), v2_normalize(b)) : v2_dot(a, b)
	return math.acos(theta)
}

@private
v2_normalize :: proc(v: V2) -> V2 {
	v := v
	magnitude := math.sqrt(f64(v.x) * f64(v.x) + f64(v.y) * f64(v.y))
	
	if magnitude > 1e-6 {
		magnitude = 1.0 / magnitude
		v.x = f32(f64(v.x) * magnitude)
		v.y = f32(f64(v.y) * magnitude)
	}

	return v
}

@private
v2_normalize_to :: proc(v: V2, scale: f32) -> V2 {
	v := v
	magnitude := math.sqrt(f64(v.x) * f64(v.x) + f64(v.y) * f64(v.y))
	
	if magnitude > 1e-6 {
		magnitude = f64(scale) / magnitude
		v.x = f32(f64(v.x) * magnitude)
		v.y = f32(f64(v.y) * magnitude)
	}

	return v
}

@private
v2_perpendicular :: proc(v: V2) -> V2 {
	return { -v.y, v.x }
}

@private
v2_distance :: proc(p1, p2: V2) -> f32 {
	delta := p2 - p1
	return v2_length(delta)
}

@private
v2_dot :: proc(a, b: V2) -> (c: f32) {
	return a.x * b.x + a.y * b.y
}

@private
v2_cross :: proc(v0, v1: V2) -> f32 {
	return v1.x * v0.y - v0.x * v1.y
}

@private
v2_length :: proc(v: V2) -> f32 {
	return math.sqrt_f32(v.x * v.x + v.y * v.y)
}

@private
v2_lerp_to :: proc(a, b: V2, t: f32) -> V2 {
	return {
		a.x + (b.x - a.x) * t, 
		a.y + (b.y - a.y) * t,
	}
}

@private
v2_lerp :: proc(a, b: V2, t: f32) -> V2 {
	return {
		a.x*(1-t) + b.x*t,
		a.y*(1-t) + b.y*t,
	}
}

curve_print :: proc(curve: Curve) {
	switch curve.count {
	case CURVE_LINE: fmt.eprintf("LINE S(%f : %f)\tE(%f : %f)\n", curve.p[0].x, curve.p[0].y, curve.p[1].x, curve.p[1].y)
	case CURVE_QUADRATIC: fmt.eprintf("QUAD S(%f : %f)\tC(%f : %f)\tE(%f : %f)\n", curve.p[0].x, curve.p[0].y, curve.p[1].x, curve.p[1].y, curve.p[2].x, curve.p[2].y)
	case CURVE_CUBIC: fmt.eprintf("TODO")
	}
}

// get the endpoint of the curve by its type
curve_endpoint :: #force_inline proc(curve: Curve) -> V2 {
	return curve.p[curve.count + 1]
}

curve_beginpoint_tangent :: proc(curve: Curve) -> V2 {
	return curve.p[1] - curve.p[0]
}

curve_endpoint_tangent :: proc(curve: Curve) -> V2 {
	return curve.p[curve.count + 1] - curve.p[curve.count]
}

// invert the start/end point
curve_invert :: proc(curve: ^Curve) {
	if curve.count == CURVE_CUBIC {
		curve.p[2], curve.p[1] = curve.p[1], curve.p[2]
	} 

	curve.p[0], curve.p[curve.count + 1] = curve.p[curve.count + 1], curve.p[0]
}

// split at T
curve_offset_quadratic :: proc(curve: Curve, offset: f32) -> (res1, res2: Curve, split: bool) {
	// vectors between points
	v1 := curve.p[1] - curve.p[0]
	v2 := curve.p[2] - curve.p[1]

	// perpendicular normals
	n1 := v2_perpendicular(v2_normalize_to(v1, offset))
	n2 := v2_perpendicular(v2_normalize_to(v2, offset))

	// offset start/end
	p1 := curve.p[0] + n1
	p2 := curve.p[2] + n2

	// control points
	c1 := curve.p[1] + n1
	c2 := curve.p[1] + n2

	split = v2_angle_between(v1, v2, true) > math.PI / 2
	if !split {
		res1 = curve
		res1.p[0] = p1
		cfinal, cok := line_intersection(p1, c1, p2, c2)
		res1.p[1] = cok ? cfinal : 0
		res1.p[2] = p2
	} else {
		t := quadratic_bezier_nearest_point(curve)
		pt := quadratic_bezier_point(curve, t)
		t1 := curve.p[0] * (1 - t) + curve.p[1] * t
		t2 := curve.p[1] * (1 - t) + curve.p[2] * t
		
		vt := v2_perpendicular(v2_normalize_to(t2 - t1, offset))
		q := pt + vt
		q1, _ := line_intersection(p1, c1, q, q + v2_perpendicular(vt))
		q2, _ := line_intersection(c2, p2, q, q + v2_perpendicular(vt))

		// Calculate the offset points by adding the offset vectors to the original curve points
		res1 = curve
		res1.p[0] = p1
		res1.p[1] = q1
		res1.p[2] = q

		res2 = curve
		res2.p[0] = q
		res2.p[1] = q2
		res2.p[2] = p2
	}

	return
}

line_intersection :: proc(ap0, ap1, bp0, bp1: V2) -> (isec: V2, ok: bool) {
	// look if control points or other points match
	if ap0 == bp0 || ap0 == bp1 {
		isec = ap0
		ok = true
		return
	}
	if ap1 == bp0 || ap1 == bp1 {
		isec = ap1
		ok = true
		return
	}

	denom := f64(bp1.y - bp0.y) * f64(ap1.x - ap0.x) - f64(bp1.x - bp0.x) * f64(ap1.y - ap0.y)
	na := f64(bp1.x - bp0.x) * f64(ap0.y - bp0.y) - f64(bp1.y - bp0.y) * f64(ap0.x - bp0.x)
	nb := f64(ap1.x - ap0.x) * f64(ap0.y - bp0.y) - f64(ap1.y - ap0.y) * f64(ap0.x - bp0.x)
	// fmt.eprintf("INT %.6f %.6f %.6f\n", denom, na, nb)

	if denom != 0 {
		ua := na / denom
		isec = v2_lerp_to(ap0, ap1, f32(ua))
		ok = true
	}

	return
}

// get a point on the bezier curve by t (0 to 1)
cubic_bezier_point :: proc(curve: Curve, t: f32) -> V2 {
	cx := 3 * (curve.p[1].x - curve.p[0].x)
	cy := 3 * (curve.p[1].y - curve.p[0].y)
	bx := 3 * (curve.p[2].x - curve.p[1].x) - cx
	by := 3 * (curve.p[2].y - curve.p[1].y) - cy
	ax := curve.p[3].x - curve.p[0].x - cx - bx
	ay := curve.p[3].y - curve.p[0].y - cy - by
	x := ax * t * t * t + bx * t * t + cx * t + curve.p[0].x
	y := ay * t * t * t + by * t * t + cy * t + curve.p[0].y
	return { x, y }
}

// get a point on the bezier curve by t (0 to 1)
quadratic_bezier_point :: proc(curve: Curve, t: f32) -> V2 {
	x := (1 - t) * (1 - t) * curve.p[0].x + 2 * (1 - t) * t * curve.p[1].x + t * t * curve.p[2].x
	y := (1 - t) * (1 - t) * curve.p[0].y + 2 * (1 - t) * t * curve.p[1].y + t * t * curve.p[2].y
	return { x, y }
}

// get the closest point on the bezier curve to the control point
quadratic_bezier_nearest_point :: proc(curve: Curve) -> f32 {
	v0 := curve.p[1] - curve.p[0]
	v1 := curve.p[2] - curve.p[1]

	a := v2_dot(v1 - v0, v1 - v0)
	b := 3 * (v2_dot(v1, v0) - v2_dot(v0, v0))
	c := 3 * (v2_dot(v0, v0) - v2_dot(v1, v0))
	d := -1 * v2_dot(v0, v0)

	p := -b / (3 * a)
	q := p * p * p + (b * c - 3 * a * d) / (6 * a * a)
	r := c / (3 * a)

	s := math.sqrt_f32(q * q + math.pow_f32(r - p * p, 3))
	t := cbrt(q + s) + cbrt(q - s) + p

	return t
}

// cubic root
cbrt :: proc(x: f32) -> f32 {
	sign: f32 = x == 0 ? 0 : x > 0 ? 1 : -1
	return sign * math.pow(math.abs(x), 1 / 3)
}

quadratic_bezier_is_linear :: proc(curve: Curve) -> bool {
	// Calculate the slope of the line connecting the start and end points
	slope := (curve.p[2].y - curve.p[0].y) / (curve.p[2].x - curve.p[0].x)

	// Calculate the y-coordinate of the control point on the line connecting the start and end points
	control_y_on_line := curve.p[0].y + slope * (curve.p[1].x - curve.p[0].x)

	// Check if the y-coordinate of the control point is equal to the actual y-coordinate of the control point
	return curve.p[1].y == control_y_on_line
}

v2_set_length :: proc(v: V2, scale: f32) -> V2 {
	length := math.sqrt_f32(v.x * v.x + v.y * v.y)
	return {
		scale * v.x / length,
		scale * v.y / length,
	}
}

v2_same_direction :: proc(a, b: V2) -> bool {
	same :: proc(a, b: f32) -> bool {
		return abs(a - b) < 1e-8
	}

	aunit := v2_set_length(a, 1)
	bunit := v2_set_length(b, 1)

	return same(aunit.x, bunit.x) && same(aunit.y, bunit.y) || same(aunit.x, -bunit.x) || same(aunit.y, -bunit.y)
}

// v2_intersection :: proc(abase, adirection, bbase, bdirection: V2) -> V2 {
// 	fmt.eprintln(adirection, bdirection)

// 	if v2_same_direction(adirection, bdirection) {
// 		fmt.panicf("same direction %f %f\n", adirection, bdirection)
// 	}

// 	// if (sameDirection(aDirection, bDirection))
// 	//     return 'parallel-or-identical'

// 	// would result in a == 0 which in turn would result in a division by 0
// 	// so we just switch the args, they can both have a direction in y direction of 0
// 	// since then they would have the same direction which is already tested
// 	abase := abase
// 	bbase := bbase
// 	adirection := adirection
// 	bdirection := bdirection

// 	if adirection.y == 0 {
// 		abase, bbase = bbase, abase
// 		adirection, bdirection = bdirection, adirection
// 	}

// 	a1x := abase.x
// 	a1y := abase.y
// 	a2x := abase.x + adirection.x
// 	a2y := abase.y + adirection.y

// 	a := a1y - a2y
// 	b := a2x - a1x
// 	c := a1x * a2y - a2x * a1y

// 	b1x := bbase.x
// 	b1y := bbase.y

// 	b2x := b1x + bdirection.x
// 	b2y := b1y + bdirection.y

// 	d := b1y - b2y
// 	e := b2x - b1x
// 	f := b1x * b2y - b2x * b1y

// 	y := (d * c - f * a) / (a * e - d * b)
// 	x := (-c - b * y) / a

// 	return { x, y }
// }

// split at T
curve_offset_cubic :: proc(curve: Curve, offset: f32) -> (res: Curve) {
	// vectors between points
	v1 := curve.p[1] - curve.p[0]
	v2 := curve.p[2] - curve.p[1] // between control points
	v3 := curve.p[3] - curve.p[2]

	// perpendicular normals
	n1 := v2_perpendicular(v2_normalize_to(v1, offset))
	n2 := v2_perpendicular(v2_normalize_to(v2, offset)) // between control points
	n3 := v2_perpendicular(v2_normalize_to(v3, offset))

	// offset start/end
	pstart := curve.p[0] + n1
	pc1 := curve.p[1] + n2
	pc2 := curve.p[2] + n2
	pend := curve.p[3] + n3

	// control points
	c1n1 := curve.p[1] + n1
	c1n2 := curve.p[1] + n2
	c2n2 := curve.p[2] + n2
	c2n3 := curve.p[2] + n3
	
	c1, _ := line_intersection(pstart, c1n1, c1n2, c2n2)
	c2, _ := line_intersection(c1n2, c2n2, c2n3, pend)

	res = curve
	res.p[0] = pstart
	res.p[1] = c1
	res.p[2] = c2
	res.p[3] = pend

	return
}