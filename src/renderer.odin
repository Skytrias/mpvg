package src

import "core:mem"
import "core:fmt"
import "core:slice"
import "core:runtime"
import "core:math/rand"

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
	// raw curves that were inserted by the user
	curves: []Curve,
	curve_index: int,

	// tag along data processing curves
	contexts: []Implicizitation_Context,
	roots: []Roots,

	// result of monotization & implicitization
	output: []Implicit_Curve,
	output_index: int,

	// result of monotization & implicitization
	commands: []Renderer_Command,
	command_index: int,

	// tiling temp
	tiles: []Renderer_Tile,
	tile_index: int,
	tile_count: int,
	tiles_x: int,
	tiles_y: int,

	// font data
	font_pool: Pool(8, Font),
}

Renderer_Tile :: struct #packed {
	winding_number: i32,
	command_offset: i32,
	command_count: i32,
	pad3: i32,
	color: [4]f32,
}

Renderer_Command :: struct #packed {
	curve_index: i32,
	crossed_right: b32,
	tile_index: i32,
	pad1: i32,
}

renderer_init :: proc(renderer: ^Renderer) {
	renderer.output = make([]Implicit_Curve, 256)
	renderer.roots = make([]Roots, 256)
	renderer.contexts = make([]Implicizitation_Context, 256)
	renderer.curves = make([]Curve, 256)
	renderer.tiles = make([]Renderer_Tile, 1028)
	renderer.commands = make([]Renderer_Command, 1028)
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
	delete(renderer.tiles)
	delete(renderer.commands)

	// TODO destroy fonts
}

renderer_clear :: proc(
	renderer: ^Renderer, 
	tile_count: int,
	tiles_x: int,
	tiles_y: int,
) {
	renderer.curve_index = 0
	renderer.output_index = 0
	renderer.command_index = 1

	if renderer.tile_count != tile_count {
		for i in 0..<tile_count {
			renderer.tiles[i] = {
				color = {
					rand.float32(),
					rand.float32(),
					rand.float32(),
					1,
				},
			}
		}
	}

	renderer.tiles_x = tiles_x
	renderer.tiles_y = tiles_y
	renderer.tile_count = tile_count
	renderer.tile_index = tile_count
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

renderer_process_tiles :: proc(renderer: ^Renderer, width, height: f32) {
	for i in 0..<renderer.tile_count {
		tile := &renderer.tiles[i]
		tile.winding_number = 0
		tile.command_offset = 100_000
		tile.command_count = 0
	}

	start: [2]f32
	end: [2]f32

	// loop through all implicit curves
	curve_loop: for j in 0..<renderer.output_index {
		curve := &renderer.output[j]
		start = curve.box.xy
		end = curve.box.zw

		// swap
		if curve.orientation == .BL || curve.orientation == .TL {
			start, end = end, start
		}

		// loop through all tiles
		for x in 0..<renderer.tiles_x {
			for y in 0..<renderer.tiles_y {
				index := x + y * renderer.tiles_x
				tile := &renderer.tiles[index]

				// tile in real coordinates
				x1 := f32(x) / f32(renderer.tiles_x) * width
				y1 := f32(y) / f32(renderer.tiles_x) * height
				x2 := f32(x + 1) / f32(renderer.tiles_x) * width
				y2 := f32(y + 1) / f32(renderer.tiles_x) * height

				// inside tile check
				start_inside := x1 < end.x && y1 < end.y && end.x < x2 && end.y < y2 
				
				// inside tile check
				end_inside := x1 < start.x && y1 < start.y && start.x < x2 && start.y < y2 
		
				// left edge crossing (start->end or end->start)
				left_edge := (start.x < x1 && end.x > x1 || end.x < x1 && start.x > x1) && y1 < end.y && end.y < y2 

				// right edge crossing (start->end or end->start)
				right_edge := (start.x < x2 && end.x > x2 || end.x < x2 && start.x > x2) && y1 < end.y && end.y < y2

				// top edge crossing  (start->end or end->start)
				top_edge := (start.y < y1 && end.y > y1 || end.y < y1 && start.y > y1) && x1 < end.x && end.x < x2

				// -1 winding for every segement that crosses bottom edge
				// bottom edge crossing  (start->end or end->start)
				bottom_edge := (start.y < y2 && end.y > y2 || end.y < y2 && start.y > y2) && x1 < end.x && end.x < x2

				if end_inside || start_inside || left_edge || right_edge || top_edge || bottom_edge {
					cmd := Renderer_Command { curve_index = i32(j) }
					cmd.tile_index = i32(index)

					if right_edge {
						cmd.crossed_right = true
					}

					if bottom_edge {
						tile.winding_number += curve.winding_increment
					}

					renderer.commands[renderer.command_index] = cmd
					renderer.command_index += 1
					tile.command_count += 1
					// continue curve_loop
				}
			}

			// TEMP CHECK fill all curve data per tile
			// copy(renderer.final[renderer.final_index:], renderer.output[:renderer.output_index])
			// renderer.final_index += renderer.output_index
			// tile.curve_count = i32(renderer.output_index)
		}
	}	

	// sort by tile index on each command
	slice.sort_by(renderer.commands[:renderer.command_index], proc(a, b: Renderer_Command) -> bool {
		return a.tile_index < b.tile_index
	})

	// assign proper min offset to tile
	last := i32(100_000)
	for i in 0..<renderer.command_index {
		cmd := renderer.commands[i]
		defer last = cmd.tile_index

		if last == cmd.tile_index {
			continue
		}

		tile := &renderer.tiles[cmd.tile_index]
		tile.command_offset = min(tile.command_offset, i32(i))
	}

	// // post process winding?
	// for i in 0..<renderer.tile_index {
	// 	tile := &renderer.tiles[i]

	// 	if tile.command_offset != 100_000 {
	// 		fmt.eprintln("~~~i", i, tile.command_offset, tile.command_count)
	// 	}
	// }
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
