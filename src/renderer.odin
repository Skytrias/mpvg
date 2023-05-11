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
shader_compute_implicitize := #load("mpvg_implicitize.comp")
shader_compute_tile_backprop := #load("mpvg_tile_backprop.comp")

USE_TILING :: true

when USE_TILING {
	shader_compute_raster := #load("mpvg_raster_tiling.comp")
} else {
	shader_compute_raster := #load("mpvg_raster_non_tiling.comp")
}

Xform :: [6]f32

Vertex :: struct {
	pos: [2]f32,
	uv: [2]f32,
}

KAPPA90 :: 0.5522847493

Paint :: struct {
	xform: Xform, // paint affine transformation
	radius: f32,
	feather: f32,
	inner_color: [4]f32,
	outer_color: [4]f32,
	extent: [2]f32,
	image: u32,
}

Renderer_State :: struct {
	paint: Paint,
	xform: Xform, // state affine transformation
}

// glsl std140 layout
// indices that will get advanced in compute shaders!
Renderer_Indices :: struct #packed {
	implicit_curves: i32,
	commands: i32,
	pad1: i32,
	pad2: i32,
}

Renderer :: struct {
	// raw curves that were inserted by the user
	curves: []Curve,
	curve_index: int,
	curve_last: [2]f32, // temp last point in path creation

	// result of monotization & implicitization
	implicit_curves: []Implicit_Curve,

	// indices that will get advanced on the gpu	
	indices: Renderer_Indices,

	// result of monotization & implicitization
	commands: []Renderer_Command,

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
	fill: struct {
		vao: u32,
		vbo: u32,
		program: u32,
		loc_projection: i32,
	},

	implicitize: struct {
		program: u32,
	}

	raster: struct {
		program: u32,
		loc_color_mode: i32,
		loc_fill_rule: i32,
		loc_ignore_temp: i32,
		texture_id: u32,
	},

	backprop: struct {
		program: u32,
	},

	indices_ssbo: u32,
	curves_ssbo: u32,
	implicit_curves_ssbo: u32,
	tiles_ssbo: u32,
	commands_ssbo: u32,
}

Renderer_Tile :: struct #packed {
	winding_offset: i32,
	command_offset: i32,
	command_count: i32,
	pad1: i32,

	color: [4]f32,
}

Renderer_Command :: struct #packed {
	curve_index: i32,
	tile_index: i32,
	cross_right: b32,
	pad1: i32	
}

MAX_CURVES :: 256
MAX_IMPLICIT_CURVES :: 256
MAX_TILES :: 1028
MAX_COMMANDS :: 1028

renderer_init :: proc(renderer: ^Renderer) {
	renderer.curves = make([]Curve, MAX_CURVES)
	renderer.implicit_curves = make([]Implicit_Curve, MAX_IMPLICIT_CURVES)
	renderer.tiles = make([]Renderer_Tile, MAX_TILES)
	renderer.commands = make([]Renderer_Command, MAX_COMMANDS)
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
	delete(renderer.implicit_curves)
	delete(renderer.curves)
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
	renderer.indices.implicit_curves = 0
	renderer.indices.commands = 1 // TODO maybe do 1?

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

	// TODO could do this on GPU, maybe happens during path setup?
	// reset winding offsets
	for i in 0..<renderer.tile_count {
		tile := &renderer.tiles[i]
		tile.winding_offset = 0
		tile.command_offset = 0
		tile.command_count = 0
	}

	renderer_gpu_gl_start(renderer)

	renderer.states.len = 0
	renderer_state_save(renderer)
	renderer_state_reset(renderer)
}

