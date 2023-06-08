package vg

import "core:os"
import "core:fmt"
import "core:mem"
import "core:math"
import "core:slice"
import "core:runtime"
import "core:prof/spall"

KAPPA90 :: 0.5522847493

MAX_STATES :: 32
MAX_TEMP_PATHS :: 1028
MAX_TEMP_CURVES :: 1028 * 4

Paint :: struct {
	xform: Xform,
	inner_color: [4]f32,
	outer_color: [4]f32,
}

Line_Cap :: enum {
	Butt, // default
	Square,
}

Line_Join :: enum {
	Miter, // default
	Bevel,
}

State :: struct {
	fill: Paint,
	stroke: Paint,
	stroke_width: f32,
	line_join: Line_Join,
	line_cap: Line_Cap,
	miter_limit: f32,
	alpha: f32,
	xform: Xform,

	font_size: f32,
	font_id: u32,
	letter_spacing: f32,
	line_height: f32,
	ah: Align_Horizontal,
	av: Align_Vertical,
}

Xform :: [6]f32

Context :: struct {
	// temp data for building paths, can be copied over
	temp_curves: Fixed_Array(Curve),
	temp_paths: Fixed_Array(Path),
	stroke_curves: Fixed_Array(Curve), // stroke creation of curves from above,
	stroke_last: V2, // temp point for building lines
	stroke_path_index: i32,

	// float commands for less allocation
	point_last: V2, // saved last

	// state stored 
	states: Fixed_Array(State),

	// font data
	font_pool: Pool(8, Font),

	// renderer 
	renderer: Renderer,

	// quality options?
	distance_tolerance: f32,
	tesselation_tolerance: f32,
	device_pixel_ratio: f32,

	// window data
	window_width: f32,
	window_height: f32,

	// profiling
	spall_ctx: spall.Context,
	spall_buffer: spall.Buffer,
	spall_data: []byte,

	stroke_joints: bool,

	// building cubic curves
	cubic_pos: Fixed_Array(Curve),
	cubic_neg: Fixed_Array(Curve),
}

WINDING_CW :: 0
WINDING_CCW :: 1

CURVE_LINE :: 0
CURVE_QUADRATIC :: 1
CURVE_CUBIC :: 2

ctx_device_pixel_ratio :: proc(ctx: ^Context, ratio: f32) {
	ctx.tesselation_tolerance = 0.25 / ratio
	ctx.distance_tolerance = 0.01 / ratio
	ctx.device_pixel_ratio = ratio
}

ctx_init :: proc(ctx: ^Context) {
	ctx.spall_ctx = spall.context_create_with_scale("prof.spall", false, 1)
	ctx.spall_data = make([]byte, mem.Megabyte)
	ctx.spall_buffer = spall.buffer_create(ctx.spall_data, 0, 0)

	spall.SCOPED_EVENT(&ctx.spall_ctx, &ctx.spall_buffer, "ctx init")

	fa_init(&ctx.temp_curves, MAX_TEMP_CURVES)
	fa_init(&ctx.stroke_curves, MAX_TEMP_CURVES)
	fa_init(&ctx.temp_paths, MAX_TEMP_PATHS)
	fa_init(&ctx.states, MAX_STATES)

	fa_init(&ctx.cubic_pos, 64)
	fa_init(&ctx.cubic_neg, 64)

	save(ctx)
	reset(ctx)
	ctx_device_pixel_ratio(ctx, 1)

	pool_clear(&ctx.font_pool)
	renderer_init(&ctx.renderer)

	ctx.stroke_joints = true
}

ctx_make :: proc() -> (res: Context) {
	ctx_init(&res)
	return
}

ctx_destroy :: proc(ctx: ^Context) {
	{
		spall.SCOPED_EVENT(&ctx.spall_ctx, &ctx.spall_buffer, "ctx destroy")
		renderer_destroy(&ctx.renderer)
		fa_destroy(ctx.temp_paths)
		fa_destroy(ctx.temp_curves)
		fa_destroy(ctx.stroke_curves)
		fa_destroy(ctx.states)

		fa_destroy(ctx.cubic_pos)
		fa_destroy(ctx.cubic_neg)
	}

	spall.buffer_destroy(&ctx.spall_ctx, &ctx.spall_buffer)
	spall.context_destroy(&ctx.spall_ctx)
	delete(ctx.spall_data)
}

ctx_frame_begin :: proc(ctx: ^Context, width, height: int, device_pixel_ratio: f32) {
	spall.SCOPED_EVENT(&ctx.spall_ctx, &ctx.spall_buffer, "frame_begin")
	fa_clear(&ctx.states)
	ctx.window_width = f32(width)
	ctx.window_height = f32(height)
	save(ctx)
	reset(ctx)
	ctx_device_pixel_ratio(ctx, device_pixel_ratio)
	renderer_begin(&ctx.renderer, width, height)
}

ctx_frame_end :: proc(ctx: ^Context) {
	spall.SCOPED_EVENT(&ctx.spall_ctx, &ctx.spall_buffer, "frame end")
	renderer_end(&ctx.renderer)
}

