package vg

import "core:mem"
import "core:fmt"
import "core:math"
import "core:slice"
import "core:runtime"
import "core:strings"
import "core:math/rand"
import glm "core:math/linalg/glsl"
import sa "core:container/small_array"
import gl "vendor:OpenGL"

KAPPA90 :: 0.5522847493

MAX_STATES :: 32
MAX_COMMANDS :: 1028
MAX_TEMP_PATHS :: 128
MAX_TEMP_CURVES :: 1028

Paint :: struct {
	xform: Xform,
	inner_color: [4]f32,
	outer_color: [4]f32,
}

Line_Cap :: enum {
	Butt,
	Round,
	Square,
	Bevel,
	Miter,
}

State :: struct {
	fill: Paint,
	stroke: Paint,
	stroke_width: f32,
	line_join: Line_Cap,
	line_cap: Line_Cap,
	miter_limit: f32,
	alpha: f32,
	xform: Xform,

	font_size: f32,
	letter_spacing: f32,
	line_height: f32,
	font_id: int,
}

Xform :: [6]f32

Context :: struct {
	// temp data for building paths, can be copied over
	temp_curves: Fixed_Array(Curve),
	temp_paths: Fixed_Array(Path),

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
}

V2 :: [2]f32

ctx_device_pixel_ratio :: proc(ctx: ^Context, ratio: f32) {
	ctx.tesselation_tolerance = 0.25 / ratio
	ctx.distance_tolerance = 0.01 / ratio
	ctx.device_pixel_ratio = ratio
}

ctx_init :: proc(ctx: ^Context) {
	fa_init(&ctx.temp_curves, MAX_TEMP_CURVES)
	fa_init(&ctx.temp_paths, MAX_TEMP_PATHS)
	fa_init(&ctx.states, MAX_STATES)

	ctx_save(ctx)
	ctx_reset(ctx)
	ctx_device_pixel_ratio(ctx, 1)

	renderer_init(&ctx.renderer)
}

ctx_make :: proc() -> (res: Context) {
	ctx_init(&res)
	return
}

ctx_destroy :: proc(ctx: ^Context) {
	renderer_destroy(&ctx.renderer)
	fa_destroy(ctx.temp_paths)
	fa_destroy(ctx.temp_curves)
	fa_destroy(ctx.states)
}

ctx_frame_begin :: proc(ctx: ^Context, width, height: int, device_pixel_ratio: f32) {
	fa_clear(&ctx.states)
	ctx_save(ctx)
	ctx_reset(ctx)
	ctx_device_pixel_ratio(ctx, device_pixel_ratio)
	renderer_begin(&ctx.renderer, width, height)
}

ctx_frame_end :: proc(ctx: ^Context) {
	renderer_end(&ctx.renderer)
}

ctx_save :: proc(ctx: ^Context) {
	if ctx.states.index >= MAX_STATES {
		return
	}

	// copy prior
	if ctx.states.index > 0 {
		ctx.states.data[ctx.states.index] = ctx.states.data[ctx.states.index - 1]
	}

	ctx.states.index += 1
}

ctx_restore :: proc(ctx: ^Context) {
	if ctx.states.index <= 1 {
		return
	}

	ctx.states.index -= 1
}

@(deferred_in=ctx_restore)
ctx_save_scoped :: #force_inline proc(ctx: ^Context) {
	ctx_save(ctx)
}

@private
paint_set_color :: proc(p: ^Paint, color: [4]f32) {
	p^ = {}
	xform_identity(&p.xform)
	p.inner_color = color
	p.outer_color = color
}

ctx_reset :: proc(ctx: ^Context) {
	state := state_get(ctx)
	state^ = {}

	paint_set_color(&state.fill, { 1, 0, 0, 1 })
	paint_set_color(&state.stroke, { 0, 0, 0, 1 })

	state.stroke_width = 1
	state.miter_limit = 10
	state.line_cap = .Butt
	state.line_join = .Miter
	state.alpha = 1
	xform_identity(&state.xform)

	// font sets
	state.font_size = 16
	state.letter_spacing = 0
	state.line_height = 1
}