renderer_end :: proc(using renderer: ^Renderer, width, height: int) {
	renderer_gpu_gl_end(renderer, width, height)
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

// renderer_process_tiles :: proc(renderer: ^Renderer, width, height: f32) {
// 	for i in 0..<renderer.tile_count {
// 		tile := &renderer.tiles[i]
// 		tile.winding_number = 0
// 		tile.command_offset = 100_000
// 		tile.command_count = 0
// 	}

// 	start: [2]f32
// 	end: [2]f32

// 	path_area := [4]f32 {
// 		0, 0,
// 		width, height,
// 	}

// 	// loop through all implicit curves
// 	curve_loop: for j in 0..<renderer.output_index {
// 		curve := renderer.output[j]

// 		// swap
// 		if curve.orientation == .TL || curve.orientation == .BR {
// 			start = curve.box.xy
// 			end = curve.box.zw
// 		} else {
// 			start = curve.box.xw
// 			end = curve.box.zy
// 		}

// 		// TODO minimize iteration
// 		// covered_tiles := curve.box / 32
// 		// xmin := int(max(0, covered_tiles.x - path_area.x))
// 		// ymin := int(max(0, covered_tiles.y - path_area.y))
// 		// xmax := int(min(covered_tiles.z - path_area.x, path_area.z - 1))
// 		// ymax := int(min(covered_tiles.w - path_area.y, path_area.w - 1))
// 		// fmt.eprintln(xmin, ymin, xmax, ymax)
// 		// for x in xmin..<xmax {
// 		// 	for y in ymin..<ymax {

// 		// loop through all tiles
// 		for x in 0..<renderer.tiles_x {
// 			for y in 0..<renderer.tiles_y {
// 				index := x + y * renderer.tiles_x
// 				tile := &renderer.tiles[index]

// 				// tile in real coordinates
// 				x1 := f32(x) / f32(renderer.tiles_x) * width
// 				y1 := f32(y) / f32(renderer.tiles_x) * height
// 				x2 := f32(x + 1) / f32(renderer.tiles_x) * width
// 				y2 := f32(y + 1) / f32(renderer.tiles_x) * height

// 				sbl := curve_eval(curve, { x1, y1 })
// 				sbr := curve_eval(curve, { x2, y1 })
// 				str := curve_eval(curve, { x2, y2 })
// 				stl := curve_eval(curve, { x1, y2 })

// 				crossL := (stl * sbl) < 0
// 				crossR := (str * sbr) < 0
// 				crossT := (stl * str) < 0
// 				crossB := (sbl * sbr) < 0

// 				start_inside := start.x >= x1 && start.x < x2 && start.y >= y1 && start.y < y2
// 				end_inside := end.x >= x1 && end.x < x2 && end.y >= y1 && end.y < y2

// 				if end_inside || start_inside || crossL || crossR || crossT || crossB {
// 					cmd := Renderer_Command { curve_index = i32(j) }
// 					cmd.tile_index = i32(index)
// 					cmd.x = min(curve.box.x, curve.box.z)

// 					if crossR {
// 						cmd.crossed_right = true
// 					}

// 					if crossB {
// 						tile.winding_number += curve.winding_increment
// 					}

// 					renderer.commands[renderer.command_index] = cmd
// 					renderer.command_index += 1
// 					tile.command_count += 1
// 				}
// 			}
// 		}
// 	}	

// 	// sort by tile index on each command
// 	slice.sort_by(renderer.commands[:renderer.command_index], proc(a, b: Renderer_Command) -> bool {
// 		return a.tile_index < b.tile_index 
// 	})

// 	// TODO optimize to not use a for loop on all commands
// 	// assign proper min offset to tile
// 	last := i32(100_000)
// 	for i in 0..<renderer.command_index {
// 		cmd := renderer.commands[i]
// 		defer last = cmd.tile_index

// 		if last == cmd.tile_index {
// 			continue
// 		}

// 		tile := &renderer.tiles[cmd.tile_index]
// 		tile.command_offset = min(tile.command_offset, i32(i))
// 	}

// 	// for i in 0..<renderer.tile_count {
// 	// 	tile := &renderer.tiles[i]
		
// 	// 	if tile.command_offset != 100_000 {
// 	// 		// fmt.eprintln(tile.command_offset, tile.command_count)
// 	// 		slice.sort_by(renderer.commands[tile.command_offset:tile.command_offset + tile.command_count], proc(a, b: Renderer_Command) -> bool {
// 	// 			return a.x < b.x
// 	// 			// return a.curve_index < b.curve_index
// 	// 		})
// 	// 	}
// 	// }

// 	// prefix sum backpropogation
// 	if true {
// 		for y in 0..<renderer.tiles_y {
// 			sum: i32

// 			for x := renderer.tiles_x - 1; x >= 0; x -= 1 {
// 				index := x + y * renderer.tiles_x
// 				tile := &renderer.tiles[index]
// 				temp := tile.winding_number
// 				tile.winding_number = sum
// 				sum += temp
// 			}
// 		}
// 	}
// }

renderer_gpu_gl_init :: proc(using gpu: ^Renderer_GL) {
	{
		gl.GenVertexArrays(1, &fill.vao)
		gl.BindVertexArray(fill.vao)
		defer gl.BindVertexArray(0)

		gl.GenBuffers(1, &fill.vbo)
		gl.BindBuffer(gl.ARRAY_BUFFER, fill.vbo)

		size := i32(size_of(Vertex))
		gl.VertexAttribPointer(0, 2, gl.FLOAT, gl.FALSE, size, 0)
		gl.EnableVertexAttribArray(0)
		gl.VertexAttribPointer(1, 2, gl.FLOAT, gl.FALSE, size, offset_of(Vertex, uv))
		gl.EnableVertexAttribArray(1)

		ok: bool
		fill.program, ok = gl.load_shaders_source(string(shader_vert), string(shader_frag))
		if !ok {
			panic("failed loading frag/vert shader")
		}

		fill.loc_projection = gl.GetUniformLocation(fill.program, "projection")
	}
	
	{
		ok: bool
		raster.program, ok = gl.load_compute_source(string(shader_compute_raster))
		if !ok {
			panic("failed loading compute shader")
		}
		raster.loc_color_mode = gl.GetUniformLocation(raster.program, "color_mode")
		raster.loc_fill_rule = gl.GetUniformLocation(raster.program, "fill_rule")
		raster.loc_ignore_temp = gl.GetUniformLocation(raster.program, "ignore_temp")

		gl.GenTextures(1, &raster.texture_id)
		gl.BindTexture(gl.TEXTURE_2D, raster.texture_id)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
		gl.BindImageTexture(0, raster.texture_id, 0, gl.FALSE, 0, gl.WRITE_ONLY, gl.RGBA8)

		{
			// TODO dynamic width/height or finite big one
			w := 800
			h := 800
			gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, i32(w), i32(h), 0, gl.RGBA, gl.UNSIGNED_BYTE, nil)
		}
		gl.BindTexture(gl.TEXTURE_2D, 0)
	}

	{
		ok: bool
		implicitize.program, ok = gl.load_compute_source(string(shader_compute_implicitize))
		if !ok {
			panic("failed loading compute shader")
		}
	}

	{
		ok: bool
		backprop.program, ok = gl.load_compute_source(string(shader_compute_tile_backprop))
		if !ok {
			panic("failed loading compute shader")
		}
	}

	gl.CreateBuffers(1, &indices_ssbo)
	gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, indices_ssbo)
	gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 0, indices_ssbo)
	gl.NamedBufferData(indices_ssbo, 1 * size_of(Renderer_Indices), nil, gl.STREAM_DRAW)

	gl.CreateBuffers(1, &curves_ssbo)
	gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, curves_ssbo)
	gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 1, curves_ssbo)
	gl.NamedBufferData(curves_ssbo, MAX_CURVES * size_of(Curve), nil, gl.STREAM_DRAW)

	gl.CreateBuffers(1, &implicit_curves_ssbo)
	gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, implicit_curves_ssbo)
	gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 2, implicit_curves_ssbo)
	gl.NamedBufferData(implicit_curves_ssbo, MAX_IMPLICIT_CURVES * size_of(Implicit_Curve), nil, gl.STREAM_DRAW)

	gl.CreateBuffers(1, &tiles_ssbo)
	gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, tiles_ssbo)
	gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 3, tiles_ssbo)
	gl.NamedBufferData(tiles_ssbo, MAX_TILES * size_of(Renderer_Tile), nil, gl.STREAM_DRAW)

	gl.CreateBuffers(1, &commands_ssbo)
	gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, commands_ssbo)
	gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 4, commands_ssbo)
	gl.NamedBufferData(commands_ssbo, MAX_COMMANDS * size_of(Renderer_Command), nil, gl.STREAM_DRAW)
}

