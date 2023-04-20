package src

import "core:math"

Curve :: struct {
	B: [4][2]f32,
	count: int, // 0-2 + 1
}

// Curve1 == Curve count = 0 + 1
// Curve2 == Curve count = 1 + 1
// Curve3 == Curve count = 2 + 1

Roots :: [MAX_ROOTS]f32
MAX_ROOTS :: 2 + 2 + 2 + 1

c1_make :: proc(a, b: [2]f32) -> (res: Curve) {
	c1_init(&res, a, b)
	return
}

c1_init :: proc(curve: ^Curve, a, b: [2]f32) {
	curve.B[0] = a
	curve.B[1] = b
	curve.count = 0
}

c1_eval :: proc(using curve: Curve, t: f32) -> [2]f32 {
	return (1-t)*B[0] + t*B[1]
}

c1_subcurve  :: proc(using curve: Curve, u, v: f32) -> (out: Curve) {
	out.count = curve.count
	out.B[0] = math.lerp(B[0], B[1], u)
	out.B[1] = math.lerp(B[0], B[1], v)
	return
}

c2_make :: proc(a, b, c: [2]f32) -> (res: Curve) {
	c2_init(&res, a, b, c)
	return
}

c2_init :: proc(curve: ^Curve, a, b, c: [2]f32) {
	curve.B[0] = a
	curve.B[1] = b
	curve.B[2] = c
	curve.count = 1
}

c2_eval :: proc(using curve: Curve, t: f32) -> [2]f32 {
	return math.lerp(math.lerp(B[0],B[1],t), math.lerp(B[1],B[2],t), t);
}

c2_blossom :: proc(using curve: Curve, u, v: f32) -> [2]f32 {
	return B[0]*(u*v - u - v+1) + B[1]*(u + v - 2*u*v) + B[2]*(u*v)
}

c2_subcurve :: proc(using seg: Curve, u, v: f32) -> (out: Curve) {
	out.count = seg.count

	if u == 0 {
		out.B[0] = B[0]
		out.B[1] = c2_blossom(seg, u, v)
		out.B[2] = c2_blossom(seg, v, v)
	} else if(v == 1) {
		out.B[0] = c2_blossom(seg, u, u)
		out.B[1] = c2_blossom(seg, u, v)
		out.B[2] = B[2]
	} else {
		out.B[0] = c2_blossom(seg, u, u)
		out.B[1] = c2_blossom(seg, u, v)
		out.B[2] = c2_blossom(seg, v, v)
	}

	return
}

c2_calc_roots :: proc(using curve: Curve, roots: ^Roots) -> (nroots: int) {
	update :: proc(roots: ^Roots, nroots: ^int, a, b: f32) {
		// is already monotonic?  ( ! (0 < -B/A < 1) )
		if math.signbit(a) != math.signbit(b) && b!=0 && abs(b) < abs(a) {
			roots[nroots^] = -b/a
			nroots^ += 1
		}
	}

	a := B[0] - 2*B[1] + B[2]
	b := B[1] - B[0]

	update(roots, &nroots, a.x, b.x)
	update(roots, &nroots, a.y, b.y)

	return
}

c3_make :: proc(a, b, c, d: [2]f32) -> (res: Curve) {
	c3_init(&res, a, b, c, d)
	return
}

c3_init :: proc(curve: ^Curve, a, b, c, d: [2]f32) {
	curve.B[0] = a
	curve.B[1] = b
	curve.B[2] = c
	curve.B[3] = d
	curve.count = 2
}

c3_eval :: proc(using curve: Curve, t: f32) -> [2]f32 {
	temp: Curve
	c2_init(
		&temp,
		math.lerp(B[0], B[1], t),
		math.lerp(B[1], B[2], t),
		math.lerp(B[2], B[3], t),
	)
	return c2_eval(temp, t)
}

c3_blossom :: proc(using curve: Curve, u, v, w: f32) -> [2]f32 {
	return B[0]*(-u*v*w + v*w + u*w + u*v - (v + u + w) + 1) +
		B[1]*(3*u*v*w - 2*(v*w + u*w + u*v) + u + v + w) +
		B[2]*(-3*u*v*w + v*w + u*w + u*v) +
		B[3]*(u*v*w);
}

c3_subcurve :: proc(using curve: Curve, u, v: f32) -> (out: Curve) {
	out.count = curve.count

	if u == 0 {
		out.B[0] = B[0]
		out.B[1] = c3_blossom(curve,u,u,v)
		out.B[2] = c3_blossom(curve,u,v,v)
		out.B[3] = c3_blossom(curve,v,v,v)
	}	else if v == 1 {
		out.B[0] = c3_blossom(curve,u,u,u)
		out.B[1] = c3_blossom(curve,u,u,v)
		out.B[2] = c3_blossom(curve,u,v,v)
		out.B[3] = B[3]
	} else {
		out.B[0] = c3_blossom(curve,u,u,u)
		out.B[1] = c3_blossom(curve,u,u,v)
		out.B[2] = c3_blossom(curve,u,v,v)
		out.B[3] = c3_blossom(curve,v,v,v)
	}

	return
}

c3_calc_roots :: proc(using curve: Curve, roots: ^Roots) -> (nroots: int) {
	update :: proc(roots: ^Roots, nroots: ^int, a, b, c: f32) {
		t: [4]f32
		n := quadratic_solve_simple(a, b, c, &t)

		if n==2 {
			// compare negating condition to avoid having to compare against NaN

			if !(0 < t[0] && t[0] < 1) {
				t[0] = t[1]
				n = 1
			} else if !(0 < t[1] && t[1] < 1) {
				n = 1
			}
		}

		switch n {
		case 1:
			if(0 < t[0] && t[0] < 1) {
				roots[nroots^] = t[0]
				nroots^ += 1
			}
		case 2:
			roots[nroots^] = t[0]
			nroots^ += 1
			roots[nroots^] = t[1]
			nroots^ += 1
		}
	}

	a := 3*(-B[0] + 3*B[1] - 3*B[2] + B[3])
	b := 6*(B[0] - 2*B[1] + B[2])
	c := 3*(-B[0] + B[1])

	update(roots, &nroots, a.x, b.x, c.x)
	update(roots, &nroots, a.y, b.y, c.y)

	return
}

curve_get_xy_mono_box :: proc(curve: Curve) -> (res: Box) {
	first := curve.B[0]
	last := curve.B[curve.count + 1]

	if first.x < last.x {
		res.x = first.x
		res.z = last.x
	} else {
		res.x = last.x
		res.z = first.x
	}

	if first.y < last.y {
		res.y = first.y
		res.w = last.y
	} else {
		res.y = last.y
		res.w = first.y
	}

	return
}