save :: proc(ctx: ^Context) {
	if ctx.states.index >= MAX_STATES {
		return
	}

	// copy prior
	if ctx.states.index > 0 {
		ctx.states.data[ctx.states.index] = ctx.states.data[ctx.states.index - 1]
	}

	ctx.states.index += 1
}

restore :: proc(ctx: ^Context) {
	if ctx.states.index <= 1 {
		return
	}

	ctx.states.index -= 1
}

@(deferred_in=restore)
save_scoped :: #force_inline proc(ctx: ^Context) {
	save(ctx)
}

global_alpha :: proc(ctx: ^Context, alpha: f32) {
	state := state_get(ctx)
	state.alpha = alpha
}

@private
paint_set_color :: proc(p: ^Paint, color: [4]f32) {
	p^ = {}
	xform_identity(&p.xform)
	p.inner_color = color
	p.outer_color = color
}

reset :: proc(ctx: ^Context) {
	state := state_get(ctx)
	state^ = {}

	paint_set_color(&state.fill, { 1, 0, 0, 1 })
	paint_set_color(&state.stroke, { 0, 0, 0, 1 })

	state.stroke_width = 5
	state.miter_limit = 10
	state.line_cap = .Butt
	state.line_join = .Miter
	state.alpha = 1
	xform_identity(&state.xform)

	// font sets
	state.font_id = Pool_Invalid_Slot_Index
	state.font_size = 16
	state.letter_spacing = 0
	state.line_height = 1
}

@private
state_get :: proc(ctx: ^Context) -> ^State #no_bounds_check {
	return &ctx.states.data[ctx.states.index - 1]
}

stroke_width :: proc(ctx: ^Context, value: f32) {
	state := state_get(ctx)
	state.stroke_width = value
}

fill_color :: proc(ctx: ^Context, color: [4]f32) {
	state := state_get(ctx)
	paint_set_color(&state.fill, color)
}

stroke_color :: proc(ctx: ^Context, color: [4]f32) {
	state := state_get(ctx)
	paint_set_color(&state.stroke, color)
}

line_join :: proc(ctx: ^Context, join: Line_Join) {
	state := state_get(ctx)
	state.line_join = join
}

line_cap :: proc(ctx: ^Context, cap: Line_Cap) {
	state := state_get(ctx)
	state.line_cap = cap
}

// set scissor region to current path
scissor :: proc(ctx: ^Context, x, y, w, h: f32) {
	if ctx.temp_paths.index > 0 {
		path := fa_last_unsafe(&ctx.temp_paths)
		// TODO maybe intersect by window?
		path.clip = { x, y, w, h }
	}
}

///////////////////////////////////////////////////////////
// Commands
///////////////////////////////////////////////////////////

path_begin :: proc(ctx: ^Context) {
	fa_clear(&ctx.temp_curves)
	fa_clear(&ctx.temp_paths)
	fa_clear(&ctx.stroke_curves)
	fa_clear(&ctx.cubic_pos)
	fa_clear(&ctx.cubic_neg)
	ctx.point_last = {}
	ctx.stroke_last = {}
}

rect :: proc(ctx: ^Context, x, y, w, h: f32) {
	move_to(ctx, x, y)
	line_to(ctx, x, y + h)
	line_to(ctx, x + w, y + h)
	line_to(ctx, x + w, y)
	close(ctx)
}

// Creates new rounded rectangle shaped sub-path.
rounded_rect :: proc(ctx: ^Context, x, y, w, h, radius: f32) {
	rounded_rect_varying(ctx, x, y, w, h, radius, radius, radius, radius)
}

// Creates new rounded rectangle shaped sub-path with varying radii for each corner.
rounded_rect_varying :: proc(
	ctx: ^Context,
	x, y: f32,
	w, h: f32,
	radius_top_left: f32,
	radius_top_right: f32,
	radius_bottom_right: f32,
	radius_bottom_left: f32,
) {
	if radius_top_left < 0.1 && radius_top_right < 0.1 && radius_bottom_right < 0.1 && radius_bottom_left < 0.1 {
		rect(ctx, x, y, w, h)
	} else {
		halfw := abs(w) * 0.5
		halfh := abs(h) * 0.5
		rxBL := min(radius_bottom_left, halfw) * math.sign(w)
		ryBL := min(radius_bottom_left, halfh) * math.sign(h)
		rxBR := min(radius_bottom_right, halfw) * math.sign(w)
		ryBR := min(radius_bottom_right, halfh) * math.sign(h)
		rxTR := min(radius_top_right, halfw) * math.sign(w)
		ryTR := min(radius_top_right, halfh) * math.sign(h)
		rxTL := min(radius_top_left, halfw) * math.sign(w)
		ryTL := min(radius_top_left, halfh) * math.sign(h)
		
		move_to(ctx, x, y + ryTL)
		line_to(ctx, x, y + h - ryBL)
		cubic_to(ctx, x, y + h - ryBL*(1 - KAPPA90), x + rxBL*(1 - KAPPA90), y + h, x + rxBL, y + h)
		line_to(ctx, x + w - rxBR, y + h)
		cubic_to(ctx, x + w - rxBR*(1 - KAPPA90), y + h, x + w, y + h - ryBR*(1 - KAPPA90), x + w, y + h - ryBR)
		line_to(ctx, x + w, y + ryTR)
		cubic_to(ctx, x + w, y + ryTR*(1 - KAPPA90), x + w - rxTR*(1 - KAPPA90), y, x + w - rxTR, y)
		line_to(ctx, x + rxTL, y)
		cubic_to(ctx, x + rxTL*(1 - KAPPA90), y, x, y + ryTL*(1 - KAPPA90), x, y + ryTL)
		close(ctx)
	}
}