renderer_gpu_gl_destroy :: proc(using gpu: ^Renderer_GL) {

}

renderer_gpu_gl_start :: proc(renderer: ^Renderer) {

}

renderer_gpu_gl_end :: proc(renderer: ^Renderer, width, height: int) {
	gpu := &renderer.gpu
	using gpu

	// implicitize stage
	{
		gl.UseProgram(implicitize.program)

		gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, indices_ssbo)
		gl.NamedBufferSubData(indices_ssbo, 0, 1 * size_of(Renderer_Indices), &renderer.indices)

		gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, curves_ssbo)
		gl.NamedBufferSubData(curves_ssbo, 0, renderer.curve_index * size_of(Curve), raw_data(renderer.curves))

		gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, tiles_ssbo)
		gl.NamedBufferSubData(tiles_ssbo, 0, renderer.tile_index * size_of(Renderer_Tile), raw_data(renderer.tiles))

		gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, implicit_curves_ssbo)

		gl.DispatchCompute(u32(renderer.curve_index), 1, 1)
	}

	// tile backprop stage
	{
		gl.UseProgram(backprop.program)
		gl.DispatchCompute(u32(renderer.tiles_x), 1, 1)
		gl.MemoryBarrier(gl.SHADER_STORAGE_BARRIER_BIT)
	}

	// raster stage
	{
		gl.UseProgram(raster.program)

		gl.Uniform1i(raster.loc_color_mode, i32(renderer.color_mode))
		gl.Uniform1i(raster.loc_fill_rule, i32(renderer.fill_rule))
		gl.Uniform1i(raster.loc_ignore_temp, i32(renderer.ignore_temp))

		when USE_TILING {
			gl.DispatchCompute(u32(renderer.tiles_x), u32(renderer.tiles_y), 1)
		} else {
			gl.DispatchCompute(u32(width), u32(height), 1)
		}

		gl.MemoryBarrier(gl.SHADER_IMAGE_ACCESS_BARRIER_BIT)

		// gl.GetNamedBufferSubData(indices_ssbo, 0, 1 * size_of(Renderer_Indices), &renderer.indices)
		// gl.GetNamedBufferSubData(
		// 	implicit_curves_ssbo, 
		// 	0, int(renderer.indices.implicit_curves) * size_of(Implicit_Curve), 
		// 	raw_data(renderer.implicit_curves),
		// )
		// for i in 0..<renderer.indices.implicit_curves {
		// 	c := renderer.implicit_curves[i]
		// 	fmt.eprintln("\ti", i, c.kind, Implicit_Curve_Cubic_Type(c.hull_padding.x))
		// }
	}

	// fill texture
	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
	gl.Disable(gl.CULL_FACE)
	gl.Disable(gl.DEPTH_TEST)
	gl.BindVertexArray(fill.vao)
	gl.UseProgram(fill.program)

	projection := glm.mat4Ortho3d(0, f32(width), f32(height), 0, 0, 1)
	gl.UniformMatrix4fv(fill.loc_projection, 1, gl.FALSE, &projection[0][0])

	gl.BindTexture(gl.TEXTURE_2D, raster.texture_id)
	gl.BindBuffer(gl.ARRAY_BUFFER, fill.vbo)

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
	xform_identity(&paint.xform)
	paint.feather = 1
	paint.inner_color = color
	paint.outer_color = color
}

