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
MAX_CACHE_PATHS :: 1028
MAX_CACHE_POINTS :: 1028
MAX_CACHE_VERTICES :: 1028

Command :: enum i32 {
	Move_To,
	Line_To,
	Quadratic_To,
	Cubic_To,
	Close,
}

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
	// float commands for less allocation
	commands: Fixed_Array(V2),
	command_last: V2, // saved last

	// state stored 
	states: Fixed_Array(State),

	// font data
	font_pool: Pool(8, Font),

	// renderer 
	renderer: Renderer,

	// quality options?
	distance_tolerance: f32,
	tesselation_tolerance: f32,
	fringe_width: f32,
	device_pixel_ratio: f32,

	// cache
	cache: Cache,
}

Cache :: struct {
	paths: Fixed_Array(Cache_Path),
	points: Fixed_Array(Cache_Point),
	bounds: [4]f32,
}

Cache_Path :: struct {
	point_start: int,
	count: int,
	closed: bool,

	nbevel: int,
	fill: []V2,
	stroke: []V2,

	convex: bool,	
}

Cache_Point :: struct {
	pos: V2,
	delta: V2,
	len: f32,
	dmx, dmy: f32,
	flags: Point_Flags,
}

Point_Flag :: enum {
	Corner,
	Left,
	Bevel,
	Inner_Bevel,
}
Point_Flags :: bit_set[Point_Flag]

V2 :: [2]f32

ctx_device_pixel_ratio :: proc(ctx: ^Context, ratio: f32) {
	ctx.tesselation_tolerance = 0.25 / ratio
	ctx.distance_tolerance = 0.01 / ratio
	ctx.fringe_width = 1.0 / ratio
	ctx.device_pixel_ratio = ratio
}

ctx_init :: proc(ctx: ^Context) {
	fa_init(&ctx.commands, MAX_COMMANDS)
	fa_init(&ctx.states, MAX_STATES)

	ctx_save(ctx)
	ctx_reset(ctx)
	ctx_device_pixel_ratio(ctx, 1)

	fa_init(&ctx.cache.paths, MAX_CACHE_PATHS)
	fa_init(&ctx.cache.points, MAX_CACHE_POINTS)

	renderer_init(&ctx.renderer)
}

ctx_make :: proc() -> (res: Context) {
	ctx_init(&res)
	return
}

ctx_destroy :: proc(ctx: ^Context) {
	renderer_destroy(&ctx.renderer)
	fa_destroy(ctx.cache.points)
	fa_destroy(ctx.cache.paths)
	fa_destroy(ctx.commands)
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
	// TODO render final results
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

	paint_set_color(&state.fill, { 1, 1, 1, 1 })
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

@private
cmd2f :: #force_inline proc(cmd: Command) -> V2 {
	return { transmute(f32) cmd, max(f32) }
}

f2cmd :: #force_inline proc(v: V2) -> Command {
	return transmute(Command) v.x
}

ctx_append_commands :: proc(ctx: ^Context, values: []V2) {
	state := state_get(ctx)

	cmd_first := Command(values[0].x)
	if cmd_first != .Close {
		ctx.command_last = values[len(values) - 1]
	}

	transform :: proc(xform: Xform, v: ^V2) {
		// catch command and dont transform
		if v.y == max(f32) {
			return
		}

		temp := v^
		v.x = temp.x * xform[0] + temp.y * xform[2] + xform[4]
		v.y = temp.x * xform[1] + temp.y * xform[3] + xform[5]
	}

	// transform all points, commands are ignored
	values := values
	for v in &values {
		transform(state.xform, &v)
	}

	// copy transformed values over
	fa_add(&ctx.commands, values)
}

push_path :: proc(ctx: ^Context) {
	fa_clear(&ctx.commands)
	fa_clear(&ctx.cache.points)
	fa_clear(&ctx.cache.paths)
}

push_rect :: proc(ctx: ^Context, x, y, w, h: f32) {
	commands := [?]V2 {
		cmd2f(.Move_To), { x, y }, 
		cmd2f(.Line_To), { x, y + h }, 
		cmd2f(.Line_To), { x + w, y + h },
		cmd2f(.Line_To), { x + w, y },
		cmd2f(.Close),
	}
	ctx_append_commands(ctx, commands[:])
}

push_move_to :: proc(ctx: ^Context, x, y: f32) {
	commands := [?]V2 { cmd2f(.Move_To), { x, y }}
	ctx_append_commands(ctx, commands[:])
}