ellipse :: proc(ctx: ^Context, cx, cy, rx, ry: f32) {
	move_to(ctx, cx-rx, cy)
	cubic_to(ctx, cx-rx, cy+ry*KAPPA90, cx-rx*KAPPA90, cy+ry, cx, cy+ry)
	cubic_to(ctx, cx+rx*KAPPA90, cy+ry, cx+rx, cy+ry*KAPPA90, cx+rx, cy)
	cubic_to(ctx, cx+rx, cy-ry*KAPPA90, cx+rx*KAPPA90, cy-ry, cx, cy-ry)
	cubic_to(ctx, cx-rx*KAPPA90, cy-ry, cx-rx, cy-ry*KAPPA90, cx-rx, cy)
	close(ctx)
}

circle :: proc(ctx: ^Context, cx, cy, radius: f32) {
	ellipse(ctx, cx, cy, radius, radius)
}

move_to :: proc(ctx: ^Context, x, y: f32) {
	path_add(ctx)
	state := state_get(ctx)
	ctx.point_last = xform_point_v2(state.xform, { x, y })
}

line_to :: proc(ctx: ^Context, x, y: f32) {
	state := state_get(ctx)
	fa_push(&ctx.temp_curves, Curve { 
		p = { 
			0 = ctx.point_last,
			1 = xform_point_v2(state.xform, { x, y }),
		},
		path_index = i32(ctx.temp_paths.index - 1),
	})
	ctx.point_last = xform_point_v2(state.xform, { x, y })
	
	path := fa_last(&ctx.temp_paths)
	path.curve_end = i32(ctx.temp_curves.index)
}

quadratic_to :: proc(ctx: ^Context, cx, cy, x, y: f32) {
	state := state_get(ctx)
	fa_push(&ctx.temp_curves, Curve { 
		p = { 
			0 = ctx.point_last,
			1 = xform_point_v2(state.xform, { cx, cy }),
			2 = xform_point_v2(state.xform, { x, y }),
		},
		count = 1,
		path_index = i32(ctx.temp_paths.index - 1),
	})
	ctx.point_last = xform_point_v2(state.xform, { x, y })

	path := fa_last(&ctx.temp_paths)
	path.curve_end = i32(ctx.temp_curves.index)
}

cubic_to :: proc(ctx: ^Context, c1x, c1y, c2x, c2y, x, y: f32) {
	state := state_get(ctx)
	fa_push(&ctx.temp_curves, Curve { 
		p = { 
			ctx.point_last,
			xform_point_v2(state.xform, { c1x, c1y }),
			xform_point_v2(state.xform, { c2x, c2y }),
			xform_point_v2(state.xform, { x, y }),
		},
		count = 2,
		path_index = i32(ctx.temp_paths.index - 1),
	})
	ctx.point_last = xform_point_v2(state.xform, { x, y })
	
	path := fa_last(&ctx.temp_paths)
	path.curve_end = i32(ctx.temp_curves.index)
}

close :: proc(ctx: ^Context) {
	if ctx.temp_paths.index > 0 {
		path := fa_last_unsafe(&ctx.temp_paths)

		// connect the start / end point
		if path.curve_end > path.curve_start {
			curve_first := ctx.temp_curves.data[path.curve_start]
			state := state_get(ctx)

			fa_push(&ctx.temp_curves, Curve { 
				p = { 
					0 = ctx.point_last,
					1 = curve_first.p[0],
				},
				path_index = i32(ctx.temp_paths.index - 1),
			})
			
			path.curve_end = i32(ctx.temp_curves.index)
		}

		path.closed = true
	}
}

@private
path_add :: proc(ctx: ^Context) {
	fa_push(&ctx.temp_paths, Path {
		clip = { 0, 0, ctx.window_width, ctx.window_height },
		box = { max(f32), max(f32), -max(f32), -max(f32) },
		curve_start = i32(ctx.temp_curves.index),
		stroke = false,
	})
}

@private
point_equals :: proc(v0, v1: V2, tolerance: f32) -> bool {
	delta := v1 - v0
	return delta.x * delta.x + delta.y * delta.y < tolerance * tolerance
}

