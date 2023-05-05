package src

import "core:mem"
import "core:fmt"
import "core:math"
import "core:slice"
import "core:runtime"
import "core:math/rand"
import glm "core:math/linalg/glsl"
import sa "core:container/small_array"
import gl "vendor:OpenGL"

MAX_STATES :: 32

shader_vert := #load("vertex.glsl")
shader_frag := #load("fragment.glsl")

when true {
	shader_compute := #load("mpvg.comp")
} else {
	shader_compute := #load("mpvg_non_tiling.comp")
}

Vertex :: struct {
	pos: [2]f32,
	uv: [2]f32,
}

KAPPA90 :: 0.5522847493 * 2

Paint :: struct {
	xform: glm.mat4, // paint affine transformation
	radius: f32,
	feather: f32,
	inner_color: [4]f32,
	outer_color: [4]f32,
	extent: [2]f32,
	image: u32,
}

Renderer_State :: struct {
	paint: Paint,
	xform: glm.mat4, // state affine transformation
}

Renderer :: struct {
	// raw curves that were inserted by the user
	curves: []Curve,
	curve_index: int,

	// curve temp
	curve_last: [2]f32,

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

	// uniform options
	color_mode: int,
	fill_rule: int,
	ignore_temp: int,

	// platform dependent implementation
	gpu: Renderer_GL,

	// small states
	states: sa.Small_Array(MAX_STATES, Renderer_State),
}

Renderer_GL :: struct {
	fill_vao: u32,
	fill_vbo: u32,
	fill_program: u32,
	fill_loc_projection: i32,

	compute_program: u32,
	compute_loc_color_mode: i32,
	compute_loc_fill_rule: i32,
	compute_loc_ignore_temp: i32,
	compute_texture_id: u32,

	compute_curves_ssbo: u32,
	compute_tiles_ssbo: u32,
	compute_commands_ssbo: u32,
}

Renderer_Tile :: struct #packed {
	winding_number: i32,
	command_offset: i32,
	command_count: i32,
	pad1: i32,

	color: [4]f32,
}

Renderer_Command :: struct #packed {
	curve_index: i32,
	crossed_right: b32,
	tile_index: i32,
	x: f32,
}

renderer_init :: proc(renderer: ^Renderer) {
	renderer.output = make([]Implicit_Curve, 256)
	renderer.roots = make([]Roots, 256)
	renderer.contexts = make([]Implicizitation_Context, 256)
	renderer.curves = make([]Curve, 256)
	renderer.tiles = make([]Renderer_Tile, 1028)
	renderer.commands = make([]Renderer_Command, 1028)
	pool_clear(&renderer.font_pool)

	renderer_gpu_gl_init(&renderer.gpu)

	renderer_state_save(renderer)
	renderer_state_reset(renderer)
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

	renderer_gpu_gl_destroy(&renderer.gpu)
	// TODO destroy fonts
}

renderer_start :: proc(
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

	renderer_gpu_gl_start(renderer)

	renderer.states.len = 0
	renderer_state_save(renderer)
	renderer_state_reset(renderer)
}

renderer_end :: proc(renderer: ^Renderer, width, height: int) {
	renderer_process(renderer)
	renderer_process_tiles(renderer, f32(width), f32(height))
	renderer_gpu_gl_end(renderer, width, height)
}

