package src

import "core:math"

linear_solve :: proc(a, b: f32, r: ^[4]f32) -> int {
	if a == 0 {
		if b == 0 {
			// it has actually infinite solutions
			r[0] = 0
			return 1
		} else {
			return 0 // no solutions
		}
	} else {
		r[0] = -b/a
		return 1
	}
}

quadratic_solve :: proc(a, b, c: f32, delta: f32, r: ^[4]f32) -> int {
	if a == 0 {
		return linear_solve(b,c,r)
	}

	if delta < 0 {
		return 0
	}

	b := b

	if b > 0.0 {
		b /= 2.0
		q := b+math.sqrt(delta)
		r[0] = -c/q
		r[1] = -q/a
		return 2
	} else if b < 0.0 {
		b /= 2.0

		q := -b+math.sqrt(delta)
		r[0] = q/a
		r[1] = c/q
		return 2
	} else {
		q := math.sqrt(-a*c)
		if abs(a) >= abs(c) {
			r[0] = q/a
			r[1] = -q/a
		}	else {
			r[0] = -c/q
			r[1] = c/q
		}
		return 2
	}
}

quadratic_solve_simple :: proc(a, b, c: f32, r: ^[4]f32) -> int {
	return quadratic_solve(a, b, c, b*b/4-a*c, r)
}

chop_f32 :: proc(t: f32) -> f32 {
	if t < 0 && t > -1e-7 {
		return 0
	} else {
		return t
	}
}

chop_f64 :: proc(t: f64) -> f64 {
	if t < 0.0 && t > -1e-15 {
		return 0
	} else {
		return t
	}
}

chop :: proc { chop_f32, chop_f64 }

discriminant_f32 :: proc(a, b, c: f32) -> (value: f32, exponent: int) {
	_, ea := math.frexp(a)
	_, eb := math.frexp(b)
	_, ec := math.frexp(c)

	exponent = max(eb, (ea + ec) >> 2)
	s := math.ldexp(f32(1), -exponent)
	a := a * s
	b := b * s
	c := c * s
	// TODO infinite precision thingy
	// return chop_f32(math.fma(b, b, -a * c))
	value = b * b + (-a * c)
	return 
}

discriminant_f64 :: proc(a, b, c: f64) -> (value: f64, exponent: int) {
	_, ea := math.frexp(a)
	_, eb := math.frexp(b)
	_, ec := math.frexp(c)

	exponent = max(eb, (ea + ec) >> 2)
	s := math.ldexp(f64(1), -exponent)
	a := a * s
	b := b * s
	c := c * s

	// TODO infinite precision thingy
	value = b * b + (-a * c)
	return 
}

discriminant :: proc { discriminant_f32, discriminant_f64 }

quadratic_solve_f32 :: proc(a, b, c, delta: f32, e: int, t, s: ^[2]f32) -> int {
	if delta >= 0 {
		d := math.ldexp(f32(1), e) * math.sqrt(delta)

		if b > 0 {
			e := b + d
			t^ = { -c,  e }
			s^ = {  e, -a }
		} else if b < 0 {
			e := -b + d
			t^ = { e, c }
			s^ = { a, e }
		} else if abs(a) > abs(c) {
			t^ = { d, -d }
			s^ = { a,  a }
		} else {
			t^ = { -c, c }
			s^ = {  d, d }
		}

		return 2
	}

	return 0
}

quadratic_solve_f64 :: proc(a, b, c, delta: f64, e: int, t, s: ^[2]f64) -> int {
	if delta >= 0 {
		d := math.ldexp(f64(1), e) * math.sqrt(delta)

		if b > 0 {
			e := b + d
			t^ = { -c,  e }
			s^ = {  e, -a }
		} else if b < 0 {
			e := -b + d
			t^ = { e, c }
			s^ = { a, e }
		} else if abs(a) > abs(c) {
			t^ = { d, -d }
			s^ = { a,  a }
		} else {
			t^ = { -c, c }
			s^ = {  d, d }
		}

		return 2
	}

	return 0
}

quadratic_solve_simple_f32 :: proc(a, b, c: f32, t, s: ^[2]f32) -> int {
	delta, exponent := discriminant_f32(a, b, c)
	return quadratic_solve_f32(a, b, c, delta, exponent, t, s)
}