// Adds an arc segment at the corner defined by the last path point, and two specified points.
arc_to :: proc(
	ctx: ^Context,
	x1, y1: f32,
	x2, y2: f32,
	radius: f32,
) {
	point_distance_segment :: proc(p0, p1, p2: V2) -> f32 {
		pq := p2 - p1
		delta := p0 - p1
		d := pq.x * pq.x + pq.y * pq.y
		t := pq.x * delta.x + pq.y * delta.y
		
		if d > 0 {
			t /= d
		}
		
		if t < 0 {
			t = 0
		} else if t > 1 {
			t = 1
		} 

		delta.x = p1.x + t * pq.x - p0.x
		delta.y = p1.y + t * pq.y - p0.y
		return delta.x * delta.x + delta.y * delta.y
	}

	if ctx.temp_curves.index == 0 {
		return
	}

	p0 := ctx.point_last
	p1 := V2 { x1, y1 }
	p2 := V2 { x2, y2 }
	
	// Handne degenerate cases.
	if point_equals(p0, p1, ctx.distance_tolerance) ||
		point_equals(p1, p2, ctx.distance_tolerance) ||
		point_distance_segment(p1, p0, p2) < ctx.distance_tolerance*ctx.distance_tolerance ||
		radius < ctx.distance_tolerance {
		line_to(ctx, x1, y1)
		return
	}

	// Calculate tangential circle to lines (p0)-(p1) and (p1)-(p2).
	delta0 := v2_normalize(p0 - p1)
	delta1 := v2_normalize(p2 - p1)
	a := math.acos(delta0.x*delta1.x + delta0.y*delta1.y)
	d := radius / math.tan(a / 2.0)

	if d > 10000 {
		line_to(ctx, x1, y1)
		return
	}

	a0, a1, cx, cy: f32
	direction: int

	if v2_cross(delta0, delta1) > 0.0 {
		cx = x1 + delta0.x*d + delta0.y*radius
		cy = y1 + delta0.y*d + -delta0.x*radius
		a0 = math.atan2(delta0.x, -delta0.y)
		a1 = math.atan2(-delta1.x, delta1.y)
		direction = WINDING_CW
	} else {
		cx = x1 + delta0.x*d + -delta0.y*radius
		cy = y1 + delta0.y*d + delta0.x*radius
		a0 = math.atan2(-delta0.x, delta0.y)
		a1 = math.atan2(delta1.x, -delta1.y)
		direction = WINDING_CCW
	}

	arc(ctx, cx, cy, radius, a0, a1, direction)
}

// Creates new circle arc shaped sub-path. The arc center is at cx,cy, the arc radius is r,
// and the arc is drawn from angle a0 to a1, and swept in direction dir (NVG_CCW, or NVG_CW).
// Angles are specified in radians.
arc :: proc(ctx: ^Context, cx, cy, r, a0, a1: f32, dir: int) {
	do_line := ctx.temp_curves.index > 0

	// Clamp angles
	da := a1 - a0
	if dir == WINDING_CW {
		if abs(da) >= math.PI*2 {
			da = math.PI*2
		} else {	
			for da < 0.0 {
				da += math.PI*2
			}
		}
	} else {
		if abs(da) >= math.PI*2 {
			da = -math.PI*2
		} else {
			for da > 0.0 {
				da -= math.PI*2
			} 
		}
	}

	// Split arc into max 90 degree segments.
	ndivs := max(1, min((int)(abs(da) / (math.PI*0.5) + 0.5), 5))
	hda := (da / f32(ndivs)) / 2.0
	kappa := abs(4.0 / 3.0 * (1.0 - math.cos(hda)) / math.sin(hda))

	if dir == WINDING_CCW {
		kappa = -kappa
	}

	nvals := 0

	px, py, ptanx, ptany: f32
	for i in 0..=ndivs {
		a := a0 + da * f32(i) / f32(ndivs)
		dx := math.cos(a)
		dy := math.sin(a)
		x := cx + dx*r
		y := cy + dy*r
		tanx := -dy*r*kappa
		tany := dx*r*kappa

		if i == 0 {
			if do_line {
				line_to(ctx, x, y)
			} else {
				move_to(ctx, x, y)
			}
		} else {
			cubic_to(
				ctx, 
				px + ptanx, py + ptany,
				x - tanx, y - tany,
				x, y,
			)
		}

		px = x
		py = y
		ptanx = tanx
		ptany = tany
	}
}

// path checking for first / last
ctx_check_closed :: proc(ctx: ^Context) {
	for i in 0..<ctx.temp_paths.index {
		path := &ctx.temp_paths.data[i]

		if path.curve_end > path.curve_start {
			c := ctx.temp_curves.data[path.curve_start]

			if point_equals(c.p[0], curve_endpoint(c), ctx.distance_tolerance) {
				path.closed = true
			}
		}
	}
}

// finish curves, gather aabb, set path closed flag, calculate deltas
ctx_finish_curves :: proc(ctx: ^Context, curves: []Curve) {
	for i in 0..<ctx.temp_paths.index {
		path := &ctx.temp_paths.data[i]

		for j in path.curve_start..<path.curve_end {
			curve := &curves[j]

			// get box early as strokes dont really extend?
			for k in 0..=curve.count + 1 {
				point := curve.p[k]
				path.box.x = min(path.box.x, point.x)
				path.box.y = min(path.box.y, point.y)
				path.box.z = max(path.box.z, point.x)
				path.box.w = max(path.box.w, point.y)
			}
		}
	}
}

@(deferred_in=fill)
fill_scoped :: proc(ctx: ^Context) {
	path_begin(ctx)
}