push_line_to :: proc(ctx: ^Context, x, y: f32) {
	commands := [?]V2 { cmd2f(.Line_To), { x, y }}
	ctx_append_commands(ctx, commands[:])
}

paths_add :: proc(ctx: ^Context) {
	fa_push(&ctx.cache.paths, Cache_Path {
		point_start = ctx.cache.points.index,
	})		
}

paths_close :: proc(ctx: ^Context) {
	path := fa_last(&ctx.cache.paths)
	if path == nil {
		return
	}
	path.closed = true		
}

point_equals :: proc(v0, v1: V2, tolerance: f32) -> bool {
	delta := v1 - v0
	return delta.x * delta.x + delta.y * delta.y < tolerance * tolerance
}

points_add :: proc(ctx: ^Context, v: V2, flags: Point_Flags) {
	path := fa_last(&ctx.cache.paths)
	if path == nil {
		return
	}

	if path.count > 0 && ctx.cache.points.index > 0 {
		pt := fa_last_unsafe(&ctx.cache.points)

		// check last point if its too close and replace it 
		if point_equals(pt.pos, v, ctx.distance_tolerance) {
			pt.flags |= flags
			return
		}
	}

	// add point + update count
	fa_push(&ctx.cache.points, Cache_Point {
		pos = v,
		flags = flags,
	})
	path.count += 1
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

paths_flatten :: proc(ctx: ^Context) {
	if fa_not_empty(ctx.cache.paths) {
		return
	}

	// add translated points to path
	i := 0
	for i < ctx.commands.index {
		cmd := f2cmd(ctx.commands.data[i])

		switch cmd {
		case .Move_To:
			paths_add(ctx)
			points_add(ctx, ctx.commands.data[i + 1], { .Corner })
			i += 2

		case .Line_To:
			points_add(ctx, ctx.commands.data[i + 1], { .Corner })
			i += 2
		
		case .Quadratic_To:
			// TODO others
			i += 3

		case .Cubic_To:
			// TODO others
			i += 4

		case .Close:
			paths_close(ctx)
			i += 1
		}
	}

	// gather aabb
	ctx.cache.bounds = {
		max(f32),
		max(f32),
		-max(f32),
		-max(f32),
	}

	// Calculate the direction and length of line segments.
	for j in 0..<ctx.cache.paths.index {
		path := &ctx.cache.paths.data[j]
		pts := ctx.cache.points.data[path.point_start:]

		// If the first and last points are the same, remove the last, mark as closed path.
		p0 := &pts[path.count-1]
		p1 := &pts[0]
		if point_equals(p0.pos, p1.pos, ctx.distance_tolerance) && path.count > 1 {
			path.count -= 1
			p0 = &pts[path.count - 1]
			path.closed = true
		}

		// TODO winding?
		// // enforce winding
		// if path.count > 2 {
		// 	area := __polyArea(pts[:path.count])
			
		// 	if path.winding == .CCW && area < 0 {
		// 		__polyReverse(pts[:path.count])
		// 	}
			
		// 	if path.winding == .CW && area > 0 {
		// 		__polyReverse(pts[:path.count])
		// 	}
		// }

		for k in 0..<path.count {
			// Calculate segment direction and length
			p0.delta = p1.pos - p0.pos
			p0.len = v2_normalize(&p0.delta)
			
			// Update bounds
			ctx.cache.bounds[0] = min(ctx.cache.bounds[0], p0.pos.x)
			ctx.cache.bounds[1] = min(ctx.cache.bounds[1], p0.pos.y)
			ctx.cache.bounds[2] = max(ctx.cache.bounds[2], p0.pos.x)
			ctx.cache.bounds[3] = max(ctx.cache.bounds[3], p0.pos.y)
			
			// Advance
			p0 = p1
			p1 = mem.ptr_offset(p1, 1)
		}
	}
}

fill :: proc(ctx: ^Context) {
	state := state_get(ctx)
	fill_paint := state.fill

	paths_flatten(ctx)
	// expand_fill()

	fill_paint.inner_color.a *= state.alpha
	fill_paint.outer_color.a *= state.alpha

	// for i in 0
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

@test
sparse_set_test :: proc() {
	set := sparse_set_make(10)
	sparse_set_print(&set)
	sparse_set_insert(&set, 3)
	sparse_set_print(&set)
	sparse_set_insert(&set, 3)
	sparse_set_print(&set)
	sparse_set_insert(&set, 4)
	sparse_set_print(&set)
	fmt.eprintln(sparse_set_contains(&set, 4))
	fmt.eprintln(sparse_set_contains(&set, 3))
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