renderer_process :: proc(using renderer: ^Renderer) {
	results := curves[:curve_index]

	for c, i in results {
		preprocess1[c.count](c, &roots[i], &contexts[i])
	}

	for c, i in results {
		root := &roots[i]
		ctx := &contexts[i]
		preprocess2[c.count](output, &renderer.output_index, c, root, ctx)
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
	
	// // TODO
	// for c in glyph.curves {
	// 	temp := illustration_to_image(c, scale, { x, y })
	// 	renderer.curves[renderer.curve_index] = c
	// 	renderer.curve_index += 1
	// }

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

	path_area := [4]f32 {
		0, 0,
		width, height,
	}

	// loop through all implicit curves
	curve_loop: for j in 0..<renderer.output_index {
		curve := renderer.output[j]

		// swap
		if curve.orientation == .TL || curve.orientation == .BR {
			start = curve.box.xy
			end = curve.box.zw
		} else {
			start = curve.box.xw
			end = curve.box.zy
		}

		// TODO minimize iteration
		// covered_tiles := curve.box / 32
		// xmin := int(max(0, covered_tiles.x - path_area.x))
		// ymin := int(max(0, covered_tiles.y - path_area.y))
		// xmax := int(min(covered_tiles.z - path_area.x, path_area.z - 1))
		// ymax := int(min(covered_tiles.w - path_area.y, path_area.w - 1))
		// fmt.eprintln(xmin, ymin, xmax, ymax)
		// for x in xmin..<xmax {
		// 	for y in ymin..<ymax {

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

				sbl := curve_eval(curve, { x1, y1 })
				sbr := curve_eval(curve, { x2, y1 })
				str := curve_eval(curve, { x2, y2 })
				stl := curve_eval(curve, { x1, y2 })

				crossL := (stl * sbl) < 0
				crossR := (str * sbr) < 0
				crossT := (stl * str) < 0
				crossB := (sbl * sbr) < 0

				start_inside := start.x >= x1 && start.x < x2 && start.y >= y1 && start.y < y2
				end_inside := end.x >= x1 && end.x < x2 && end.y >= y1 && end.y < y2

				if end_inside || start_inside || crossL || crossR || crossT || crossB {
					cmd := Renderer_Command { curve_index = i32(j) }
					cmd.tile_index = i32(index)
					cmd.x = min(curve.box.x, curve.box.z)

					if crossR {
						cmd.crossed_right = true
					}

					if crossB {
						tile.winding_number += curve.winding_increment
						// tile.winding_number += start.x < x1 ? -1 : end.x > x2 ? 1 : 0
					}

					renderer.commands[renderer.command_index] = cmd
					renderer.command_index += 1
					tile.command_count += 1
				}
			}
		}
	}	

	// sort by tile index on each command
	slice.sort_by(renderer.commands[:renderer.command_index], proc(a, b: Renderer_Command) -> bool {
		return a.tile_index < b.tile_index 
	})

	// TODO optimize to not use a for loop on all commands
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

	for i in 0..<renderer.tile_count {
		tile := &renderer.tiles[i]
		
		if tile.command_offset != 100_000 {
			// fmt.eprintln(tile.command_offset, tile.command_count)
			slice.sort_by(renderer.commands[tile.command_offset:tile.command_offset + tile.command_count], proc(a, b: Renderer_Command) -> bool {
				// return a.x < b.x
				return a.curve_index < b.curve_index
			})
		}
	}

	// prefix sum backpropogation
	if true {
		for y in 0..<renderer.tiles_y {
			sum: i32

			for x := renderer.tiles_x - 1; x >= 0; x -= 1 {
				index := x + y * renderer.tiles_x
				tile := &renderer.tiles[index]
				temp := tile.winding_number
				tile.winding_number = sum
				sum += temp
			}
		}
	}
}