@private
state_get :: proc(ctx: ^Context) -> ^State #no_bounds_check {
	return &ctx.states.data[ctx.states.index - 1]
}

ctx_stroke_width :: proc(ctx: ^Context, value: f32) {
	state := state_get(ctx)
	state.stroke_width = value
}

ctx_fill_color :: proc(ctx: ^Context, color: [4]f32) {
	state := state_get(ctx)
	paint_set_color(&state.fill, color)
}

ctx_stroke_color :: proc(ctx: ^Context, color: [4]f32) {
	state := state_get(ctx)
	paint_set_color(&state.stroke, color)
}

path_begin :: proc(ctx: ^Context) {
	fa_clear(&ctx.temp_curves)
	fa_clear(&ctx.temp_paths)
	ctx.point_last = {}
}

push_rect :: proc(ctx: ^Context, x, y, w, h: f32) {
	push_move_to(ctx, x, y)
	push_line_to(ctx, x, y + h)
	push_line_to(ctx, x + w, y + h)
	push_line_to(ctx, x + w, y)
	push_close(ctx)
}

push_ellipse :: proc(ctx: ^Context, cx, cy, rx, ry: f32) {
	push_move_to(ctx, cx, cy)
	push_cubic_to(ctx, cx-rx, cy+ry*KAPPA90, cx-rx*KAPPA90, cy+ry, cx, cy+ry)
	push_cubic_to(ctx, cx+rx*KAPPA90, cy+ry, cx+rx, cy+ry*KAPPA90, cx+rx, cy)
	push_cubic_to(ctx, cx+rx, cy-ry*KAPPA90, cx+rx*KAPPA90, cy-ry, cx, cy-ry)
	push_cubic_to(ctx, cx-rx*KAPPA90, cy-ry, cx-rx, cy-ry*KAPPA90, cx-rx, cy)
	push_close(ctx)
}

push_circle :: proc(ctx: ^Context, cx, cy, radius: f32) {
	push_ellipse(ctx, cx, cy, radius, radius)
}

push_move_to :: proc(ctx: ^Context, x, y: f32) {
	path_add(ctx)
	ctx.point_last = { x, y }
}

push_line_to :: proc(ctx: ^Context, x, y: f32) {
	state := state_get(ctx)
	fa_push(&ctx.temp_curves, Curve { 
		B = { 
			0 = xform_point_v2(state.xform, ctx.point_last),
			1 = xform_point_v2(state.xform, { x, y }),
		},
		path_index = i32(ctx.temp_paths.index - 1),
	})
	ctx.point_last = { x, y }
	
	path := fa_last(&ctx.temp_paths)
	path.curve_end = i32(ctx.temp_curves.index)
}

push_quadratic_to :: proc(ctx: ^Context, cx, cy, x, y: f32) {
	state := state_get(ctx)
	fa_push(&ctx.temp_curves, Curve { 
		B = { 
			0 = xform_point_v2(state.xform, ctx.point_last),
			1 = xform_point_v2(state.xform, { cx, cy }),
			2 = xform_point_v2(state.xform, { x, y }),
		},
		count = 1,
		path_index = i32(ctx.temp_paths.index - 1),
	})
	ctx.point_last = { x, y }
	
	path := fa_last(&ctx.temp_paths)
	path.curve_end = i32(ctx.temp_curves.index)
}

push_cubic_to :: proc(ctx: ^Context, c1x, c1y, c2x, c2y, x, y: f32) {
	state := state_get(ctx)
	fa_push(&ctx.temp_curves, Curve { 
		B = { 
			0 = xform_point_v2(state.xform, ctx.point_last),
			1 = xform_point_v2(state.xform, { c1x, c1y }),
			2 = xform_point_v2(state.xform, { c2x, c2y }),
			3 = xform_point_v2(state.xform, { x, y }),
		},
		count = 2,
		path_index = i32(ctx.temp_paths.index - 1),
	})
	ctx.point_last = { x, y }
	
	path := fa_last(&ctx.temp_paths)
	path.curve_end = i32(ctx.temp_curves.index)
}