fill :: proc(ctx: ^Context) {
	spall.SCOPED_EVENT(&ctx.spall_ctx, &ctx.spall_buffer, "fill")
	state := state_get(ctx)

	if ctx.temp_paths.index == 0 {
		return
	}

	// not 100% necessary as we dont use the path.closed on fill
	ctx_check_closed(ctx)
	ctx_finish_curves(ctx, ctx.temp_curves.data)

	fill_paint := state.fill
	fill_paint.inner_color.a *= state.alpha
	fill_paint.outer_color.a *= state.alpha

	// set colors
	for i in 0..<ctx.temp_paths.index {
		path := &ctx.temp_paths.data[i]
		path.color = fill_paint.inner_color
		path.stroke = false
	}

	// submit
	ctx_curves_submit(ctx, fa_slice(&ctx.temp_curves))
}

// submit curves, set the path index per curve AFTER submit to retain relative index
ctx_curves_submit :: proc(ctx: ^Context, slice: []Curve) {
	start := ctx.renderer.curves.index
	fa_add(&ctx.renderer.curves, slice)

	// set curve path final index 
	path_offset := i32(ctx.renderer.paths.index)
	for i in start..<ctx.renderer.curves.index {
		curve := &ctx.renderer.curves.data[i]
		curve.path_index += path_offset
	}

	fa_add(&ctx.renderer.paths, fa_slice(&ctx.temp_paths))
}

@private
STROKE_LINE_TO :: proc(ctx: ^Context, to: V2) {
	fa_push(&ctx.stroke_curves, Curve { p = { 0 = ctx.stroke_last, 1 = to }, path_index = i32(ctx.stroke_path_index) })
	ctx.stroke_last = to
}

@private
STROKE_LINE :: proc(ctx: ^Context, from, to: V2) {
	fa_push(&ctx.stroke_curves, Curve { p = { 0 = from, 1 = to }, path_index = i32(ctx.stroke_path_index) })
	ctx.stroke_last = to
}

@private
STROKE_QUAD_TO :: proc(ctx: ^Context, control, to: V2) {
	fa_push(&ctx.stroke_curves, Curve { p = { 0 = ctx.stroke_last, 1 = control, 2 = to }, count = 1, path_index = i32(ctx.stroke_path_index) })
	ctx.stroke_last = to
}

// push joints based on shared point p0 and t0/t1 normals
@private
stroke_push_joints :: proc(ctx: ^Context, state: ^State, p0, t0, t1: V2) {
	w2 := state.stroke_width / 2

	n0 := v2_perpendicular(v2_normalize(t0))
	n1 := v2_perpendicular(v2_normalize(t1))

	cross_z := v2_cross(n1, n0)
	if cross_z > 0 {
		n0 *= -1
		n1 *= -1
	}

	u := n0 + n1
	unorm_square := u.x * u.x + u.y * u.y
	alpha := state.stroke_width / unorm_square
	v := u * alpha
	temp := alpha - state.stroke_width / 4
	excursion_suqare := unorm_square * (temp * temp)

	ctx.stroke_last = p0

	if state.line_join == .Miter && excursion_suqare <= (state.miter_limit * state.miter_limit) {
		STROKE_LINE_TO(ctx, { p0.x + n1.x * w2, p0.y + n1.y * w2 })
		STROKE_LINE_TO(ctx, p0 + v)
		STROKE_LINE_TO(ctx, { p0.x + n0.x * w2, p0.y + n0.y * w2 })
		STROKE_LINE_TO(ctx, p0)
	} else {
		STROKE_LINE_TO(ctx, { p0.x + n1.x * w2, p0.y + n1.y * w2 })
		STROKE_LINE_TO(ctx, { p0.x + n0.x * w2, p0.y + n0.y * w2 })
		STROKE_LINE_TO(ctx, p0)
	}
}