renderer_state_reset :: proc(using renderer: ^Renderer) {
	state := renderer_state_get(renderer)
	state^ = {}
	paint_set_color(renderer, &state.paint, { 1, 0, 0, 1 })
	xform_identity(&state.xform)
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
	xform_identity(&state.xform)
}

renderer_state_translate :: proc(using renderer: ^Renderer, x, y: f32) {
	state := renderer_state_get(renderer)
	temp := xform_translate(x, y)
	xform_premultiply(&state.xform, temp)
}

renderer_state_rotate :: proc(using renderer: ^Renderer, angle: f32) {
	state := renderer_state_get(renderer)
	temp := xform_rotate(angle)
	xform_premultiply(&state.xform, temp)
}

renderer_state_scale :: proc(using renderer: ^Renderer, x, y: f32) {
	state := renderer_state_get(renderer)
	temp := xform_scale(x, y)
	xform_premultiply(&state.xform, temp)
}

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
		xform_point_v2(state.xform, curve_last), 
		xform_point_v2(state.xform, { x, y }),
	)
	curve_index += 1
	curve_last = { x, y }
}

renderer_line_to_rel :: proc(using renderer: ^Renderer, x, y: f32) {
	state := renderer_state_get(renderer)
	curves[curve_index] = c1_make(
		xform_point_v2(state.xform, curve_last), 
		xform_point_v2(state.xform, curve_last + { x, y }),
	)
	curve_index += 1
	curve_last = curve_last + { x, y }
}

