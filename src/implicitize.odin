package src

import "core:fmt"
import "core:math"
import "core:math/linalg"
import glm "core:math/linalg/glsl"

c1_implicitize :: proc(using curve: Curve) -> (res: Implicit_Curve) {
	res.kind = .LINE
	res.box = curve_get_xy_mono_box(curve)

	going_right := B[0].x < B[1].x
	going_up := B[0].y < B[1].y

	// res.orientation = orientation_get(going_right, going_up)
	res.orientation = going_up == going_right ? .BR : .TR
	res.going_up = b32(going_up)
	res.winding_increment = going_up ? 1 : -1
	return
}

create_quad_matrix :: proc(p0, p1, p2: [2]f32) -> (m: glm.mat4) {
	a := p0.x
	b := p0.y
	c := p1.x
	d := p1.y
	e := p2.x
	f := p2.y
	det_inv := 1/(-b*c + a*d + b*e - d*e - a*f + c*f)
	//{{(b - d)/det + (-b + f)/(2 det), (-a + c)/det + (a - e)/(2 det), 0},
	//{(b - d)/det, (-a + c)/det, 0}} 
	// m = glm.identity(glm.mat4)
	m[0][0] = det_inv*(b-d) + det_inv*(-b+f)/2
	m[0][1] = det_inv*(-a+c) + det_inv*(a-e)/2
	m[1][0] = det_inv*(b-d)
	m[1][1] = det_inv*(-a+c)
	return
}

c2_implicitize :: proc(using curve: Curve, t0, t1: f32) -> (res: Implicit_Curve) {
	res.kind = .QUADRATIC
	res.box = curve_get_xy_mono_box(curve)

	going_right := B[0].x < B[2].x
	going_up := B[0].y < B[2].y
	res.orientation = orientation_get(going_right, going_up)
	res.going_up = b32(going_up)
	res.winding_increment = going_up ? 1 : -1
	// fmt.eprintln("QUAD", res.orientation)

	// by definition the set { (x,y) f(x,y) < 0 } is the convex subset defined
	// by the quadratic. Assuming that we are dealing with monotonic segments,
	// we can use ccw to find if c is to the left(counterclockwise) of be.  We
	// have two possibles situations: b.y < e.y and othewise.  On the first
	// case, ccw(c,b,e) < 0 implies that c is to the left of be (the segment
	// be) wich implies that the set f<0 is to the right of be. We should then,
	// change sign to -1.
	b := B[0]
	c := B[1]
	e := B[2]

	// if res.orientation == .TL {
	// 	res.negative = true
	// }

	res.M = create_quad_matrix(b, c, e)
	return
}

// TYPE3

Cubic_Type :: enum {
	UNKOWN,
	SERPENTINE,
	LOOP,
	CUSP_AT_INFINITY,
	QUADRATIC,
	LINE,
	POINT,
}

// TODO
// TODO REFACTOR all array accessors here 
// TODO

c3_coeficients_matrix :: proc(using curve: Curve) -> (m: glm.mat3) #no_bounds_check {
	a := B[0].x
	b := B[0].y
	c := B[1].x
	d := B[1].y
	e := B[2].x
	f := B[2].y
	g := B[3].x
	h := B[3].y

	m = glm.identity(glm.mat3)
	m[0][0] =              a; m[0][1] =           b; m[0][2] = 1
	m[1][0] =       -3*(a-c); m[1][1] =    -3*(b-d); m[1][2] = 0
	m[2][0] =    3*(a-2*c+e); m[2][1] = 3*(b-2*d+f); m[2][2] = 0
	m[3][0] =    g+3*(c-e)-a; m[3][1] = h+3*(d-f)-b; m[3][2] = 0
	return
}

find_discriminant_coeficients :: proc(m: glm.mat3) -> (dc: [4]f32) #no_bounds_check {
	c := m[1][0]
	d := m[1][1]
	e := m[2][0]
	f := m[2][1]
	g := m[3][0]
	h := m[3][1]

	dc[1] = f*g - e*h
	dc[2] = c*h - d*g
	dc[3] = d*e - c*f
	return
}