push_close :: proc(ctx: ^Context) {
	if ctx.temp_paths.index > 0 {
		path := fa_last_unsafe(&ctx.temp_paths)

		// connect the start / end point
		if path.curve_end > path.curve_start {
			curve_first := ctx.temp_curves.data[path.curve_start]
			state := state_get(ctx)

			fa_push(&ctx.temp_curves, Curve { 
				B = { 
					0 = xform_point_v2(state.xform, ctx.point_last),
					1 = curve_first.B[0],
				},
				path_index = i32(ctx.temp_paths.index - 1),
			})
			
			path.curve_end = i32(ctx.temp_curves.index)			
		}
	}
}

@private
path_add :: proc(ctx: ^Context) {
	fa_push(&ctx.temp_paths, Path {
		// TODO replace
		clip = { 0, 0, 800, 800 },
		box = { max(f32), max(f32), -max(f32), -max(f32) },
		curve_start = i32(ctx.temp_curves.index),
	})
}

point_equals :: proc(v0, v1: V2, tolerance: f32) -> bool {
	delta := v1 - v0
	return delta.x * delta.x + delta.y * delta.y < tolerance * tolerance
}

v2_normalize :: proc(v: ^V2) -> f32 {
	d := math.sqrt(v.x * v.x + v.y * v.y)
	if d > 1e-6 {
		id := 1.0 / d
		v.x *= id
		v.y *= id
	}
	return d
}

// paths_calculate_joins :: proc(
// 	ctx: ^Context,
// 	w: f32,
// 	line_join: Line_Cap,
// 	miter_limit: f32,
// ) {
// 	cache := &ctx.cache
// 	iw := f32(0)

// 	if w > 0 {
// 		iw = 1.0 / w
// 	} 

// 	// Calculate which joins needs extra vertices to append, and gather vertex count.
// 	for i in 0..<ctx.cache.paths.index {
// 		path := &ctx.cache.paths.data[i]
// 		pts := ctx.cache.points.data[path.point_start:]
// 		p0 := &pts[path.count-1]
// 		p1 := &pts[0]
// 		nleft := 0
// 		path.nbevel = 0

// 		for j in 0..<path.count {
// 			dlx0, dly0, dlx1, dly1, dmr2, __cross, limit: f32
// 			dlx0 = p0.delta.y
// 			dly0 = -p0.delta.x
// 			dlx1 = p1.delta.y
// 			dly1 = -p1.delta.x
// 			// Calculate extrusions
// 			p1.dmx = (dlx0 + dlx1) * 0.5
// 			p1.dmy = (dly0 + dly1) * 0.5
// 			dmr2 = p1.dmx*p1.dmx + p1.dmy*p1.dmy
// 			if (dmr2 > 0.000001) {
// 				scale := 1.0 / dmr2
// 				if (scale > 600.0) {
// 					scale = 600.0
// 				}
// 				p1.dmx *= scale
// 				p1.dmy *= scale
// 			}

// 			// Clear flags, but keep the corner.
// 			p1.flags = (.Corner in p1.flags) ? { .Corner } : {}

// 			// Keep track of left turns.
// 			__cross = p1.delta.x * p0.delta.y - p0.delta.x * p1.delta.y
// 			if __cross > 0.0 {
// 				nleft += 1
// 				incl(&p1.flags, Point_Flag.Left)
// 			}

// 			// Calculate if we should use bevel or miter for inner join.
// 			limit = max(1.01, min(p0.len, p1.len) * iw)
// 			if (dmr2 * limit * limit) < 1.0 {
// 				incl(&p1.flags, Point_Flag.Inner_Bevel)
// 			}

// 			// Check to see if the Corner needs to be beveled.
// 			if .Corner in p1.flags {
// 				if (dmr2 * miter_limit*miter_limit) < 1.0 || line_join == .Bevel || line_join == .Round {
// 					incl(&p1.flags, Point_Flag.Bevel)
// 				}
// 			}

// 			if (.Bevel in p1.flags) || (.Inner_Bevel in p1.flags) {
// 				path.nbevel += 1
// 			}

// 			p0 = p1
// 			p1 = mem.ptr_offset(p1, 1)
// 		}

// 		path.convex = nleft == path.count
// 	}
// }