renderer_vertical_line_to :: proc(using renderer: ^Renderer, y: f32) {
	state := renderer_state_get(renderer)
	curves[curve_index] = c1_make(
		xform_point_v2(state.xform, curve_last), 
		xform_point_v2(state.xform, { curve_last.x, y }),
	)
	curve_index += 1
	curve_last = { curve_last.x, y }
}

renderer_horizontal_line_to :: proc(using renderer: ^Renderer, x: f32) {
	state := renderer_state_get(renderer)
	curves[curve_index] = c1_make(
		xform_point_v2(state.xform, curve_last), 
		xform_point_v2(state.xform, { x, curve_last.y }),
	)
	curve_index += 1
	curve_last = { x, curve_last.y }
}

renderer_quadratic_to :: proc(using renderer: ^Renderer, x, y, cx, cy: f32) {
	state := renderer_state_get(renderer)
	curves[curve_index] = c2_make(
		xform_point_v2(state.xform, curve_last), 
		xform_point_v2(state.xform, { cx, cy }), 
		xform_point_v2(state.xform, { x, y }),
	)
	curve_index += 1
	curve_last = { x, y }
}

renderer_quadratic_to_rel :: proc(using renderer: ^Renderer, x, y, cx, cy: f32) {
	state := renderer_state_get(renderer)
	curves[curve_index] = c2_make(
		xform_point_v2(state.xform, curve_last), 
		xform_point_v2(state.xform, curve_last + { cx, cy }),
		xform_point_v2(state.xform, curve_last + { x, y }),
	)
	curve_index += 1
	curve_last = curve_last + { x, y }
}

renderer_cubic_to :: proc(using renderer: ^Renderer, x, y, c1x, c1y, c2x, c2y: f32) {
	state := renderer_state_get(renderer)
	curves[curve_index] = c3_make(
		xform_point_v2(state.xform, curve_last),
		xform_point_v2(state.xform, { c1x, c1y }),
		xform_point_v2(state.xform, { c2x, c2y }),
		xform_point_v2(state.xform, { x, y }),
	)
	curve_index += 1
	curve_last = { x, y }
}

renderer_cubic_to_rel :: proc(using renderer: ^Renderer, x, y, c1x, c1y, c2x, c2y: f32) {
	state := renderer_state_get(renderer)
	curves[curve_index] = c3_make(
		xform_point_v2(state.xform, curve_last),
		xform_point_v2(state.xform, curve_last + { c1x, c1y }),
		xform_point_v2(state.xform, curve_last + { c2x, c2y }),
		xform_point_v2(state.xform, curve_last + { x, y }),
	)
	curve_index += 1
	curve_last = curve_last + { x, y }
}