find_serpentine_matrix :: proc(
	d: [4]f32,
	tmtl: [4]f32, // only 2 used
) -> (m: glm.mat4, ts: [2][2]f32) #no_bounds_check {
	tl := tmtl[1]
	sl := 2*d[1]

	inv_norm := 1 / math.sqrt(tl*tl + sl*sl)
	tl *= inv_norm
	sl *= inv_norm

	tm := tmtl[0]
	sm := 2*d[1]

	inv_norm = 1 / math.sqrt(tm*tm + sm*sm)
	tm *= inv_norm
	sm *= inv_norm

	// now assemble the matrix
	// {
	// {tl*tm, tl^3, tm^3, 1},
	// {-sm*tl - sl*tm, -3 sl*tl^2, -3*sm*tm^2, 0},
	// {sl*sm, 3 sl^2 tl, 3 sm^2 tm, 0},
	// {0, -sl^3, -sm^3, 0}
	// }
	//
	m = glm.identity(glm.mat4)
	m[0][0] =        tl*tm; m[0][1] =    tl*tl*tl; m[0][2] =    tm*tm*tm; m[0][3] = 1
	m[1][0] = -sm*tl-sl*tm; m[1][1] = -3*sl*tl*tl; m[1][2] = -3*sm*tm*tm; m[1][3] = 0
	m[2][0] =        sl*sm; m[2][1] =  3*sl*sl*tl; m[2][2] =  3*sm*sm*tm; m[2][3] = 0
	m[3][0] =            0; m[3][1] =   -sl*sl*sl; m[3][2] =   -sm*sm*sm; m[3][3] = 0

	// save the roots for later (tl,sl) and (tm,sm)
	ts[0] = { tl, sl }
	ts[1] = { tm, sm }
	// other inflection points:
	// tn == 1, sn == 0
	return
}

find_loop_matrix :: proc(
	d: [4]f32,
	tetd: [4]f32, // only 2 used
) -> (m: glm.mat4, ts: [2][2]f32) #no_bounds_check {
	td := tetd[1]
	sd := 2*d[1]

	inv_norm := 1 / math.sqrt(td*td + sd*sd)
	td *= inv_norm
	sd *= inv_norm

	te := tetd[0]
	se := 2*d[1]

	inv_norm = 1 / math.sqrt(te*te + se*se)
	te *= inv_norm
	se *= inv_norm

	// assemble the matrix
	// {
	// {td*te, td^2 te, td te^2, 1},
	// {-se*td - sd*te, -se*td^2 - 2 sd te td, -sd te^2 - 2 se td te, 0},
	// {sd*se, te sd^2 + 2 se td sd, td se^2 + 2 sd te se, 0},
	// {0, -sd^2 se, -sd se^2, 0}
	// }
	m = glm.identity(glm.mat4)
	m[0][0] =        td*te; m[0][1] =             td*td*te; m[0][2] =             td*te*te; m[0][3] = 1
	m[1][0] = -se*td-sd*te; m[1][1] = -se*td*td-2*sd*te*td; m[1][2] = -sd*te*te-2*se*td*te; m[1][3] = 0
	m[2][0] =        sd*se; m[2][1] =  te*sd*sd+2*se*td*sd; m[2][2] =  td*se*se+2*sd*te*se; m[2][3] = 0
	m[3][0] =            0; m[3][1] =            -sd*sd*se; m[3][2] =            -sd*se*se; m[3][3] = 0

	// save the roots for later (td,sd) and (te,se)
	ts[0] = { td, sd }
	ts[1] = { te, se }

	return
}

find_cusp_at_infinity_matrix :: proc(d: [4]f32) -> (m: glm.mat4, ts: [2][2]f32) #no_bounds_check {
	// compute and normalize the pair (tl, sl)
	tl := d[3]
	sl := 3*d[2]
	inv_norm := 1 / math.sqrt(tl*tl + sl*sl)
	tl *= inv_norm
	sl *= inv_norm

	// assemble the matrix
	// {
	// {tl, tl^3, 1,1},
	// {-sl,-3sl tl^2, 0,0},
	// {0, 3sl^2 tl, 0,0},
	// {0,-sl^3,0,0}
	// }
	m = glm.identity(glm.mat4)
	m[0][0] =  tl; m[0][1] =    tl*tl*tl; m[0][2] = 1; m[0][3] = 1
	m[1][0] = -sl; m[1][1] = -3*sl*tl*tl; m[1][2] = 0; m[1][3] = 0
	m[2][0] =   0; m[2][1] =  3*sl*sl*tl; m[2][2] = 0; m[2][3] = 0
	m[3][0] =   0; m[3][1] =   -sl*sl*sl; m[3][2] = 0; m[3][3] = 0

	// save the roots for later (tl,sl)
	ts[0] = { tl, sl }
	ts[1] = { 2, 1 } // won't be used, enough to skip root creation
	// other inflection points are:
	// tm == 1, sm == 0
	// tn == 1, sn == 0
	return
}