fill :: proc(ctx: ^Context) {
	state := state_get(ctx)

	fill_paint := state.fill
	fill_paint.inner_color.a *= state.alpha
	fill_paint.outer_color.a *= state.alpha

	// set colors and get bounding box
	for i in 0..<ctx.temp_paths.index {
		path := &ctx.temp_paths.data[i]
		path.color = fill_paint.inner_color

		for j in path.curve_start..<path.curve_end {
			curve := &ctx.temp_curves.data[j]
			curve.path_index += i32(ctx.renderer.paths.index)

			for k in 0..=curve.count + 1 {
				point := curve.B[k]
				path.box.x = min(path.box.x, point.x)
				path.box.y = min(path.box.y, point.y)
				path.box.z = max(path.box.z, point.x)
				path.box.w = max(path.box.w, point.y)
			}
		}
	}

	fa_add(&ctx.renderer.curves, fa_slice(&ctx.temp_curves))
	fa_add(&ctx.renderer.paths, fa_slice(&ctx.temp_paths))
}

ctx_translate :: proc(ctx: ^Context, x, y: f32) {
	state := state_get(ctx)
	temp := xform_translate(x, y)
	xform_premultiply(&state.xform, temp)
}

ctx_scale :: proc(ctx: ^Context, x, y: f32) {
	state := state_get(ctx)
	temp := xform_scale(x, y)
	xform_premultiply(&state.xform, temp)
}

ctx_rotate :: proc(ctx: ^Context, rotation: f32) {
	state := state_get(ctx)
	temp := xform_rotate(rotation)
	xform_premultiply(&state.xform, temp)
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
// Sparse Set
///////////////////////////////////////////////////////////

// sparse stores indices
// dense stores id
Sparse_Set :: struct {
	data: []int,
	sparse: int, // offset where dense starts
	size: int,
}

sparse_set_init :: proc(set: ^Sparse_Set, cap: int) {
	// TODO could be uninitialized since it doesnt matter
	set.data = make([]int, cap * 2)
	set.sparse = cap
	set.size = 0
}

sparse_set_make :: proc(cap: int) -> (res: Sparse_Set) {
	sparse_set_init(&res, cap)
	return
}

sparse_set_clear :: proc(set: ^Sparse_Set) {
	set.size = 0
}

sparse_set_contains :: proc(set: ^Sparse_Set, id: int) -> bool #no_bounds_check {
	index := set.data[set.sparse + id]
	return index <= 0 && index < set.size && set.data[index] == id
}

sparse_set_insert :: proc(set: ^Sparse_Set, id: int) {
	if !sparse_set_contains(set, id) {
		index := set.size
		set.data[index] = id
		set.data[set.sparse + id] = index
		set.size += 1
	}
}

sparse_set_print :: proc(set: ^Sparse_Set) {
	fmt.eprintln("DENSE  ", set.data[:set.sparse])
	fmt.eprintln("SPARSE ", set.data[set.sparse:])
	fmt.eprintln()
}

sparse_set_print_dense :: proc(set: ^Sparse_Set) {
	fmt.eprintln("DENSE  ", set.data[:set.size])
}

@test
sparse_set_test :: proc() {
	set := sparse_set_make(10)
	sparse_set_print(&set)
	sparse_set_insert(&set, 3)
	sparse_set_insert(&set, 3)
	sparse_set_insert(&set, 3)
	sparse_set_insert(&set, 4)
	sparse_set_insert(&set, 5)
	sparse_set_insert(&set, 6)
	sparse_set_print(&set)
	fmt.eprintln(sparse_set_contains(&set, 4))
	fmt.eprintln(sparse_set_contains(&set, 3))

	// sparse_set_print_dense(&set)
	// sparse_set_remove(&set, 3)
	// sparse_set_print_dense(&set)
	
	// sparse_set_print(&set)
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

fa_raw :: proc(fa: Fixed_Array($T)) -> rawptr {
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

fa_push :: proc(fa: ^Fixed_Array($T), item: T) {
	fa.data[fa.index] = item
	fa.index += 1
}

// copy a slice over added
fa_add :: proc(fa: ^Fixed_Array($T), slice: []T) {
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