@private
stroke_flatten :: proc(ctx: ^Context) {
	state := state_get(ctx)
	w2 := state.stroke_width / 2

	v0, v1: V2
	type: i32
	type_last: i32 

	// traverse paths
	for path_index in 0..<ctx.temp_paths.index {
		path := &ctx.temp_paths.data[path_index]
		path.stroke = true
		stroke_start := ctx.stroke_curves.index
		curves := ctx.temp_curves.data[path.curve_start:path.curve_end]
		ctx.stroke_path_index = i32(path_index)

		if len(curves) == 0 {
			continue
		}

		for i in 0..<len(curves) {
			curve := curves[i]

			// add joints from previous to current curve
			if i != 0 {
				previous := curves[i - 1]
				p0 := curve.p[0]
				t0 := curve_endpoint_tangent(previous)
				t1 := curve_beginpoint_tangent(curve)

				if ctx.stroke_joints {
					stroke_push_joints(ctx, state, p0, t0, t1)
				}
			}

			switch curve.count {
			case CURVE_LINE:
				S := curve.p[0]
				E := curve_endpoint(curve)

				dn := v2_perpendicular(v2_normalize(E - S))

				ctx.stroke_last	= S - dn * w2
				origin := ctx.stroke_last
				STROKE_LINE_TO(ctx, S + dn * w2)
				STROKE_LINE_TO(ctx, E + dn * w2)
				STROKE_LINE_TO(ctx, E - dn * w2)
				STROKE_LINE_TO(ctx, origin)

			case CURVE_QUADRATIC:
				pos1, pos2, split1 := curve_offset_quadratic(curve, +w2)
				neg1, neg2, split2 := curve_offset_quadratic(curve, -w2)

				if !split1 {
					curve_invert(&neg1)

					STROKE_LINE(ctx, curve_endpoint(neg1), pos1.p[0])
					fa_push(&ctx.stroke_curves, pos1)
					STROKE_LINE(ctx, curve_endpoint(pos1), neg1.p[0])
					fa_push(&ctx.stroke_curves, neg1)
				} else {
					curve_invert(&neg1)
					curve_invert(&neg2)

					STROKE_LINE(ctx, curve_endpoint(neg1), pos1.p[0])
					fa_push(&ctx.stroke_curves, pos1)
					fa_push(&ctx.stroke_curves, pos2)
					STROKE_LINE(ctx, curve_endpoint(pos2), neg2.p[0])
					fa_push(&ctx.stroke_curves, neg1)
					fa_push(&ctx.stroke_curves, neg2)
				}

			case CURVE_CUBIC:
				// fmt.eprintln("TRY", curve)
				curve_offset_cubic(ctx, curve, w2)
			}

			// // cap on first curve
			// if i == 0 {
			// 	switch state.line_cap {
			// 	case .Butt: 
			// 		ctx.stroke_last	= S - dn * w2
			// 		STROKE_LINE_TO(ctx, S + dn * w2)
			// 	case .Square:
			// 		ctx.stroke_last	= S - dn * w2 - d * w2
			// 		STROKE_LINE_TO(ctx, S + dn * w2 - d * w2)
			// 	}
			// } else {
			// 	// normal line
			// 	ctx.stroke_last	= S - dn * w2
			// 	STROKE_LINE_TO(ctx, S + dn * w2)
			// }

			// // cap on end
			// if i == len(curves) - 1 {
			// 	switch curve.count {
			// 	case CURVE_LINE:
			// 		switch state.line_cap {
			// 		case .Butt: 
			// 			STROKE_LINE_TO(ctx, E + dn * w2)
			// 			STROKE_LINE_TO(ctx, E - dn * w2)
			// 		case .Square: 
			// 			STROKE_LINE_TO(ctx, E + dn * w2 + d * w2)
			// 			STROKE_LINE_TO(ctx, E - dn * w2 + d * w2)
			// 		}

			// 	case CURVE_QUADRATIC: 
			// 		switch state.line_cap {
			// 		case .Butt: 
			// 			STROKE_LINE_TO(ctx, E + dn * w2)
			// 			STROKE_LINE_TO(ctx, E - dn * w2)
			// 		case .Square: 
			// 			STROKE_LINE_TO(ctx, E + dn * w2 + d * w2)
			// 			STROKE_LINE_TO(ctx, E - dn * w2 + d * w2)
			// 		}

			// 	case CURVE_CUBIC:
			// 		unimplemented("YO0")					
			// 	}
			// } else {
			// 	switch curve.count {
			// 	case CURVE_LINE:
			// 		STROKE_LINE_TO(ctx, E + dn * w2)
			// 		STROKE_LINE_TO(ctx, E - dn * w2)

			// 	case CURVE_QUADRATIC:
			// 		unimplemented("YO1")

			// 	case CURVE_CUBIC:
			// 		unimplemented("YO2")
			// 	}
			// }

			// curve_first := ctx.stroke_curves.data[curve_start_index]
			
			// switch curve.count {
			// case CURVE_LINE:
			// 	STROKE_LINE_TO(ctx, curve_first.p[0])
			// }
		}

		// add a closed joint when the path was properly closed
		if path.closed {
			c0 := curves[0]
			cX := curves[len(curves) - 1]

			p0 := c0.p[0]
			t0 := curve_endpoint_tangent(cX)
			t1 := curve_beginpoint_tangent(c0)

			if ctx.stroke_joints {
				stroke_push_joints(ctx, state, p0, t0, t1)
			}
		}

		// set final indices again
		path.curve_start = i32(stroke_start)
		path.curve_end = i32(ctx.stroke_curves.index)
	}
}

stroke :: proc(ctx: ^Context) {
	spall.SCOPED_EVENT(&ctx.spall_ctx, &ctx.spall_buffer, "stroke")

	if ctx.temp_paths.index == 0 {
		return
	}

	state := state_get(ctx)
	stroke_paint := state.stroke
	stroke_paint.inner_color.a *= state.alpha
	stroke_paint.outer_color.a *= state.alpha

	ctx_check_closed(ctx)
	stroke_flatten(ctx)
	ctx_finish_curves(ctx, ctx.stroke_curves.data)

	// set colors
	for i in 0..<ctx.temp_paths.index {
		path := &ctx.temp_paths.data[i]
		path.color = stroke_paint.inner_color
	}

	// submit
	ctx_curves_submit(ctx, fa_slice(&ctx.stroke_curves))
}

///////////////////////////////////////////////////////////
// STATE TRANSFORMS
///////////////////////////////////////////////////////////

translate :: proc(ctx: ^Context, x, y: f32) {
	state := state_get(ctx)
	temp := xform_translate(x, y)
	xform_premultiply(&state.xform, temp)
}