premultiply_f_by_m3_inverse :: proc(fm: glm.mat4) -> (m: glm.mat4) #no_bounds_check {
	a := fm[0][0]
	b := fm[0][1]
	c := fm[0][2] // skip 0,3
	d := fm[1][0]
	e := fm[1][1]
	f := fm[1][2] // skip 1,3
	g := fm[2][0]
	h := fm[2][1]
	i := fm[2][2] // skip 2,3
	j := fm[3][1]
	k := fm[3][2] // skip 3,0 and 3,3

	//{
	//{a,b,c,1},
	//{a+d/3,b+e/3,c+f/3,1},
	//{a+(2 d)/3+g/3,b+(2 e)/3+h/3,c+(2 f)/3+i/3,1},
	//{a+d+g,b+e+h+j,c+f+i+k,1}
	//}
	m = glm.identity(glm.mat4)
	m[0][0] =           a; m[0][1] =           b; m[0][2] =           c; m[0][3] = 1
	m[1][0] =       a+d/3; m[1][1] =       b+e/3; m[1][2] =       c+f/3; m[1][3] = 1
	m[2][0] = a+2*d/3+g/3; m[2][1] = b+2*e/3+h/3; m[2][2] = c+2*f/3+i/3; m[2][3] = 1
	m[3][0] =       a+d+g; m[3][1] =     b+e+h+j; m[3][2] =     c+f+i+k; m[3][3] = 1
	return
}

c3_cubic_find_degenerated_as_quadratic_matrix :: proc(using curve: Curve) -> (f: glm.mat4) {
	// since we have a quadratic, we begin by finding its control points.
	// the beggining and ending points are the same
	b := B[0]
	c1 := B[1]
	c2 := B[2]
	e := B[3]
	
	// we find the control point c for the quadratic
	c := 0.25*( -b + 3*c1 + 3*c2 - e )
	// linear interpolation for c1
	t1 := length(c1-b)/length(c-b)
	// linear interpolation for c2
	t2 := length(c2-e)/length(c-e)
	
	// the first line of f contains the coefficients for
	// the point b.
	f[0][0] = 0; f[0][1] = 0; f[0][2] = 0; f[0][3] = 1;
	// the second and third lines are the coefficients for
	// the control points c1 and c2. c1 is in the b->c line,
	// (1-t1)*{ 0, 0, 0, 1 } + t1*{ 0.5, 0, 0.5, 1 }
	f[1][0] = 0.5*t1; f[1][1] = 0; f[1][2] = 0.5*t1; f[1][3] = 1;
	// c2 is in the e->c line
	// (1-t2)*{1, 1, 1, 1} * t2*{ 0.5, 0, 0.5, 1 }
	tmp1 := (1-t2)*1 + t2*0.5
	tmp2 := (1-t2)*1
	f[2][0] = tmp1; f[2][1] = tmp2; f[2][2] = tmp1; f[2][3] = 1;
	// coefficients for e
	f[3][0] = 1; f[3][1] = 1; f[3][2] = 1; f[3][3] = 1;
	return
}

c3_classify :: proc(using curve: Curve) -> (
	m: glm.mat4, 
	ts: [2][2]f32,
	d: [4]f32,
	type: Cubic_Type,
)	{
	cm := c3_coeficients_matrix(curve)
	d = find_discriminant_coeficients(cm)
	f: glm.mat4

	if abs(d[1]) > 1e-6 {
		// I've decided to change the original quadraticsolve to receive
		// the delta var as a argument. The reason is that the next two
		// quadratic have the same delta, except for a constant multiplication.
		// That is: delta_serp = -1/3 * delta_loop.
		// Calculating the deltas using the A,B and C coeficients from the
		// respective equations gives disagreeing results such as both deltas < 0.
		// The first equation is: t^2 -2*d2 + (4/3)*d1*d3,
		// the second is: t^2 - 2*d2 + 4*(d2^2 -d1*d3).
		// Using Blinn's convention we have delta = b*b - a*c,
		// where b = B/2.

		delta := 3*d[2]*d[2] - 4*d[1]*d[3]
		if delta >= 0 {
			tmtl: [4]f32
			n := quadratic_solve(1, -2*d[2], (4/3)*d[1]*d[3], (1/3)*delta, &tmtl)

			if tmtl[0] > tmtl[1] {
				tmtl[0], tmtl[1] = tmtl[1], tmtl[0]
			}

			// serpentine and cusp with inflection at infinity
			f, ts = find_serpentine_matrix(d, tmtl)
			type = .SERPENTINE
		} else {
			// loop
			tetd: [4]f32
			quadratic_solve(1, -2*d[2], 4*(d[2]*d[2] - d[1]*d[3]), -delta, &tetd)
			
			if tetd[0] > tetd[1] {
				tetd[0], tetd[1] = tetd[1], tetd[0]
			}

			f, ts = find_loop_matrix(d, tetd)
			type = .LOOP
		}
		
		m = premultiply_f_by_m3_inverse(f)
	} else {
		if d[2] != 0 {
			f, ts := find_cusp_at_infinity_matrix(d)
			type = .CUSP_AT_INFINITY
			m = premultiply_f_by_m3_inverse(f)
		} else if d[3] != 0 {
			m = c3_cubic_find_degenerated_as_quadratic_matrix(curve)
			type = .QUADRATIC
		} else {
			f = glm.identity(glm.mat4)

			if (B[0] == B[1] && B[1] == B[3]) || (B[0] == B[2] && B[2] == B[3]) {
				type = .POINT
			} else {
				type = .LINE
			}
		}
	}

	return
}