renderer_gpu_gl_init :: proc(using gpu: ^Renderer_GL) {
	{
		gl.GenVertexArrays(1, &fill_vao)
		gl.BindVertexArray(fill_vao)
		defer gl.BindVertexArray(0)

		gl.GenBuffers(1, &fill_vbo)
		gl.BindBuffer(gl.ARRAY_BUFFER, fill_vbo)

		size := i32(size_of(Vertex))
		gl.VertexAttribPointer(0, 2, gl.FLOAT, gl.FALSE, size, 0)
		gl.EnableVertexAttribArray(0)
		gl.VertexAttribPointer(1, 2, gl.FLOAT, gl.FALSE, size, offset_of(Vertex, uv))
		gl.EnableVertexAttribArray(1)

		ok: bool
		fill_program, ok = gl.shader_load_sources({ 
			{ shader_vert, .VERTEX }, 
			{ shader_frag, .FRAGMENT },
		})
		if !ok {
			panic("failed loading frag/vert shader")
		}

		fill_loc_projection = gl.GetUniformLocation(fill_program, "projection")
	}
	
	{
		ok: bool
		compute_program, ok = gl.shader_load_sources({{ shader_compute, .COMPUTE }})
		if !ok {
			panic("failed loading compute shader")
		}
		compute_loc_color_mode = gl.GetUniformLocation(compute_program, "color_mode")
		compute_loc_fill_rule = gl.GetUniformLocation(compute_program, "fill_rule")
		compute_loc_ignore_temp = gl.GetUniformLocation(compute_program, "ignore_temp")

		gl.GenTextures(1, &compute_texture_id)
		gl.BindTexture(gl.TEXTURE_2D, compute_texture_id)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
		gl.BindImageTexture(0, compute_texture_id, 0, gl.FALSE, 0, gl.WRITE_ONLY, gl.RGBA8)

		{
			// TODO dynamic width/height or finite big one
			w := 800
			h := 800
			gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, i32(w), i32(h), 0, gl.RGBA, gl.UNSIGNED_BYTE, nil)
		}
		gl.BindTexture(gl.TEXTURE_2D, 0)

		gl.GenBuffers(1, &compute_curves_ssbo)
		gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, compute_curves_ssbo)

		gl.GenBuffers(1, &compute_tiles_ssbo)
		gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, compute_tiles_ssbo)

		gl.GenBuffers(1, &compute_commands_ssbo)
		gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, compute_commands_ssbo)
	}
}

renderer_gpu_gl_destroy :: proc(using gpu: ^Renderer_GL) {

}

renderer_gpu_gl_start :: proc(renderer: ^Renderer) {

}

renderer_gpu_gl_end :: proc(renderer: ^Renderer, width, height: int) {
	gpu := &renderer.gpu
	using gpu

	gl.UseProgram(compute_program)
	gl.Uniform1i(compute_loc_color_mode, i32(renderer.color_mode))
	gl.Uniform1i(compute_loc_fill_rule, i32(renderer.fill_rule))
	gl.Uniform1i(compute_loc_ignore_temp, i32(renderer.ignore_temp))

	gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 0, compute_curves_ssbo)
	gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, compute_curves_ssbo)
	gl.BufferData(gl.SHADER_STORAGE_BUFFER, renderer.output_index * size_of(Implicit_Curve), raw_data(renderer.output), gl.STREAM_DRAW)

	gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 1, compute_tiles_ssbo)
	gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, compute_tiles_ssbo)
	gl.BufferData(gl.SHADER_STORAGE_BUFFER, renderer.tile_index * size_of(Renderer_Tile), raw_data(renderer.tiles), gl.STREAM_DRAW)

	gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 2, compute_commands_ssbo)
	gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, compute_commands_ssbo)
	gl.BufferData(gl.SHADER_STORAGE_BUFFER, renderer.command_index * size_of(Renderer_Command), raw_data(renderer.commands), gl.STREAM_DRAW)

	gl.DispatchCompute(u32(renderer.tiles_x), u32(renderer.tiles_y), 1)
	gl.MemoryBarrier(gl.SHADER_IMAGE_ACCESS_BARRIER_BIT)

	// fill texture

	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
	gl.Disable(gl.CULL_FACE)
	gl.Disable(gl.DEPTH_TEST)
	gl.BindVertexArray(fill_vao)
	gl.UseProgram(fill_program)

	projection := glm.mat4Ortho3d(0, f32(width), f32(height), 0, 0, 1)
	gl.UniformMatrix4fv(fill_loc_projection, 1, gl.FALSE, &projection[0][0])

	gl.BindTexture(gl.TEXTURE_2D, compute_texture_id)
	gl.BindBuffer(gl.ARRAY_BUFFER, fill_vbo)

	{
		w := f32(width)
		h := f32(height)
		data := [6]Vertex {
			{{ 0, 0 }, { 0, 0 }},
			{{ 0, h }, { 0, 1 }},
			{{ w, 0 }, { 1, 0 }},
			{{ 0, h }, { 0, 1 }},
			{{ w, 0 }, { 1, 0 }},
			{{ w, h }, { 1, 1 }},
		}
		gl.BufferData(gl.ARRAY_BUFFER, size_of(data), &data[0], gl.STREAM_DRAW)
		gl.DrawArrays(gl.TRIANGLES, 0, 6)
	}
}

