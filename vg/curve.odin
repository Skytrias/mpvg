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
	magnitude := v.x * v.x + v.y * v.y
	
	if magnitude > 0 {
		magnitude = 1 / math.sqrt(magnitude)
		v.x *= magnitude
		v.y *= magnitude
	}

	return v
}

@private
v2_normalize_to :: proc(v: V2, scale: f32) -> V2 {
	v := v
	magnitude := math.sqrt_f32(v.x * v.x + v.y * v.y)
	
	if magnitude > 0 {
		magnitude = scale / magnitude
		v.x *= magnitude
		v.y *= magnitude
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
v2_lerp :: proc(a, b: V2, t: f32) -> V2 {
	return {
		a.x*(1-t) + b.x*t,
		a.y*(1-t) + b.y*t,
	}
}

// get the endpoint of the curve by its type
curve_endpoint :: #force_inline proc(curve: Curve) -> V2 {
	return curve.B[curve.count + 1]
}

curve_invert :: proc(curve: ^Curve) {
	curve.B[0], curve.B[curve.count + 1] = curve.B[curve.count + 1], curve.B[0]
}

// split at T
curve_offset_quadratic1 :: proc(curve: Curve, offset: f32) -> (res1, res2: Curve, split: bool) {
	// vectors between points
	v1 := curve.B[0] + curve.B[1]
	v2 := curve.B[2] - curve.B[1]

	// perpendicular normals
	n1 := v2_perpendicular(v2_normalize_to(v1, offset))
	n2 := v2_perpendicular(v2_normalize_to(v2, offset))

	// offset start/end
	p1 := curve.B[0] + n1
	p2 := curve.B[2] + n2

	// control points
	c1 := curve.B[1] + n1
	c2 := curve.B[1] + n2

	split = v2_angle_between(v1, v2, true) > math.PI / 2
	if !split {
		res1 = curve
		res1.B[0] = p1
		res1.B[1] = line_intersection2(p1, c1, c2, p2)
		res1.B[2] = p2
	} else {
		t := quadratic_bezier_nearest_point(curve)
		pt := quadratic_bezier_point(curve, t)
		t1 := curve.B[0] * (1 - t) + curve.B[1] * t
		t2 := curve.B[1] * (1 - t) + curve.B[2] * t
		
		vt := v2_perpendicular(v2_normalize_to(t2 - t1, offset))
		q := pt + vt
		q1 := line_intersection2(p1, c1, q, q + v2_perpendicular(vt))
		q2 := line_intersection2(c2, p2, q, q + v2_perpendicular(vt))

		// Calculate the offset points by adding the offset vectors to the original curve points
		res1 = curve
		res1.B[0] = p1
		res1.B[1] = q1
		res1.B[2] = q

		res2 = curve
		res2.B[0] = q
		res2.B[1] = q2
		res2.B[2] = p2
	}

	return
}

// between two lines (p1->p2) and (p3->p4)
line_intersection2 :: proc(p1, p2, p3, p4: V2) -> V2 {
	x1 := p1.x
	y1 := p1.y
	x2 := p2.x
	y2 := p2.y
	x3 := p3.x
	y3 := p3.y
	x4 := p4.x
	y4 := p4.y
	ua := ((x4 - x3) * (y1 - y3) - (y4 - y3) * (x1 - x3)) / ((y4 - y3) * (x2 - x1) - (x4 - x3) * (y2 - y1))

	return {
		x1 + ua * (x2 - x1),
		y1 + ua * (y2 - y1),
	}
}

// get a point on the bezier curve by t (0 to 1)
cubic_bezier_point :: proc(p: [4]V2, t: f32) -> V2 {
	cx := 3 * (p[1].x - p[0].x)
	cy := 3 * (p[1].y - p[0].y)
	bx := 3 * (p[2].x - p[1].x) - cx
	by := 3 * (p[2].y - p[1].y) - cy
	ax := p[3].x - p[0].x - cx - bx
	ay := p[3].y - p[0].y - cy - by
	x := ax * t * t * t + bx * t * t + cx * t + p[0].x
	y := ay * t * t * t + by * t * t + cy * t + p[0].y
	return { x, y }
}

// get a point on the bezier curve by t (0 to 1)
quadratic_bezier_point :: proc(curve: Curve, t: f32) -> V2 {
	x := (1 - t) * (1 - t) * curve.B[0].x + 2 * (1 - t) * t * curve.B[1].x + t * t * curve.B[2].x
	y := (1 - t) * (1 - t) * curve.B[0].y + 2 * (1 - t) * t * curve.B[1].y + t * t * curve.B[2].y
	return { x, y }
}

// get the closest point on the bezier curve to the control point
quadratic_bezier_nearest_point :: proc(curve: Curve) -> f32 {
	v0 := curve.B[1] - curve.B[0]
	v1 := curve.B[2] - curve.B[1]

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