scale :: proc(ctx: ^Context, x, y: f32) {
	state := state_get(ctx)
	temp := xform_scale(x, y)
	xform_premultiply(&state.xform, temp)
}

rotate :: proc(ctx: ^Context, rotation: f32) {
	state := state_get(ctx)
	temp := xform_rotate(rotation)
	xform_premultiply(&state.xform, temp)
}

reset_transform :: proc(ctx: ^Context) {
	state := state_get(ctx)
	xform_identity(&state.xform)
}

///////////////////////////////////////////////////////////
// POOL
///////////////////////////////////////////////////////////

Pool_Invalid_Slot_Index :: 0

Pool :: struct($N: int, $T: typeid) {
	data: [N + 1]T,
	queue_top: int,
	free_queue: [N]u32,
}

pool_clear :: proc(pool: ^Pool($N, $T)) {
	pool.queue_top = 0

	for i := u32(N); i >= 1; i -= 1 {
		pool.free_queue[pool.queue_top] = i
		pool.queue_top += 1
	}
}

pool_alloc_index :: proc(p: ^Pool($N, $T)) -> u32 #no_bounds_check {
	if p.queue_top > 0 {
		p.queue_top -= 1
		slot_index := p.free_queue[p.queue_top]
		assert(slot_index > Pool_Invalid_Slot_Index && slot_index < u32(N))
		return slot_index
	} else {
		return Pool_Invalid_Slot_Index
	}
}

pool_free_index :: proc(p: ^Pool($N, $T), slot_index: u32, loc := #caller_location) #no_bounds_check {
	runtime.bounds_check_error_loc(loc, int(slot_index), N)
	assert(slot_index > Pool_Invalid_Slot_Index)
	assert(p.queue_top < N)

	// debug check?

	p.free_queue[p.queue_top] = u32(slot_index)
	p.queue_top += 1
	assert(p.queue_top <= N - 1)
}

pool_at :: proc(p: ^Pool($N, $T), slot_index: u32, loc := #caller_location) -> ^T #no_bounds_check {
	runtime.bounds_check_error_loc(loc, int(slot_index), N)
	assert(slot_index > Pool_Invalid_Slot_Index)
	return &p.data[slot_index]
}

///////////////////////////////////////////////////////////
// Finite Array + allocated
///////////////////////////////////////////////////////////

// TODO do bounds checking
Fixed_Array :: struct($T: typeid) {
	data: []T,
	index: int,
}

fa_init :: proc(fa: ^Fixed_Array($T), cap: int) {
	fa.data = make([]T, cap)
	fa.index = 0
}

fa_destroy :: proc(fa: Fixed_Array($T)) {
	delete(fa.data)
}

fa_clear :: #force_inline proc(fa: ^Fixed_Array($T)) {
	fa.index = 0
}

fa_slice :: proc(fa: ^Fixed_Array($T)) -> []T {
	return fa.data[:fa.index]
}

fa_raw :: proc(fa: ^Fixed_Array($T)) -> rawptr {
	return raw_data(fa.data)
}

fa_last_unsafe :: proc(fa: ^Fixed_Array($T)) -> ^T {
	return &fa.data[fa.index - 1]
}

fa_last :: proc(fa: ^Fixed_Array($T)) -> ^T {
	if fa.index > 0 {
		return &fa.data[fa.index - 1]
	} else {
		return nil
	}
}

fa_empty :: proc(fa: Fixed_Array($T)) -> bool {
	return fa.index == 0
}

fa_not_empty :: proc(fa: Fixed_Array($T)) -> bool {
	return fa.index > 0
}

fa_push :: proc(fa: ^Fixed_Array($T), item: T, loc := #caller_location) #no_bounds_check {
	runtime.bounds_check_error_loc(loc, fa.index + 1, len(fa.data))
	fa.data[fa.index] = item
	fa.index += 1
}

// copy a slice over added
fa_add :: proc(fa: ^Fixed_Array($T), slice: []T, loc := #caller_location) #no_bounds_check {
	runtime.bounds_check_error_loc(loc, fa.index + len(slice), len(fa.data))
	copy(fa.data[fa.index:], slice)
	fa.index += len(slice)
}

// set data to fixed array
fa_copy :: proc(fa: ^Fixed_Array($T), slice: []T) {
	copy(fa.data, slice)
	fa.index = len(slice)
}

///////////////////////////////////////////////////////////
// Affine Transformation with less storage than a 4x4 matrix
///////////////////////////////////////////////////////////

xform_point_v2 :: proc(xform: Xform, input: [2]f32) -> [2]f32 {
	return {
		input.x * xform[0] + input.y * xform[2] + xform[4],
		input.x * xform[1] + input.y * xform[3] + xform[5],
	}
}

xform_point_xy :: proc(xform: Xform, x, y: f32) -> (outx, outy: f32) {
	outx = x * xform[0] + y * xform[2] + xform[4]
	outy = x * xform[1] + y * xform[3] + xform[5]
	return
}

// without offset
xform_v2 :: proc(xform: Xform, input: [2]f32) -> [2]f32 {
	return {
		input.x * xform[0] + input.y * xform[2],
		input.x * xform[1] + input.y * xform[3],
	}
}