sqrnorm :: proc(a: [2]f32) -> f32 {
	return linalg.vector_dot(a, a)
}

c3_cubic_find_end :: proc(using curve: Curve) -> [2]f32 {
	a11 := B[1].x - B[0].x
	a12 := B[3].x - B[2].x
	a21 := B[1].y - B[0].y
	a22 := B[3].y - B[2].y
	det := a11*a22 - a12*a21
	//TODO: find a better constant
	alpha: f32
	if abs(det) < 1e-3 {
		// A==B(and C!=D) or C==D(and A!=B).
		alpha = 1
		if sqrnorm(B[0]-B[1]) < sqrnorm(B[2]-B[3]) {
			// A == B
			return B[2]
		} else {
			// C==D
			return B[1]
		}
	}
	
	b1 := B[3].x - B[0].x
	b2 := B[3].y - B[0].y
	/* solve the system
	 * | a11 a12 ||alpha|   | b1 |
	 * | a21 a22 || beta| = | b2 | */
	alpha = - (a22*b1 - a12*b2)/(a12*a21 - a11*a22)
	return (1-alpha)*B[0] + alpha * B[1]
}

cubic_determinant :: proc(p0, p1, p2: [2]f32) -> f32 {
	a := p0.x
	b := p1.x
	c := p2.x
	d := p0.y
	e := p1.y
	f := p2.y
	return -b*d + c*d + a*e - c*e - a*f + b*f
}

create_baricentric_matrix :: proc(p0, p1, p2: [2]f32) -> (m: glm.mat4) {
	a := p0.x
	b := p1.x
	c := p2.x
	d := p0.y
	e := p1.y
	f := p2.y
	m = glm.identity(glm.mat4)

	// from Mathematica:
	// { {(e-f)/(-b d+c d+a e-c e-a f+b f),(-b+c)/(-b d+c d+a e-c e-a f+b f),(-c e+b f)/(-b d+c d+a e-c e-a f+b f)},
	//   {(-d+f)/(-b d+c d+a e-c e-a f+b f),(a-c)/(-b d+c d+a e-c e-a f+b f),(c d-a f)/(-b d+c d+a e-c e-a f+b f)},
	//   {(d-e)/(-b d+c d+a e-c e-a f+b f),(-a+b)/(-b d+c d+a e-c e-a f+b f),(-b d+a e)/(-b d+c d+a e-c e-a f+b f)}}
	den := 1/(-b*d + c*d + a*e - c*e - a*f + b*f)
	m[0][0] = (e-f)*den; m[0][1] = (c-b)*den; m[0][2] = (b*f-c*e)*den
	m[1][0] = (f-d)*den; m[1][1] = (a-c)*den; m[1][2] = (c*d-a*f)*den
	m[2][0] = (d-e)*den; m[2][1] = (b-a)*den; m[2][2] = (a*e-b*d)*den
	return
}

Implicizitation_Context :: struct {
	M: glm.mat4,
	d: [4]f32,
	base: [2]f32,
	cubic_type: Cubic_Type,
}

find_klm_matrix_and_transpose :: proc(cm: glm.mat4, klm_matrix: ^glm.mat4, i, j, k: int) {
	// copy line i from cm into col 0 of klm_matrix
	for l:=0; l<3; l += 1 {
		klm_matrix[l][0] = cm[i][l]
	}
	// copy line j from cm into col 1 of klm_matrix
	for l:=0; l<3; l += 1 {
		klm_matrix[l][1] = cm[j][l]
	}
	// copy line k from cm into col 2 of klm_matrix
	for l:=0; l<3; l += 1 {
		klm_matrix[l][2] = cm[k][l]
	}
}

