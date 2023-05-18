package src

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

TILE_SIZE :: 32 // has to match compute header
MAX_STATES :: 32
MAX_CURVES :: 256
MAX_IMPLICIT_CURVES :: 256
MAX_TILE_QUEUES :: 1028
MAX_TILE_OPERATIONS :: 1028
MAX_PATHS :: 1028
MAX_PATH_QUEUES :: MAX_PATHS
MAX_SCREEN_TILES :: 1028 * 2

shader_vert := #load("vertex.glsl")
shader_frag := #load("fragment.glsl")
shader_compute_header := #load("mpvg_header.comp")
shader_compute_path := #load("mpvg_path.comp")
shader_compute_implicitize := #load("mpvg_implicitize.comp")
shader_compute_tile_backprop := #load("mpvg_tile_backprop.comp")
shader_compute_merge := #load("mpvg_merge.comp")

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

// glsl std140 layout
// indices that will get advanced in compute shaders!
Indices :: struct #packed {
	implicit_curves: i32,
	tile_operations: i32,
	tile_queues: i32,
	pad1: i32,

	// data used throughout
	tiles_x: i32,
	tiles_y: i32,
	pad2: i32,
	pad3: i32,
}

Renderer :: struct {
	// raw curves that were inserted by the user
	curves: []Curve,
	curve_index: int,
	curve_last: [2]f32, // temp last point in path creation

	// indices that will get advanced on the gpu
	indices: Indices,

	// paths per curve shape
	paths: []Path,
	path_index: int,

	tile_operations: []Tile_Operation,
	tile_operation_count_last_frame: i32,

	// tiling temp
	tile_index: int,
	tile_count: int,
	tiles_size: int,
	tiles_x: int,
	tiles_y: int,

	// font data
	font_pool: Pool(8, Font),

	// platform dependent implementation
	gpu: Renderer_GL,
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
	},

	raster: struct {
		program: u32,
		texture_id: u32,
	},

	backprop: struct {
		program: u32,
	},

	path: struct {
		program: u32,
	},

	merge: struct {
		program: u32,
	},

	indices_ssbo: u32,
	curves_ssbo: u32,
	implicit_curves_ssbo: u32,
	tile_queues_ssbo: u32,
	tile_operations_ssbo: u32,
	paths_ssbo: u32,
	path_queue_ssbo: u32,
	screen_tiles_ssbo: u32,
}

Tile_Queue :: struct #packed {
	op_first: i32,
	op_last: i32,
	winding_offset: i32,
	pad1: i32,
}

Tile_Operation :: struct #packed {
	kind: i32,
	op_next: i32,	// next command index
	path_index: i32, // which path this belongs to
	curve_index: i32, // which implicit curve this belongs to

	cross_right: b32,
	pad1: i32,
	pad2: i32,
	pad3: i32,
}

Path :: struct #packed {
	color: [4]f32,
	box: [4]f32, // bounding box for all inserted vertices,
	clip: [4]f32,

	xform: Xform, // transformation used throughout vertice creation
	pad1: i32,
	pad2: i32,
}

Path_Queue :: struct #packed {
	area: [4]i32,

	tile_queues: i32,
	pad1: i32,
	pad2: i32,
	pad3: i32,
}

Implicit_Curve_Kind :: enum i32 {
	LINE,
	QUADRATIC,
	CUBIC,
}

Implicit_Curve_Cubic_Type :: enum i32 {
	ERROR = 0,
	SERPENTINE,
	CUSP,
	CUSP_INFINITY,
	LOOP,
	DEGENERATE_QUADRATIC,
	DEGENERATE_LINE,
}

Implicit_Curve_Orientation :: enum i32 {
	BL,
	BR,
	TL,
	TR,
}

Implicit_Curve :: struct {
	box: [4]f32, // bounding box

	hull_vertex: [2]f32,
	hull_padding: [2]f32,

	kind: Implicit_Curve_Kind,
	orientation: Implicit_Curve_Orientation,
	sign: i32,
	winding_increment: i32,

	implicit_matrix: [12]f32,
}