renderer_close :: proc(using renderer: ^Renderer) {
	if curve_index > 0 {
		state := renderer_state_get(renderer)
		start := curves[0].B[0]

		curves[curve_index] = c1_make(
			xform_point_v2(state.xform, curve_last), 
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

renderer_ellipse :: proc(renderer: ^Renderer, cx, cy, rx, ry: f32) {
	renderer_move_to(renderer, cx-rx, cy)
	renderer_cubic_to(renderer, cx, cy+ry, cx-rx, cy+ry*KAPPA90, cx-rx*KAPPA90, cy+ry)
	renderer_cubic_to(renderer, cx+rx, cy, cx+rx*KAPPA90, cy+ry, cx+rx, cy+ry*KAPPA90)
	renderer_cubic_to(renderer, cx, cy-ry, cx+rx, cy-ry*KAPPA90, cx+rx*KAPPA90, cy-ry)
	renderer_cubic_to(renderer, cx-rx, cy, cx-rx*KAPPA90, cy-ry, cx-rx, cy-ry*KAPPA90)
	renderer_close(renderer)
}

renderer_circle :: proc(renderer: ^Renderer, cx, cy, r: f32) {
	renderer_ellipse(renderer, cx, cy, r, r)
}

// TODO still looks weird
// arc to for svg
renderer_arc_to :: proc(
	renderer: ^Renderer,
	rx, ry: f32,
	rotation: f32,
	large_arc: f32,
	sweep_direction: f32,
	x2, y2: f32,
) {
	square :: #force_inline proc(a: f32) -> f32 {
		return a * a
	}

	vmag :: #force_inline proc(x, y: f32) -> f32 {
		return math.sqrt(x*x + y*y)
	}

	vecrat :: proc(ux, uy, vx, vy: f32) -> f32 {
		return (ux*vx + uy*vy) / (vmag(ux,uy) * vmag(vx,vy))
	}

	vecang :: proc(ux, uy, vx, vy: f32) -> f32 {
		r := vecrat(ux,uy, vx,vy)
		
		if r < -1 {
			r = -1
		}
		
		if r > 1 {
			r = 1
		}

		return ((ux*vy < uy*vx) ? -1 : 1) * math.acos(r)
	}

	// Ported from canvg (https://code.google.com/p/canvg/)
	rx := abs(rx)				// y radius
	ry := abs(ry)				// x radius
	rotx := rotation / 180 * math.PI		// x rotation angle
	fa := abs(large_arc) > 1e-6 ? 1 : 0	// Large arc
	fs := abs(sweep_direction) > 1e-6 ? 1 : 0	// Sweep direction
	x1 := renderer.curve_last.x // start point
	y1 := renderer.curve_last.y

	dx := x1 - x2
	dy := y1 - y2
	d := math.sqrt(dx*dx + dy*dy)
	if d < 1e-6 || rx < 1e-6 || ry < 1e-6 {
		// The arc degenerates to a line
		renderer_line_to(renderer, x2, y2)
		return
	}

	sinrx := math.sin(rotx)
	cosrx := math.cos(rotx)

	// Convert to center point parameterization.
	// http://www.w3.org/TR/SVG11/implnote.html#ArcImplementationNotes
	// 1) Compute x1', y1'
	x1p := cosrx * dx / 2 + sinrx * dy / 2
	y1p := -sinrx * dx / 2 + cosrx * dy / 2
	d = square(x1p)/square(rx) + square(y1p)/square(ry)
	if d > 1 {
		d = math.sqrt(d)
		rx *= d
		ry *= d
	}
	// 2) Compute cx', cy'
	s := f32(0)
	sa := square(rx)*square(ry) - square(rx)*square(y1p) - square(ry)*square(x1p)
	sb := square(rx)*square(y1p) + square(ry)*square(x1p)
	if sa < 0 {
		sa = 0
	}
	if sb > 0 {
		s = math.sqrt(sa / sb)
	}
	if fa == fs {
		s = -s
	}
	cxp := s * rx * y1p / ry
	cyp := s * -ry * x1p / rx

	// 3) Compute cx,cy from cx',cy'
	cx := (x1 + x2)/2 + cosrx*cxp - sinrx*cyp
	cy := (y1 + y2)/2 + sinrx*cxp + cosrx*cyp

	// 4) Calculate theta1, and delta theta.
	ux := (x1p - cxp) / rx
	uy := (y1p - cyp) / ry
	vx := (-x1p - cxp) / rx
	vy := (-y1p - cyp) / ry
	a1 := vecang(1,0, ux,uy)	// Initial angle
	da := vecang(ux,uy, vx,vy)		// Delta angle

	if fs == 0 && da > 0 {
		da -= 2 * math.PI
	} else if fs == 1 && da < 0 {
		da += 2 * math.PI
	}

	// Approximate the arc using cubic spline segments.
	t := Xform {
		cosrx, sinrx,
		-sinrx, cosrx,
		cx, cy,
	}

	// Split arc into max 90 degree segments.
	// The loop assumes an iteration per end point (including start and end), this +1.
	ndivs := (int)(abs(da) / (math.PI*0.5) + 1)
	hda := (da / f32(ndivs)) / 2
	// Fix for ticket #179: division by 0: avoid cotangens around 0 (infinite)
	if hda < 1e-3 && hda > -1e-3 {
		hda *= 0.5
	} else {
		hda = (1 - math.cos(hda)) / math.sin(hda)
	}

	kappa := abs(4 / 3 * hda)
	if da < 0 {
		kappa = -kappa
	}

	state := renderer_state_get(renderer)
	p, ptan: [2]f32
	for i in 0..<ndivs {
		a := a1 + da * (f32(i)/f32(ndivs))
		dx = math.cos(a)
		dy = math.sin(a)
		
		curr := xform_point_v2(t, { dx * rx, dy * ry }) // position
		tan := xform_v2(t, { -dy*rx * kappa, dx*ry * kappa }) // tangent

		if i > 0 {
			renderer_cubic_to(renderer, curr.x, curr.y, p.x+ptan.x, p.y+ptan.y, curr.x-tan.x, curr.y-tan.y)
		}

		p = curr
		ptan = tan
	}
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