///////////////////////////////////////////////////////////
// STATE
///////////////////////////////////////////////////////////

renderer_state_save :: proc(using renderer: ^Renderer) {
	length := states.len

	if length >= len(states.data) {
		return
	}

	if length > 0 {
		states.data[length] = states.data[length - 1]
	}

	states.len += 1
}

renderer_state_restore :: proc(using renderer: ^Renderer) {
	if states.len <= 1 {
		return
	}

	states.len -= 1
}

paint_set_color :: proc(renderer: ^Renderer, paint: ^Paint, color: [4]f32) {
	paint^ = {}
	paint.xform = glm.identity(glm.mat4)
	paint.feather = 1
	paint.inner_color = color
	paint.outer_color = color
}

renderer_state_reset :: proc(using renderer: ^Renderer) {
	state := renderer_state_get(renderer)
	state^ = {}
	paint_set_color(renderer, &state.paint, { 1, 0, 0, 1 })
	state.xform = glm.identity(glm.mat4)
}

renderer_state_get :: #force_inline proc(using renderer: ^Renderer) -> ^Renderer_State #no_bounds_check {
	return &states.data[states.len - 1]
}

renderer_state_fill_color :: proc(using renderer: ^Renderer, color: [4]f32) {
	state := renderer_state_get(renderer)
	paint_set_color(renderer, &state.paint, color)
}

renderer_state_fill_paint :: proc(using renderer: ^Renderer, paint: Paint) {
	state := renderer_state_get(renderer)
	state.paint = paint
	state.paint.xform *= state.xform
}

renderer_state_reset_transform :: proc(using renderer: ^Renderer) {
	state := renderer_state_get(renderer)
	state.xform = glm.identity(glm.mat4)
}

renderer_state_translate :: proc(using renderer: ^Renderer, x, y: f32) {
	state := renderer_state_get(renderer)
	temp := glm.mat4Translate({ x, y, 0 })
	mat4_premultiply(&state.xform, temp)
}

renderer_state_rotate :: proc(using renderer: ^Renderer, angle: f32) {
	state := renderer_state_get(renderer)
	temp := glm.mat4Rotate({ 0, 0, 1 }, angle)
	mat4_premultiply(&state.xform, temp)
}

renderer_state_skewx :: proc(using renderer: ^Renderer, angle: f32) {
	state := renderer_state_get(renderer)
	temp := mat4_skew_x(angle)
	mat4_premultiply(&state.xform, temp)
}

renderer_state_skewy :: proc(using renderer: ^Renderer, angle: f32) {
	state := renderer_state_get(renderer)
	temp := mat4_skew_y(angle)
	mat4_premultiply(&state.xform, temp)
}

renderer_state_scale :: proc(using renderer: ^Renderer, x, y: f32) {
	state := renderer_state_get(renderer)
	temp := glm.mat4Scale({ x, y, 0 })
	mat4_premultiply(&state.xform, temp)
}

v2_transform :: proc(input: [2]f32, xform: glm.mat4) -> [2]f32 {
	return {
		input.x * xform[0, 0] + input.y * xform[1, 0] + xform[0, 3],
		input.x * xform[0, 1] + input.y * xform[1, 1] + xform[1, 3],
	}
}

mat4_skew_x :: proc(a: f32) -> (t: glm.mat4) {
	t = glm.identity(glm.mat4)
	t[1, 0] = math.tan(a) 
	return
}

mat4_skew_y :: proc(a: f32) -> (t: glm.mat4) {
	t = glm.identity(glm.mat4)
	t[0, 1] = math.tan(a) 
	return
}

// multiply temp with a and set temp to a
mat4_premultiply :: proc(a: ^glm.mat4, b: glm.mat4) {
	temp := b
	temp *= a^
	a^ = temp
}

///////////////////////////////////////////////////////////
// PATH
///////////////////////////////////////////////////////////

renderer_move_to :: proc(renderer: ^Renderer, x, y: f32) {
	state := renderer_state_get(renderer)
	renderer.curve_last = { x, y }
}