// curve Linear, Quadratic, Cubic in flat structure
Curve :: struct #packed {
	B: [4][2]f32,
	count: i32, // 0-2 + 1
	path_index: i32,
	pad1: i32,
	pad2: i32,
}

renderer_init :: proc(renderer: ^Renderer) {
	renderer.curves = make([]Curve, MAX_CURVES)
	renderer.paths = make([]Path, MAX_PATHS)
	renderer.tile_operations = make([]Tile_Operation, MAX_TILE_OPERATIONS)
	pool_clear(&renderer.font_pool)

	renderer_gpu_gl_init(&renderer.gpu)

	renderer.tiles_size = TILE_SIZE
}

renderer_make :: proc() -> (res: Renderer) {
	renderer_init(&res)
	return
}

renderer_destroy :: proc(renderer: ^Renderer) {
	delete(renderer.curves)
	delete(renderer.paths)
	delete(renderer.tile_operations)

	renderer_gpu_gl_destroy(&renderer.gpu)
	// TODO destroy fonts
}

renderer_start :: proc(renderer: ^Renderer, width, height: int) {
	renderer.tiles_x = width / TILE_SIZE
	renderer.tiles_y = height / TILE_SIZE
	renderer.tiles_size = TILE_SIZE
	renderer.tile_count = renderer.tiles_x * renderer.tiles_y
	renderer.tile_index = renderer.tiles_x * renderer.tiles_y

	renderer.curve_index = 0
	renderer.indices.implicit_curves = 0
	renderer.indices.tiles_x = i32(renderer.tiles_x)
	renderer.indices.tiles_y = i32(renderer.tiles_y)
	renderer.indices.tile_queues = 0
	renderer.indices.tile_operations = 0
	renderer.path_index = 0
	path_init(&renderer.paths[0])

	renderer_gpu_gl_start(renderer)
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

// build unified compute shader with a shared header
renderer_gpu_shader_compute :: proc(
	builder: ^strings.Builder,
	header: []byte,
	data: []byte,
	x, y: int,
	loc := #caller_location,
) -> u32 {
	strings.builder_reset(builder)

	// write version + sizes
	fmt.sbprintf(builder, "#version 450 core\nlayout(local_size_x = %d, local_size_y = %d) in;\n\n", x, y)

	// write header
	strings.write_bytes(builder, header)

	// write rest of the data
	strings.write_bytes(builder, data)

	// write result
	program, ok := gl.load_compute_source(strings.to_string(builder^))
	if !ok {
		panic("failed loading compute shader", loc)
	}

	return program
}

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

	builder := strings.builder_make(mem.Kilobyte * 4, context.temp_allocator)

	{
		raster.program = renderer_gpu_shader_compute(&builder, shader_compute_header, shader_compute_raster, TILE_SIZE, TILE_SIZE)

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

	implicitize.program = renderer_gpu_shader_compute(&builder, shader_compute_header, shader_compute_implicitize, 1, 1)
	// backprop.program = renderer_gpu_shader_compute(&builder, shader_compute_header, shader_compute_tile_backprop, 16, 1)
	backprop.program = renderer_gpu_shader_compute(&builder, shader_compute_header, shader_compute_tile_backprop, 1, 1)
	path.program = renderer_gpu_shader_compute(&builder, shader_compute_header, shader_compute_path, 1, 1)
	merge.program = renderer_gpu_shader_compute(&builder, shader_compute_header, shader_compute_merge, 1, 1)

	// TODO revisit STREAM/STATIC?
	create :: proc(base: u32, size: int) -> (index: u32) {
		gl.CreateBuffers(1, &index)
		gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, index)
		gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, base, index)
		gl.NamedBufferData(index, size, nil, gl.STREAM_DRAW)
		return index
	}

	indices_ssbo = create(0, 1 * size_of(Indices))
	curves_ssbo = create(1, MAX_CURVES * size_of(Curve))
	implicit_curves_ssbo = create(2, MAX_IMPLICIT_CURVES * size_of(Implicit_Curve))
	tile_queues_ssbo = create(3, MAX_TILE_QUEUES * size_of(Tile_Queue))
	tile_operations_ssbo = create(4, MAX_TILE_OPERATIONS * size_of(Tile_Operation))
	paths_ssbo = create(5, MAX_PATHS * size_of(Path))
	path_queue_ssbo = create(6, MAX_PATH_QUEUES * size_of(Path_Queue))
	screen_tiles_ssbo = create(7, MAX_SCREEN_TILES * size_of(i32))
}