xform_identity :: proc(xform: ^Xform) {
	xform^ = {
		1, 0,
		0, 1,
		0, 0,
	}
}

xform_translate :: proc(tx, ty: f32) -> Xform {
	return {
		1, 0,
		0, 1,
		tx, ty,
	}
}

xform_scale :: proc(sx, sy: f32) -> Xform {
	return {
		sx, 0,
		0, sy,
		0, 0,
	}
}

xform_rotate :: proc(angle: f32) -> Xform {
	cs := math.cos(angle)
	sn := math.sin(angle)
	return {
		cs, sn,
		-sn, cs,
		0, 0,
	}
}

xform_multiply :: proc(t: ^Xform, s: Xform) {
	t0 := t[0] * s[0] + t[1] * s[2]
	t2 := t[2] * s[0] + t[3] * s[2]
	t4 := t[4] * s[0] + t[5] * s[2] + s[4]
	t[1] = t[0] * s[1] + t[1] * s[3]
	t[3] = t[2] * s[1] + t[3] * s[3]
	t[5] = t[4] * s[1] + t[5] * s[3] + s[5]
	t[0] = t0
	t[2] = t2
	t[4] = t4
}

xform_premultiply :: proc(a: ^Xform, b: Xform) {
	temp := b
	xform_multiply(&temp, a^)
	a^ = temp
}

///////////////////////////////////////////////////////////
// text calls
///////////////////////////////////////////////////////////

Align_Horizontal :: enum {
	Left,
	Center,
	Right,
}

Align_Vertical :: enum {
	Top,
	Middle,
	Baseline,
	Bottom,
}

text :: proc(ctx: ^Context, input: string, x := f32(0), y := f32(0)) -> f32 {
	spall.SCOPED_EVENT(&ctx.spall_ctx, &ctx.spall_buffer, "text")
	state := state_get(ctx)

	if state.font_id == Pool_Invalid_Slot_Index {
		return x
	}

	path_begin(ctx)
	font := pool_at(&ctx.font_pool, state.font_id)

	iter := text_iter_init(font, input, x, y, state.font_size, state.letter_spacing, state.ah, state.av)
	for glyph in text_iter_next(&iter) {
		font_glyph_render(ctx, font, glyph, iter.x, iter.y, state.font_size)
	}

	fill(ctx)
	return iter.nextx
}

text_icon :: proc(ctx: ^Context, codepoint: rune, x := f32(0), y := f32(0)) -> f32 {
	state := state_get(ctx)

	if state.font_id == Pool_Invalid_Slot_Index {
		return x
	}

	path_begin(ctx)
	font := pool_at(&ctx.font_pool, state.font_id)
	glyph := font_glyph_get(font, codepoint)

	if glyph == nil {
		return x
	}

	scaling := state.font_size * font.scaling
	x := x
	y := y + font_vertical_align(font, state.av, state.font_size)
	width := (glyph.x1 - glyph.x0) * scaling
	switch state.ah {
		case .Left: 
		case .Center: x = math.round(x - width * 0.5)
		case .Right: x -= width
	}

	font_glyph_render(ctx, font, glyph, x, y, state.font_size)
	fill(ctx)
	return x + f32(glyph.advance) * scaling
}

font_push_mem :: proc(ctx: ^Context, name: string, data: []byte, free_loaded_data: bool, init: bool) -> u32 {
	index := pool_alloc_index(&ctx.font_pool)
	font := pool_at(&ctx.font_pool, index)
	font_init(font, name, data, free_loaded_data, init)
	return index
}

font_push_path :: proc(ctx: ^Context, name: string, path: string, init: bool) -> u32 {
	data, ok := os.read_entire_file(path)
	if !ok {
		return Pool_Invalid_Slot_Index		
	}

	index := pool_alloc_index(&ctx.font_pool)
	font := pool_at(&ctx.font_pool, index)

	font_init(font, name, data, false, init)
	return index
}

font_push :: proc { font_push_mem, font_push_path }

font_size :: proc(ctx: ^Context, to: f32) {
	state := state_get(ctx)
	state.font_size = to
}

font_face :: proc(ctx: ^Context, face: string) {
	state := state_get(ctx)

	// TODO use sparse set
	for i in 0..<len(ctx.font_pool.data) {
		font := ctx.font_pool.data[i]
		
		if font.name == face {
			state.font_id = u32(i)
			break
		}
	}
}

text_bounds :: proc(ctx: ^Context, input: string, x := f32(0), y := f32(0)) -> f32 {
	font := pool_at(&ctx.font_pool, 1) 
	state := state_get(ctx)
	width := font_text_bounds(font, input, x, y, state.font_size, state.letter_spacing, state.ah)
	return width
}

text_align_horizontal :: proc(ctx: ^Context, ah: Align_Horizontal) {
	state := state_get(ctx)
	state.ah = ah
}

text_align_vertical :: proc(ctx: ^Context, av: Align_Vertical) {
	state := state_get(ctx)
	state.av = av
}

text_align :: proc(ctx: ^Context, ah: Align_Horizontal, av: Align_Vertical) {
	state := state_get(ctx)
	state.av = av
	state.ah = ah
}