quadratic_solve_simple_f64 :: proc(a, b, c: f64, t, s: ^[2]f64) -> int {
	delta, exponent := discriminant_f64(a, b, c)
	return quadratic_solve_f64(a, b, c, delta, exponent, t, s)
}

_curoot :: proc(x: f32) -> (value: f32) {
	neg := 0
	absx := x

	if x < 0.0 {
		absx = -x
		neg = 1
	}

	if absx != 0.0 {
		value = math.exp(math.ln(absx)/3.0)
	} else {
		value = 0.0
	}

	if neg == 1 {
		value = -value
	}

	return value
}

_single_helper :: proc(tilde_a, bar_c, bar_d, D: f32) -> f32 {
	sqrt_D := math.sqrt(-D)
	
	p: f32
	if bar_d < 0 {
		p = _curoot(.5*(-bar_d+abs(tilde_a)*sqrt_D))
	} else {
		p = _curoot(.5*(-bar_d-abs(tilde_a)*sqrt_D))
	}

	return p - bar_c/p
}

_triple_helper :: proc(bar_c, bar_d, sqrt_D, s, r: f32) -> (x, o: f32) {
	theta := abs(math.atan2(s*sqrt_D, -bar_d))/3
	x1 := 2*math.sqrt(abs(bar_c))*math.cos(theta)
	x3 := 2*math.sqrt(abs(bar_c))*(-.5*math.cos(theta)-(math.sqrt(f32(3))/2)*math.sin(theta))
	if x1+x3 > 2.*r {
		x = x1
		o = x3
	} else {
		x = x3
		o = x1
	}
	return
}

cubic_solve :: proc(a, b, c, d: f32, r: ^[4]f32) -> int {
	if a == 0 {
		return quadratic_solve_simple(b, c, d, r)
	}

	b := b*(1 / 3)
	c := c*(1 / 3)
	d1 := a*c-b*b
	d2 := a*d-b*c
	d3 := b*d-c*c
	D := 4*d1*d3-d2*d2
	//fprintf(stderr, "D=%.10f\n", D)
	if D <= 0 {
		// triple root
		if d1 == 0 && d2 == 0 && d3 == 0 {
			if abs(a) > abs(b) {
				if abs(a) > abs(c) {
					r[0] = -b/a
					r[1] = -b/a
					r[2] = -b/a
				} else {
					r[0] = -d/c
					r[1] = -d/c
					r[2] = -d/c
				}
			} else if abs(b) > abs(c) {
				r[0] = -c/b
				r[1] = -c/b
				r[2] = -c/b
			}	else {
				r[0] = -d/c
				r[1] = -d/c
				r[2] = -d/c
			}
			return 3
		}

		if b*b*b*d >= a*c*c*c {
			bar_c := d1
			bar_d := -2*b*d1+a*d2
			r1 := _single_helper(a, bar_c, bar_d, D)
			r^ = (r1-b)/a
			// double root
			if D == 0 {
				r[1] = (-0.5*r1-b)/a
				r[2] = (-0.5*r1-b)/a
				return 3
			}	else {
				return 1
			}
		}	else {
			bar_c := d3
			bar_d := -d*d2+2*c*d3
			r1 := _single_helper(d, bar_c, bar_d, D)
			r^ = -d/(r1+c)
			// double root
			if D == 0 {
				r[1] = -d/(-0.5*r1+b)
				r[2] = -d/(-0.5*r1+b)
				return 3
			}	else {
				return 1
			}
		}
	}	else {
		sqrt_D := math.sqrt(D)
		bar_c_a := d1
		bar_d_a := -2*b*d1+a*d2
		xl, o := _triple_helper(bar_c_a, bar_d_a, sqrt_D, a, b)
		xl = xl - b
		wl := a
		bar_c_d := d3
		bar_d_d := -d*d2+2*c*d3
		xs: f32
		xs, o = _triple_helper(bar_c_d, bar_d_d, sqrt_D, d, c)
		ws := xs + c
		xs = -d
		e := wl*ws
		f := -xl*ws-wl*xs
		g := xl*xs
		xm := c*f-b*g
		wm := -b*f+c*e
		r[0] = xs/ws
		r[1] = xm/wm
		r[2] = xl/wl
		return 3
	}
}