renderer_gpu_gl_destroy :: proc(using gpu: ^Renderer_GL) {

}

renderer_gpu_gl_start :: proc(renderer: ^Renderer) {

}

renderer_gpu_gl_end :: proc(renderer: ^Renderer, width, height: int) {
	gpu := &renderer.gpu
	using gpu

	// path setup
	{
		gl.UseProgram(path.program)

		gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, indices_ssbo)
		gl.NamedBufferSubData(indices_ssbo, 0, size_of(Indices), &renderer.indices)

		gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, paths_ssbo)
		gl.NamedBufferSubData(paths_ssbo, 0, (renderer.path_index + 1) * size_of(Path), raw_data(renderer.paths))

		gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, curves_ssbo)
		gl.NamedBufferSubData(curves_ssbo, 0, renderer.curve_index * size_of(Curve), raw_data(renderer.curves))

		gl.DispatchCompute(u32(renderer.path_index + 1), 1, 1)
		gl.MemoryBarrier(gl.SHADER_STORAGE_BARRIER_BIT)
	}

	// implicitize stage
	{
		gl.UseProgram(implicitize.program)
		gl.DispatchCompute(u32(renderer.curve_index), 1, 1)

		gl.GetNamedBufferSubData(indices_ssbo, 0, 1 * size_of(Indices), &renderer.indices)
		// fmt.eprintln(renderer.indices)
		temp := make([]Tile_Operation, renderer.indices.tile_operations, context.temp_allocator)
		gl.GetNamedBufferSubData(tile_operations_ssbo, 0, size_of(Tile_Operation) * len(temp), raw_data(temp))
		
		was_different := mem.compare(
			mem.slice_to_bytes(renderer.tile_operations[:renderer.tile_operation_count_last_frame]), 
			mem.slice_to_bytes(temp),
		)

		fmt.eprintln("~~~", was_different != 0)
		for i in 0..<renderer.indices.tile_operations {
			op := temp[i]
			fmt.eprintf("%+d\t\t", op.op_next)
		}
		fmt.eprintln()

		copy(renderer.tile_operations, temp)
		renderer.tile_operation_count_last_frame = renderer.indices.tile_operations
	}

	// fmt.eprintln("yo0")

	// // tile backprop stage go by 0->tiles_y
	// {
	// 	gl.UseProgram(backprop.program)
	// 	// gl.DispatchCompute(u32(renderer.tiles_y), 1, 1)
	// 	gl.DispatchCompute(u32(renderer.path_index + 1), 1, 1)
	// 	gl.MemoryBarrier(gl.SHADER_STORAGE_BARRIER_BIT)
	// }

	// fmt.eprintln("yo1")

	// // tile merging to screen tiles
	// {
	// 	gl.UseProgram(merge.program)
	// 	gl.DispatchCompute(u32(renderer.tiles_x), u32(renderer.tiles_y), 1)
	// 	gl.MemoryBarrier(gl.SHADER_STORAGE_BARRIER_BIT)
	// }

	// // fmt.eprintln("yo2")

	// // raster stage
	// {
	// 	gl.UseProgram(raster.program)

	// 	when USE_TILING {
	// 		gl.DispatchCompute(u32(renderer.tiles_x), u32(renderer.tiles_y), 1)
	// 	} else {
	// 		gl.DispatchCompute(u32(width), u32(height), 1)
	// 	}

	// 	gl.MemoryBarrier(gl.SHADER_IMAGE_ACCESS_BARRIER_BIT)
	// }

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
// PATHING
///////////////////////////////////////////////////////////

