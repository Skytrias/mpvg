package src

import "core:runtime"
import "core:mem"
import "core:fmt"

///////////////////////////////////////////////////////////
// GENERIC PATH
///////////////////////////////////////////////////////////

Path :: struct {
	curves: []Curve,
	offset: int,
	last: [2]f32,
}

path_init :: proc(path: ^Path, curves: []Curve) {
	path.curves = curves
}

path_make :: proc(curves: []Curve) -> (res: Path) {
	path_init(&res, curves)
	return
}

path_move_to :: proc(path: ^Path, x, y: f32) {
	path.last = { x, y }
}

path_line_to :: proc(path: ^Path, x, y: f32) {
	path.curves[path.offset] = c1_make(path.last, { x, y })
	path.offset += 1
	path.last = { x, y }
}

path_quadratic_to :: proc(path: ^Path, x, y, cx, cy: f32) {
	path.curves[path.offset] = c2_make(path.last, { cx, cy }, { x, y })
	path.offset += 1
	path.last = { x, y }
}

path_cubic_to :: proc(path: ^Path, x, y, c1x, c1y, c2x, c2y: f32) {
	path.curves[path.offset] = c3_make(path.last, { c1x, c1y }, { c2x, c2y }, { x, y })
	path.offset += 1
	path.last = { x, y }
}

path_close :: proc(path: ^Path) {
	if path.offset > 0 {
		start := path.curves[0].B[0]
		path_line_to(path, start.x, start.y)
	}
}

path_finish_curves :: proc(path: ^Path, curves: ^[]Curve) {
	curves^ = curves[path.offset:]
}

path_triangle :: proc(path: ^Path, x, y, r: f32) {
	path_move_to(path, x, y - r/2)
	path_line_to(path, x - r/2, y + r/2)
	path_line_to(path, x + r/2, y + r/2)
	path_close(path)	
}

path_rect_test :: proc(path: ^Path, x, y, w, h: f32) {
	path_move_to(path, x, y)
	path_line_to(path, x - 50, y + h + 50)
	path_line_to(path, x + w - 50, y + h)
	path_line_to(path, x + w, y)
	path_close(path)
}

path_rect :: proc(path: ^Path, x, y, w, h: f32) {
	path_move_to(path, x, y)
	path_line_to(path, x, y + h)
	path_line_to(path, x + w, y + h)
	path_line_to(path, x + w, y)
	path_close(path)
}

path_print :: proc(path: ^Path) {
	fmt.eprintln("~~~")
	for i in 0..<path.offset {
		curve := path.curves[i]
		fmt.eprintln(curve.B[0], curve.B[1])
	}
}

path_ellipse :: proc(path: ^Path, cx, cy, rx, ry: f32) {
	path_move_to(path, cx-rx, cy)
	path_cubic_to(path, cx, cy+ry, cx-rx, cy+ry*KAPPA90, cx-rx*KAPPA90, cy+ry)
	path_cubic_to(path, cx+rx, cy, cx+rx*KAPPA90, cy+ry, cx+rx, cy+ry*KAPPA90)
	path_cubic_to(path, cx, cy-ry, cx+rx, cy-ry*KAPPA90, cx+rx*KAPPA90, cy-ry)
	path_cubic_to(path, cx-rx, cy, cx-rx*KAPPA90, cy-ry, cx-rx, cy-ry*KAPPA90)
	// path_close(path)
}

path_circle :: proc(path: ^Path, cx, cy, r: f32) {
	path_ellipse(path, cx, cy, r, r)
}

path_quadratic_test :: proc(path: ^Path, x, y: f32) {
	path_move_to(path, x, y)
	path_line_to(path, x + 50, y + 50)
	path_line_to(path, x + 60, y + 100)
	path_quadratic_to(path, x + 100, y + 150, x + 90, y)
	// path_close(path)
}

path_cubic_test :: proc(path: ^Path, x, y, r: f32, count: f32) {
	path_move_to(path, x, y)
	xx := x - r/2
	yy := y + r/2
	// off := (count * 0.05)
	off := f32(0)
	path_cubic_to(path, xx, yy, xx - off * 0.5, yy - 10, xx + 10 + off, yy - 15)
	// path_close(path)
}

///////////////////////////////////////////////////////////
// TEST RENDERER SETUP
///////////////////////////////////////////////////////////

Renderer :: struct {
	output: []Implicit_Curve,
	output_index: int,

	curves: []Curve,
	curve_index: int,

	contexts: []Implicizitation_Context,
	roots: []Roots,

	font_pool: Pool(8, Font),
}

renderer_init :: proc(renderer: ^Renderer) {
	renderer.output = make([]Implicit_Curve, 256)
	renderer.roots = make([]Roots, 256)
	renderer.contexts = make([]Implicizitation_Context, 256)
	renderer.curves = make([]Curve, 256)
	pool_clear(&renderer.font_pool)
}

renderer_make :: proc() -> (res: Renderer) {
	renderer_init(&res)
	return
}

renderer_destroy :: proc(renderer: ^Renderer) {
	delete(renderer.output)
	delete(renderer.curves)
	delete(renderer.roots)
	delete(renderer.contexts)

	// TODO destroy fonts
}

renderer_clear :: proc(renderer: ^Renderer) {
	renderer.curve_index = 0
	renderer.output_index = 0
}

renderer_path_make :: proc(renderer: ^Renderer) -> (res: Path) {
	path_init(&res, renderer.curves[renderer.curve_index:])
	return
}

renderer_path_finish :: proc(renderer: ^Renderer, path: ^Path) {
	renderer.curve_index += path.offset
}

renderer_process :: proc(using renderer: ^Renderer, scale, offset: [2]f32) {
	results := curves[:curve_index]
	// mem.zero_slice(roots[:])
	// mem.zero_slice(contexts[:])

	for c, i in results {
		preprocess1[c.count](c, &roots[i], &contexts[i])
	}

	for c, i in results {
		root := &roots[i]
		ctx := &contexts[i]
		preprocess2[c.count](output, &renderer.output_index, c, root, scale, offset, ctx)
	}
}

renderer_glyph_push :: proc(
	using renderer: ^Renderer, 
	glyph: rune, 
	scale: f32, 
	x, y: f32,
) -> f32 {
	// TODO allow font selection
	font := pool_at(&font_pool, 1)
	glyph := font_get_glyph(font, glyph)
	
	for c in glyph.curves {
		temp := illustration_to_image(c, scale, { x, y })
		renderer.curves[renderer.curve_index] = temp
		renderer.curve_index += 1
	}

	return glyph.advance * scale
}

renderer_text_push :: proc(
	using renderer: ^Renderer, 
	text: string,
	scale: f32, 
	x, y: f32, 
) {
	x := x
	for codepoint in text {
		x += renderer_glyph_push(renderer, codepoint, scale, x, y)
	}
}

renderer_font_push :: proc(renderer: ^Renderer, path: string) -> u32 {
	index := pool_alloc_index(&renderer.font_pool)
	font := pool_at(&renderer.font_pool, index)
	font_init(font, path)
	return index
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
