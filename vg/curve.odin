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

	// sp: [3]V2
	// quadratic_slice(temp, 0, 0.5, &sp)
	// res1 = curve
	// res1.p[0] = sp[0]
	// res1.p[1] = sp[1]
	// res1.p[2] = sp[2]
	// quadratic_slice(temp, 0.5, 1, &sp)
	// res2 = curve
	// res2.p[0] = sp[0]
	// res2.p[1] = sp[1]
	// res2.p[2] = sp[2]
	// split = true

	return
}

curve_offset_quadratic3 :: proc(curve: Curve, out: ^Curve, offset: f32) {
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

	out^ = curve
	out.p[0] = p1
	cfinal, cok := line_intersection(p1, c1, p2, c2)
	out.p[1] = cok ? cfinal : 0
	out.p[2] = p2
	
	if offset < 0 {
		curve_invert(out)
	}
}

// split at T
curve_offset_quadratic2 :: proc(ctx: ^Context, curve: Curve, offset: f32) {
	out: [16]Curve
	out_index: int
	t := [?]f32 { 0, 0.2, 0.4, 0.6, 0.8, 1 }
	
	for i in 0..<len(t) - 1 {
		t0 := t[i]
		t1 := t[i + 1]
		
		sliced := quadratic_slice(curve, t0, t1)
		
		pos := &out[out_index]
		neg := &out[out_index + 1]
		out_index += 2

		curve_offset_quadratic3(sliced, pos, offset)
		curve_offset_quadratic3(sliced, neg, -offset)

		STROKE_LINE(ctx, curve_endpoint(neg^), pos.p[0])
		fa_push(&ctx.stroke_curves, pos^)
		STROKE_LINE(ctx, curve_endpoint(pos^), neg.p[0])
		fa_push(&ctx.stroke_curves, neg^)
	}	

	// a := quadratic_slice(curve, 0, 0.25)
	// b := quadratic_slice(curve, 0.25, 1)

	// {
	// 	out: [4]Curve
	// 	curve_offset_quadratic3(a, &out[0], offset)
	// 	curve_offset_quadratic3(a, &out[1], -offset)
	// 	STROKE_LINE(ctx, curve_endpoint(out[1]), out[0].p[0])
	// 	fa_push(&ctx.stroke_curves, out[0])
	// 	STROKE_LINE(ctx, curve_endpoint(out[0]), out[1].p[0])
	// 	fa_push(&ctx.stroke_curves, out[1])
	// }

	// {
	// 	out: [4]Curve
	// 	curve_offset_quadratic3(b, &out[0], offset)
	// 	curve_offset_quadratic3(b, &out[1], -offset)
	// 	STROKE_LINE(ctx, curve_endpoint(out[1]), out[0].p[0])
	// 	fa_push(&ctx.stroke_curves, out[0])
	// 	STROKE_LINE(ctx, curve_endpoint(out[0]), out[1].p[0])
	// 	fa_push(&ctx.stroke_curves, out[1])
	// }

	// split := v2_angle_between(v1, v2, true) > math.PI / 2
	// if !split {
	// 	temp := curve
	// 	temp.p[0] = p1
	// 	cfinal, cok := line_intersection(p1, c1, p2, c2)
	// 	temp.p[1] = cok ? cfinal : 0
	// 	temp.p[2] = p2
	// 	if invert {
	// 		curve_invert(&temp)
	// 	}
	// 	fa_push(&ctx.stroke_curves, temp)
	// } else {
	// 	t := quadratic_bezier_nearest_point(curve)
	// 	pt := quadratic_bezier_point(curve, t)
	// 	t1 := curve.p[0] * (1 - t) + curve.p[1] * t
	// 	t2 := curve.p[1] * (1 - t) + curve.p[2] * t
		
	// 	vt := v2_perpendicular(v2_normalize_to(t2 - t1, offset))
	// 	q := pt + vt
	// 	q1, _ := line_intersection(p1, c1, q, q + v2_perpendicular(vt))
	// 	q2, _ := line_intersection(c2, p2, q, q + v2_perpendicular(vt))

	// 	// Calculate the offset points by adding the offset vectors to the original curve points
	// 	res1 := curve
	// 	res1.p[0] = p1
	// 	res1.p[1] = q1
	// 	res1.p[2] = q

	// 	res2 := curve
	// 	res2.p[0] = q
	// 	res2.p[1] = q2
	// 	res2.p[2] = p2

	// 	if invert {
	// 		curve_invert(&res1)
	// 		curve_invert(&res2)
	// 	}

	// 	fa_push(&ctx.stroke_curves, res1)
	// 	fa_push(&ctx.stroke_curves, res2)
	// }


	// sp: [3]V2
	// quadratic_slice(temp, 0, 0.5, &sp)
	// res1 = curve
	// res1.p[0] = sp[0]
	// res1.p[1] = sp[1]
	// res1.p[2] = sp[2]
	// quadratic_slice(temp, 0.5, 1, &sp)
	// res2 = curve
	// res2.p[0] = sp[0]
	// res2.p[1] = sp[1]
	// res2.p[2] = sp[2]
	// split = true
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

curve_offset_cubic :: proc(curve: Curve, out: []Curve, offset: f32) -> (curve_count: int) {
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

	// t := [?]f32 { 0.25, 0.4, 0.6, 0.75 }
	t := [?]f32 { 0.5 }
	for i in 0..=len(t) {
		out[0] = curve
		out[0].p[0] = pstart
		out[0].p[1] = c1
		out[0].p[2] = c2
		out[0].p[3] = pend
	}

	curve_count = len(t) + 1

	// curve_count = 1
	// out[0] = curve
	// out[0].p[0] = pstart
	// out[0].p[1] = c1
	// out[0].p[2] = c2
	// out[0].p[3] = pend

	return
}

cubic_blossom :: proc(curve: Curve, u, v, w: f32) -> V2 {
	b10 := u*curve.p[1] + (1-u)*curve.p[0]
	b11 := u*curve.p[2] + (1-u)*curve.p[1]
	b12 := u*curve.p[3] + (1-u)*curve.p[2]
	b20 := v*b11 + (1-v)*b10
	b21 := v*b12 + (1-v)*b11
	b30 := w*b21 + (1-w)*b20
	return b30
}

cubic_slice :: proc(curve: Curve, s0, s1: f32, sp: ^[4]V2) {
	sp[0] = s0 == 0 ? curve.p[0] : cubic_blossom(curve, s0, s0, s0)
	sp[1] = cubic_blossom(curve, s0, s0, s1)
	sp[2] = cubic_blossom(curve, s0, s1, s1)
	sp[3] = s1 == 1 ? curve.p[3] : cubic_blossom(curve, s1, s1, s1)
}

quadratic_blossom :: proc(curve: Curve, u, v: f32) -> V2 {
	b10 := u*curve.p[1] + (1-u)*curve.p[0]
	b11 := u*curve.p[2] + (1-u)*curve.p[1]
	b20 := v*b11 + (1-v)*b10
	return b20
}

quadratic_slice :: proc(curve: Curve, s0, s1: f32) -> (res: Curve) {
	res = curve
	res.p[0] = (s0 == 0) ? curve.p[0] : quadratic_blossom(curve, s0, s0)
	res.p[1] = quadratic_blossom(curve, s0, s1)
	res.p[2] = (s1 == 1) ? curve.p[2] : quadratic_blossom(curve, s1, s1)
	return
}