renderer_move_to :: proc(renderer: ^Renderer, x, y: f32) {
	path := renderer_path_get(renderer)

	// if renderer.curve_index > 0 {
	// 	renderer_close(renderer)
	// }

	renderer.curve_last = { x, y }
}

renderer_move_to_rel :: proc(renderer: ^Renderer, x, y: f32) {
	path := renderer_path_get(renderer)
	renderer.curve_last = renderer.curve_last + { x, y }
}

renderer_line_to :: proc(using renderer: ^Renderer, x, y: f32) {
	path := renderer_path_get(renderer)

	curve_linear_init(
		&curves[curve_index],
		path_xform_v2(path, curve_last),
		path_xform_v2(path, { x, y }),
		renderer.path_index,
	)
	curve_index += 1
	curve_last = { x, y }
}

renderer_line_to_rel :: proc(using renderer: ^Renderer, x, y: f32) {
	path := renderer_path_get(renderer)
	curve_linear_init(
		&curves[curve_index],
		path_xform_v2(path, curve_last),
		path_xform_v2(path, curve_last + { x, y }),
		renderer.path_index,
	)
	curve_index += 1
	curve_last = curve_last + { x, y }
}

renderer_vertical_line_to :: proc(using renderer: ^Renderer, y: f32) {
	path := renderer_path_get(renderer)
	curve_linear_init(
		&curves[curve_index],
		path_xform_v2(path, curve_last),
		path_xform_v2(path, { curve_last.x, y }),
		renderer.path_index,
	)
	curve_index += 1
	curve_last = { curve_last.x, y }
}

renderer_horizontal_line_to :: proc(using renderer: ^Renderer, x: f32) {
	path := renderer_path_get(renderer)
	curve_linear_init(
		&curves[curve_index],
		path_xform_v2(path, curve_last),
		path_xform_v2(path, { x, curve_last.y }),
		renderer.path_index,
	)
	curve_index += 1
	curve_last = { x, curve_last.y }
}

renderer_quadratic_to :: proc(using renderer: ^Renderer, cx, cy, x, y: f32) {
	path := renderer_path_get(renderer)
	curve_quadratic_init(
		&curves[curve_index],
		path_xform_v2(path, curve_last),
		path_xform_v2(path, { cx, cy }),
		path_xform_v2(path, { x, y }),
		renderer.path_index,
	)
	curve_index += 1
	curve_last = { x, y }
}

renderer_quadratic_to_rel :: proc(using renderer: ^Renderer, cx, cy, x, y: f32) {
	path := renderer_path_get(renderer)
	curve_quadratic_init(
		&curves[curve_index],
		path_xform_v2(path, curve_last),
		path_xform_v2(path, curve_last + { cx, cy }),
		path_xform_v2(path, curve_last + { x, y }),
		renderer.path_index,
	)
	curve_index += 1
	curve_last = curve_last + { x, y }
}

renderer_cubic_to :: proc(using renderer: ^Renderer, c1x, c1y, c2x, c2y, x, y: f32) {
	path := renderer_path_get(renderer)
	curve_cubic_init(
		&curves[curve_index],
		path_xform_v2(path, curve_last),
		path_xform_v2(path, { c1x, c1y }),
		path_xform_v2(path, { c2x, c2y }),
		path_xform_v2(path, { x, y }),
		renderer.path_index,
	)
	curve_index += 1
	curve_last = { x, y }
}

renderer_cubic_to_rel :: proc(using renderer: ^Renderer, c1x, c1y, c2x, c2y, x, y: f32) {
	path := renderer_path_get(renderer)
	curve_cubic_init(
		&curves[curve_index],
		path_xform_v2(path, curve_last),
		path_xform_v2(path, curve_last + { c1x, c1y }),
		path_xform_v2(path, curve_last + { c2x, c2y }),
		path_xform_v2(path, curve_last + { x, y }),
		renderer.path_index,
	)
	curve_index += 1
	curve_last = curve_last + { x, y }
}