renderer_move_to_rel :: proc(renderer: ^Renderer, x, y: f32) {
	state := renderer_state_get(renderer)
	renderer.curve_last = renderer.curve_last + { x, y }
}

renderer_line_to :: proc(using renderer: ^Renderer, x, y: f32) {
	state := renderer_state_get(renderer)
	curves[curve_index] = c1_make(
		v2_transform(curve_last, state.xform), 
		v2_transform({ x, y }, state.xform),
	)
	curve_index += 1
	curve_last = { x, y }
}

renderer_line_to_rel :: proc(using renderer: ^Renderer, x, y: f32) {
	state := renderer_state_get(renderer)
	curves[curve_index] = c1_make(
		v2_transform(curve_last, state.xform), 
		v2_transform(curve_last + { x, y }, state.xform),
	)
	curve_index += 1
	curve_last = curve_last + { x, y }
}

renderer_vertical_line_to :: proc(using renderer: ^Renderer, y: f32) {
	state := renderer_state_get(renderer)
	curves[curve_index] = c1_make(
		v2_transform(curve_last, state.xform), 
		v2_transform({ curve_last.x, y }, state.xform),
	)
	curve_index += 1
	curve_last = { curve_last.x, y }
}

renderer_horizontal_line_to :: proc(using renderer: ^Renderer, x: f32) {
	state := renderer_state_get(renderer)
	curves[curve_index] = c1_make(
		v2_transform(curve_last, state.xform), 
		v2_transform({ x, curve_last.y }, state.xform),
	)
	curve_index += 1
	curve_last = { x, curve_last.y }
}

renderer_quadratic_to :: proc(using renderer: ^Renderer, x, y, cx, cy: f32) {
	state := renderer_state_get(renderer)
	curves[curve_index] = c2_make(
		v2_transform(curve_last, state.xform), 
		v2_transform({ cx, cy }, state.xform), 
		v2_transform({ x, y }, state.xform),
	)
	curve_index += 1
	curve_last = { x, y }
}

renderer_quadratic_to_rel :: proc(using renderer: ^Renderer, x, y, cx, cy: f32) {
	state := renderer_state_get(renderer)
	curves[curve_index] = c2_make(
		v2_transform(curve_last, state.xform), 
		v2_transform(curve_last + { cx, cy }, state.xform),
		v2_transform(curve_last + { x, y }, state.xform),
	)
	curve_index += 1
	curve_last = curve_last + { x, y }
}

renderer_cubic_to :: proc(using renderer: ^Renderer, x, y, c1x, c1y, c2x, c2y: f32) {
	state := renderer_state_get(renderer)
	curves[curve_index] = c3_make(
		v2_transform(curve_last, state.xform),
		v2_transform({ c1x, c1y }, state.xform),
		v2_transform({ c2x, c2y }, state.xform),
		v2_transform({ x, y }, state.xform),
	)
	curve_index += 1
	curve_last = { x, y }
}

renderer_cubic_to_rel :: proc(using renderer: ^Renderer, x, y, c1x, c1y, c2x, c2y: f32) {
	state := renderer_state_get(renderer)
	curves[curve_index] = c3_make(
		v2_transform(curve_last, state.xform),
		v2_transform(curve_last + { c1x, c1y }, state.xform),
		v2_transform(curve_last + { c2x, c2y }, state.xform),
		v2_transform(curve_last + { x, y },state.xform),
	)
	curve_index += 1
	curve_last = curve_last + { x, y }
}

renderer_close :: proc(using renderer: ^Renderer) {
	if curve_index > 0 {
		state := renderer_state_get(renderer)
		start := curves[0].B[0]

		curves[curve_index] = c1_make(
			v2_transform(curve_last, state.xform), 
			{ start.x, start.y },
		)
		
		curve_index += 1
		curve_last = { start.x, start.y }
	}
}

renderer_triangle :: proc(renderer: ^Renderer, x, y, r: f32) {
	renderer_move_to(renderer, x, y - r/2)
	renderer_line_to(renderer, x - r/2, y + r/2)
	renderer_line_to(renderer, x + r/2, y + r/2)
	renderer_close(renderer)	
}