c3_classify_with_ctx :: proc(
	using curve: Curve, 
	ctx: ^Implicizitation_Context,
) -> (
	ts: [2][2]f32,
	cubic_type: Cubic_Type,
) {
	im: glm.mat4
	bm: glm.mat4
	klm_matrix: glm.mat4

	b := B[0]
	c1 := B[1]
	c2 := B[2]
	e := B[3]

	im, ts, ctx.d, cubic_type = c3_classify(curve)

	// now im contains the matrix with the coefficients for the cubic,
	// the first line for b, the second for c1, third for c2 and the
	// fourth for e.
	// Now we find wich subset of the control points (b, c1, c2, e)
	// forms the better triangle
	//
	// if b!=e we choose between c1 and c2. This may not be the optimal
	// choice because b and e may be close to each other.
	// TODO: find a better constant
	if length(b-e) > 1e-5 {
		v1 := cubic_determinant(b, c1, e)
		v2 := cubic_determinant(b, c2, e)
		if abs(v1) > abs(v2) {
			ctx.base = c1
			bm = create_baricentric_matrix(b-c1, c1-c1, e-c1)
			find_klm_matrix_and_transpose(im, &klm_matrix, 0, 1, 3)
		}	else {
			ctx.base = c2
			bm = create_baricentric_matrix(b-c2, c2-c2, e-c2)
			find_klm_matrix_and_transpose(im, &klm_matrix, 0, 2, 3)
		}
	} else {
		v1 := cubic_determinant(b, c1, c2)
		v2 := cubic_determinant(e, c1, c2)
		if abs(v1) > abs(v2) {
			ctx.base = c1
			bm = create_baricentric_matrix(b-c1, c1-c1, c2-c1)
			find_klm_matrix_and_transpose(im, &klm_matrix, 0, 1, 2)
		}	else {
			ctx.base = c1;
			bm = create_baricentric_matrix(e-c1, c1-c1, c2-c1)
			find_klm_matrix_and_transpose(im, &klm_matrix, 3, 1, 2)
		}
	}

	// multiply the klm_matrix by the baricentric transformation
	// this way we will have:
	// [k l m]^t = K*B[x y 1]^t, where K is klm_matrix and B is bm.
	// B will transform the vector [x y 1]^t into [a b c]^t which are
	// the baricentric coodinates relatives to the triagle chosen above.
	// K*[a b c]^t will make a convex combination of the K columns (given
	// by the 2005 paper) resulting in the desired values for [k l m]^t.

	ctx.M = klm_matrix * bm
	return
}

c3_implicitize :: proc(
	using curve: Curve, 
	t0, t1: f32, 
	ctx: ^Implicizitation_Context,
) -> (res: Implicit_Curve) {
	res.kind = .CUBIC
	res.box = curve_get_xy_mono_box(curve)

	going_right := B[0].x < B[3].x
	going_up := B[0].y < B[3].y
	res.orientation = orientation_get(going_right, going_up)
	res.going_up = b32(going_up)
	res.winding_increment = going_up ? 1 : -1

	res.M = ctx.M
	res.base = ctx.base
	res.E = c3_cubic_find_end(curve)

	// find the sign
	if ctx.cubic_type == .LOOP {
		// for loops we need to find the sign for each segment :-/
		// we compare the values of H(t/s,1) at each point of the
		// segment. see Loop and Blin 2005, section 4.4 The loop, last
		// paragraph.

		d := ctx.d

		h0 := d[3]*d[1] - d[2]*d[2] + d[1]*d[2]*t0 - d[1]*d[1]*t0*t0
		h1 := d[3]*d[1] - d[2]*d[2] + d[1]*d[2]*t1 - d[1]*d[1]*t1*t1
		if abs(h0) > abs(h1) {
			if ctx.d[1]*h0 > 0 {
				res.negative = true
			}
		}else {
			if ctx.d[1]*h1 > 0 {
				res.negative = true
			}
		}
	} else if ctx.cubic_type == .SERPENTINE {
	// we must flip the sign if d[1] < 0
		if ctx.d[1] < 0 {
			res.negative = true
		}
	}

	// now we need to find the correct sign.
	// what we have, from the code above,
	// is the value of sign as defined by the paper
	// Loop and Blinn 2005 section 4.3 paragraph 6,
	// with the negative values to the right of the
	// direction of parametric travel.
	// We want the negative values to be at the left
	// side of the *curve*. For that we need the curve
	// to be monotonic.
	// If it's going up then we need to change the sign
	if going_up {
		// flip negative bit
		res.negative = !res.negative
	}

	return
}