renderer_close :: proc(using renderer: ^Renderer) {
	if curve_index > 0 {
		path := renderer_path_get(renderer)
		start := curves[0].B[0]

		curve_linear_init(
			&curves[curve_index],
			path_xform_v2(path, curve_last),
			{ start.x, start.y },
			renderer.path_index,
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
	ndivs := int(abs(da) / (math.PI*0.5) + 1)
	hda := (da / f32(ndivs)) / 2
	// Fix for ticket #179: division by 0: avoid cotangens around 0 (infinite)
	if hda < 1e-3 && hda > -1e-3 {
		hda *= 0.5
	} else {
		hda = (1 - math.cos(hda)) / math.sin(hda)
	}

	kappa := abs(4.0 / 3.0 * hda)
	if da < 0.0 {
		kappa = -kappa
	}

	path := renderer_path_get(renderer)
	p, ptan: [2]f32
	for i in 0..=ndivs {
		a := a1 + da * (f32(i)/f32(ndivs))
		dx = math.cos(a)
		dy = math.sin(a)

		curr := xform_point_v2(t, { dx * rx, dy * ry }) // position
		tan := xform_v2(t, { -dy*rx * kappa, dx*ry * kappa }) // tangent

		if i > 0 {
			renderer_cubic_to(renderer, p.x+ptan.x, p.y+ptan.y, curr.x-tan.x, curr.y-tan.y, curr.x, curr.y)
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

///////////////////////////////////////////////////////////
// PATH
///////////////////////////////////////////////////////////

path_init :: proc(using path: ^Path) {
	path.box = {
		max(f32),
		max(f32),
		-max(f32),
		-max(f32),
	}
	path.clip = {
		-100,
		-100,
		1100,
		1100,
	}

	xform_identity(&path.xform)
	path.color = { 0, 1, 0, 1 }
}

// add to bounding box
path_box_push :: proc(path: ^Path, output: [2]f32) {
	path.box.x = min(path.box.x, output.x)
	path.box.z = max(path.box.z, output.x)
	path.box.y = min(path.box.y, output.y)
	path.box.w = max(path.box.w, output.y)
}

path_xform_v2 :: proc(path: ^Path, input: [2]f32) -> (res: [2]f32) {
	res = {
		input.x * path.xform[0] + input.y * path.xform[2] + path.xform[4],
		input.x * path.xform[1] + input.y * path.xform[3] + path.xform[5],
	}
	path_box_push(path, res)
	return
}

curve_linear_init :: proc(curve: ^Curve, a, b: [2]f32, path_index: int) {
	curve.B[0] = a
	curve.B[1] = b
	curve.count = 0
	curve.path_index = i32(path_index)
}

curve_quadratic_init :: proc(curve: ^Curve, a, b, c: [2]f32, path_index: int) {
	curve.B[0] = a
	curve.B[1] = b
	curve.B[2] = c
	curve.count = 1
	curve.path_index = i32(path_index)
}

curve_cubic_init :: proc(curve: ^Curve, a, b, c, d: [2]f32, path_index: int) {
	curve.B[0] = a
	curve.B[1] = b
	curve.B[2] = c
	curve.B[3] = d
	curve.count = 2
	curve.path_index = i32(path_index)
}

renderer_path_get :: #force_inline proc(renderer: ^Renderer) -> ^Path #no_bounds_check {
	return &renderer.paths[renderer.path_index]
}

renderer_path_reset_transform :: proc(using renderer: ^Renderer) {
	path := renderer_path_get(renderer)
	xform_identity(&path.xform)
}

renderer_path_translate :: proc(using renderer: ^Renderer, x, y: f32) {
	path := renderer_path_get(renderer)
	temp := xform_translate(x, y)
	xform_premultiply(&path.xform, temp)
}

renderer_path_rotate :: proc(using renderer: ^Renderer, angle: f32) {
	path := renderer_path_get(renderer)
	temp := xform_rotate(angle)
	xform_premultiply(&path.xform, temp)
}

renderer_path_scale :: proc(using renderer: ^Renderer, x, y: f32) {
	path := renderer_path_get(renderer)
	temp := xform_scale(x, y)
	xform_premultiply(&path.xform, temp)
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