renderer_rect :: proc(renderer: ^Renderer, x, y, w, h: f32) {
	renderer_move_to(renderer, x, y)
	renderer_line_to(renderer, x, y + h)
	renderer_line_to(renderer, x + w, y + h)
	renderer_line_to(renderer, x + w, y)
	renderer_close(renderer)
}

// renderer_print :: proc(renderer: ^Renderer) {
// 	fmt.eprintln("~~~")
// 	for i in 0..<renderer.offset {
// 		curve := renderer.curves[i]
// 		fmt.eprintln(curve.B[0], curve.B[1])
// 	}
// }

// renderer_ellipse :: proc(renderer: ^Renderer, cx, cy, rx, ry: f32) {
// 	renderer_move_to(renderer, cx-rx, cy)
// 	renderer_cubic_to(renderer, cx, cy+ry, cx-rx, cy+ry*KAPPA90, cx-rx*KAPPA90, cy+ry)
// 	renderer_cubic_to(renderer, cx+rx, cy, cx+rx*KAPPA90, cy+ry, cx+rx, cy+ry*KAPPA90)
// 	renderer_cubic_to(renderer, cx, cy-ry, cx+rx, cy-ry*KAPPA90, cx+rx*KAPPA90, cy-ry)
// 	renderer_cubic_to(renderer, cx-rx, cy, cx-rx*KAPPA90, cy-ry, cx-rx, cy-ry*KAPPA90)
// 	// renderer_close(renderer)
// }

// renderer_circle :: proc(renderer: ^Renderer, cx, cy, r: f32) {
// 	renderer_ellipse(renderer, cx, cy, r, r)
// }

// renderer_quadratic_test :: proc(renderer: ^Renderer, x, y: f32) {
// 	renderer_move_to(renderer, x, y)
// 	renderer_line_to(renderer, x + 50, y + 50)
// 	renderer_line_to(renderer, x + 60, y + 100)
// 	renderer_quadratic_to(renderer, x + 100, y + 150, x + 90, y)
// 	// renderer_close(renderer)
// }

// renderer_cubic_test :: proc(renderer: ^Renderer, x, y, r: f32, count: f32) {
// 	renderer_move_to(renderer, x, y)
// 	xx := x - r/2
// 	yy := y + r/2
// 	// off := (count * 0.05)
// 	off := f32(0)
// 	renderer_cubic_to(renderer, xx, yy, xx - off * 0.5, yy - 10, xx + 10 + off, yy - 15)
// 	// renderer_close(renderer)
// }

// renderer_mpvg_test :: proc(renderer: ^Renderer, x, y: f32) {
// 	renderer_move_to(renderer, x, y)
	
// 	// red
// 	// renderer_quadratic_to_rel(renderer, 0, 0, -20, -40)
// 	renderer_line_to_rel(renderer, -10, -40)
// 	renderer_quadratic_to_rel(renderer, 40, 50, 10, 20)
// 	// renderer_line_to_rel(renderer, 40, -50)
// 	renderer_line_to_rel(renderer, 10, 0)
// 	renderer_line_to_rel(renderer, 20, 20)
	
// 	// black
// 	renderer_line_to_rel(renderer, 40, 30)
// 	renderer_line_to_rel(renderer, 35, -20)
// 	renderer_line_to_rel(renderer, 40, -20)
// 	renderer_line_to_rel(renderer, 20, 0)
// 	renderer_line_to_rel(renderer, 10, 10)
	
// 	// orange
// 	renderer_line_to_rel(renderer, 5, 10)
// 	renderer_line_to_rel(renderer, -10, 20)
// 	renderer_line_to_rel(renderer, -10, 25)
// 	renderer_line_to_rel(renderer, 5, 10)
	
// 	// blue
// 	renderer_line_to_rel(renderer, 5, 10)
// 	renderer_line_to_rel(renderer, -70, 20)
	
// 	// green
// 	// renderer_line_to_rel(renderer, -70, 20)
	
// 	renderer_close(renderer)
// }

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
