package vg

import "core:fmt"
import "core:mem"
import "core:strings"

import glm "core:math/linalg/glsl"
import sa "core:container/small_array"
import gl "vendor:OpenGL"

TILE_SIZE :: 32 // has to match compute header
MAX_CURVES :: 4048
MAX_PATHS :: 1028 * 8
SIZE_IMPLICIT_CURVES :: mem.Megabyte
SIZE_TILE_QUEUES :: mem.Megabyte
SIZE_TILE_OPERATIONS :: mem.Megabyte * 4
SIZE_SCREEN_TILES :: mem.Megabyte

////////////////////////////////////////////////////////////////////////////////
// Compute Renderer implementation
////////////////////////////////////////////////////////////////////////////////

shader_vert := #load("shaders/vertex.glsl")
shader_frag := #load("shaders/fragment.glsl")
compute_header := #load("shaders/compute/header.comp")
compute_path_setup := #load("shaders/compute/path_setup.comp")
compute_curve_implicitize := #load("shaders/compute/curve_implicitize.comp")
compute_tile_backprop := #load("shaders/compute/tile_backprop.comp")
compute_tile_merge := #load("shaders/compute/tile_merge.comp")
compute_tile_queue := #load("shaders/compute/tile_queue.comp")
compute_raster := #load("shaders/compute/raster.comp")

Vertex :: struct {
	pos: [2]f32,
	uv: [2]f32,
}

Renderer :: struct {
	// raw curves that were inserted by the user
	curves: Fixed_Array(Curve),

	// indices that will get advanced on the gpu
	indices: Indices,

	// paths per curve shape
	paths: Fixed_Array(Path),

	// tiling temp
	tiles_x: int,
	tiles_y: int,

	// width/height this frame
	window_width: int,
	window_height: int,

	fill: struct {
		vao: u32,
		vbo: u32,
		program: u32,
		loc_projection: i32,
	},

	raster_program: u32,
	raster_texture_id: u32,
	raster_texture_width: int,
	raster_texture_height: int,

	curve_implicitize_program: u32,
	tile_backprop_program: u32,
	tile_merge_program: u32,
	tile_queue_program: u32,
	path_setup_program: u32,

	indices_ssbo: u32,
	curves_ssbo: u32,
	implicit_curves_ssbo: u32,
	tile_queues_ssbo: u32,
	tile_operations_ssbo: u32,
	paths_ssbo: u32,
	path_queues_ssbo: u32,
	screen_tiles_ssbo: u32,
}

// indices that will get advanced in compute shaders!
Indices :: struct #packed {
	implicit_curves: i32,
	paths: i32,
	tile_operations: i32,
	tile_queues: i32,

	// data used throughout
	tiles_x: i32,
	tiles_y: i32,
}

Path :: struct #packed {
	color: [4]f32,
	box: [4]f32,
	clip: [4]f32,

	stroke: b32, // fill default
	pad1: i32,

	curve_start: i32, // start index
	curve_end: i32, // end index
}

// curve Linear, Quadratic, Cubic in flat structure
Curve :: struct #packed {
	B: [4][2]f32,
	count: i32, // 0-2 + 1
	path_index: i32,
}

Screen_Tile :: i32

renderer_init :: proc(using renderer: ^Renderer) {
	fa_init(&renderer.curves, MAX_CURVES)
	fa_init(&renderer.paths, MAX_PATHS)
	
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
		raster_program = renderer_gpu_shader_compute(&builder, compute_header, compute_raster, TILE_SIZE, TILE_SIZE)

		gl.GenTextures(1, &raster_texture_id)
		gl.BindTexture(gl.TEXTURE_2D, raster_texture_id)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
		gl.BindImageTexture(0, raster_texture_id, 0, gl.FALSE, 0, gl.WRITE_ONLY, gl.RGBA8)

		{
			// TODO dynamic width/height or finite big one
			raster_texture_width = 2560
			raster_texture_height = 1080
			gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, i32(raster_texture_width), i32(raster_texture_height), 0, gl.RGBA, gl.UNSIGNED_BYTE, nil)
		}

		gl.BindTexture(gl.TEXTURE_2D, 0)
	}

	curve_implicitize_program = renderer_gpu_shader_compute(&builder, compute_header, compute_curve_implicitize, 1, 1)
	// curve_transform_program = renderer_gpu_shader_compute(&builder, compute_header, compute_curve_transform, 1, 1)
	tile_backprop_program = renderer_gpu_shader_compute(&builder, compute_header, compute_tile_backprop, 16, 1)
	path_setup_program = renderer_gpu_shader_compute(&builder, compute_header, compute_path_setup, 1, 1)
	tile_merge_program = renderer_gpu_shader_compute(&builder, compute_header, compute_tile_merge, 1, 1)
	tile_queue_program = renderer_gpu_shader_compute(&builder, compute_header, compute_tile_queue, 1, 1)

	// TODO revisit STREAM/STATIC?
	create :: proc(base: u32, size: int) -> (index: u32) {
		gl.CreateBuffers(1, &index)
		gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, index)
		gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, base, index)
		gl.NamedBufferData(index, size, nil, gl.STREAM_DRAW)
		fmt.eprintln("SSBO", base, size, size / mem.Kilobyte, size / mem.Megabyte)
		return index
	}

	indices_ssbo = create(0, 1 * size_of(Indices))
	curves_ssbo = create(1, MAX_CURVES * size_of(Curve))
	implicit_curves_ssbo = create(2, SIZE_IMPLICIT_CURVES)
	tile_queues_ssbo = create(3, SIZE_TILE_QUEUES)
	tile_operations_ssbo = create(4, SIZE_TILE_OPERATIONS)
	paths_ssbo = create(5, MAX_PATHS * size_of(Path))
	path_queues_ssbo = create(6, MAX_PATHS * size_of(Path))
	screen_tiles_ssbo = create(7, SIZE_SCREEN_TILES)
}

renderer_make :: proc() -> (res: Renderer) {
	renderer_init(&res)
	return
}

renderer_destroy :: proc(renderer: ^Renderer) {
	fa_destroy(renderer.curves)
	fa_destroy(renderer.paths)
}

renderer_begin :: proc(renderer: ^Renderer, width, height: int) {
	renderer.tiles_x = width / TILE_SIZE
	renderer.tiles_y = height / TILE_SIZE

	fa_clear(&renderer.curves)
	fa_clear(&renderer.paths)

	renderer.indices = {}
	renderer.indices.tiles_x = i32(renderer.tiles_x)
	renderer.indices.tiles_y = i32(renderer.tiles_y)

	renderer.window_width = width
	renderer.window_height = height
}

// renderer_text_push :: proc(
// 	using renderer: ^Renderer,
// 	text: string,
// 	x, y: f32,
// 	size: f32,
// ) {
// 	font := pool_at(&font_pool, 1)
	
// 	x_start := x
// 	x := x
// 	y := y
// 	for codepoint in text {
// 		x += renderer_font_glyph(renderer, font, codepoint, x, y, size)
// 		// if x > 500 {
// 		// 	x = x_start
// 		// 	y += size
// 		// }
// 	}
// }

// renderer_font_push :: proc(renderer: ^Renderer, path: string) -> u32 {
// 	index := pool_alloc_index(&renderer.font_pool)
// 	font := pool_at(&renderer.font_pool, index)
// 	font_init(font, path)
// 	return index
// }

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
	strings.write_byte(builder, '\n')

	// write rest of the data
	strings.write_bytes(builder, data)

	// write result
	program, ok := gl.load_compute_source(strings.to_string(builder^))
	if !ok {
		panic("failed loading compute shader", loc)
	}

	return program
}

renderer_end :: proc(using renderer: ^Renderer) {
	// // check path count or unfinished path we might have pushed
	// path_count := renderer.path_index + 1
	// path := renderer.paths[renderer.path_index]
	// if path.curve_index_start == path.curve_index_current {
	// 	path_count -= 1
	// }
	
	// write in the final path count
	// fmt.eprintln("PATH COUNT", path_count, size_of(Path))
	// renderer.indices.paths = i32(path_count)
	path_count := renderer.paths.index
	renderer.indices.paths = i32(path_count)

	// bind
	{
		gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, indices_ssbo)
		gl.NamedBufferSubData(indices_ssbo, 0, size_of(Indices), &renderer.indices)

		gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, paths_ssbo)
		gl.NamedBufferSubData(paths_ssbo, 0, path_count * size_of(Path), fa_raw(renderer.paths))

		gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, curves_ssbo)
		gl.NamedBufferSubData(curves_ssbo, 0, renderer.curves.index * size_of(Curve), fa_raw(renderer.curves))
	}

	// path setup
	{
		gl.UseProgram(path_setup_program)
		gl.DispatchCompute(u32(path_count), 1, 1)
	}

	// implicitize stage
	{
		gl.UseProgram(curve_implicitize_program)
		gl.DispatchCompute(u32(renderer.curves.index), 1, 1)
	}

	// find head/tail of tile queues, set op nexts per tile queue
	{
		gl.GetNamedBufferSubData(indices_ssbo, 0, size_of(Indices), &renderer.indices)
		gl.UseProgram(tile_queue_program)
		gl.DispatchCompute(u32(renderer.indices.tile_queues), 1, 1)
	}

	// tile backprop stage go by 0->tiles_y
	{
		gl.UseProgram(tile_backprop_program)
		gl.DispatchCompute(u32(path_count), 1, 1)
	}

	// tile merging to screen tiles
	{
		gl.UseProgram(tile_merge_program)
		gl.DispatchCompute(u32(renderer.tiles_x), u32(renderer.tiles_y), 1)
	}

	// raster stage
	{
		gl.UseProgram(raster_program)
		gl.DispatchCompute(u32(renderer.tiles_x), u32(renderer.tiles_y), 1)
		gl.MemoryBarrier(gl.SHADER_IMAGE_ACCESS_BARRIER_BIT)
	}

	// fill texture
	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
	gl.Disable(gl.CULL_FACE)
	gl.Disable(gl.DEPTH_TEST)
	gl.BindVertexArray(fill.vao)
	gl.UseProgram(fill.program)

	projection := glm.mat4Ortho3d(0, f32(renderer.window_width), f32(renderer.window_height), 0, 0, 1)
	gl.UniformMatrix4fv(fill.loc_projection, 1, gl.FALSE, &projection[0][0])

	gl.BindTexture(gl.TEXTURE_2D, raster_texture_id)
	gl.BindBuffer(gl.ARRAY_BUFFER, fill.vbo)

	{
		w := f32(renderer.window_width)
		h := f32(renderer.window_height)
		u := w / f32(raster_texture_width)
		v := h / f32(raster_texture_height)

		data := [6]Vertex {
			{{ 0, 0 }, { 0, 0 }},
			{{ 0, h }, { 0, v }},
			{{ w, 0 }, { u, 0 }},
			{{ 0, h }, { 0, v }},
			{{ w, 0 }, { u, 0 }},
			{{ w, h }, { u, v }},
		}
		gl.BufferData(gl.ARRAY_BUFFER, size_of(data), &data[0], gl.STREAM_DRAW)
		gl.DrawArrays(gl.TRIANGLES, 0, 6)
	}
}

// ///////////////////////////////////////////////////////////
// // PATHING
// ///////////////////////////////////////////////////////////

// renderer_move_to :: proc(renderer: ^Renderer, x, y: f32) {
// 	path := renderer_path_get(renderer)
	
// 	// if path.curve_index_current > path.curve_index_start {
// 	// 	renderer_path_transition(renderer)
// 	// }

// 	renderer.curve_last = { x, y }
// 	renderer.curve_last_control = renderer.curve_last
// }

// renderer_move_to_rel :: proc(renderer: ^Renderer, x, y: f32) {
// 	path := renderer_path_get(renderer)
// 	// TODO add path transition
// 	renderer.curve_last = renderer.curve_last + { x, y }
// }

// renderer_line_to :: proc(using renderer: ^Renderer, x, y: f32) {
// 	path := renderer_path_get(renderer)
// 	curve_linear_init(
// 		&curves[curve_index],
// 		curve_last,
// 		{ x, y },
// 		renderer.path_index,
// 	)
// 	curve_index += 1
// 	path.curve_index_current = i32(curve_index)
// 	curve_last = { x, y }
// }

// renderer_line_to_rel :: proc(using renderer: ^Renderer, x, y: f32) {
// 	path := renderer_path_get(renderer)
// 	curve_linear_init(
// 		&curves[curve_index],
// 		curve_last,
// 		curve_last + { x, y },
// 		renderer.path_index,
// 	)
// 	curve_index += 1
// 	path.curve_index_current = i32(curve_index)
// 	curve_last = curve_last + { x, y }
// }

// renderer_vertical_line_to :: proc(using renderer: ^Renderer, y: f32) {
// 	path := renderer_path_get(renderer)
// 	curve_linear_init(
// 		&curves[curve_index],
// 		curve_last,
// 		{ curve_last.x, y },
// 		renderer.path_index,
// 	)
// 	curve_index += 1
// 	path.curve_index_current = i32(curve_index)
// 	curve_last = { curve_last.x, y }
// }

// renderer_horizontal_line_to :: proc(using renderer: ^Renderer, x: f32) {
// 	path := renderer_path_get(renderer)
// 	curve_linear_init(
// 		&curves[curve_index],
// 		curve_last,
// 		{ x, curve_last.y },
// 		renderer.path_index,
// 	)
// 	curve_index += 1
// 	path.curve_index_current = i32(curve_index)
// 	curve_last = { x, curve_last.y }
// }

// renderer_quadratic_to :: proc(using renderer: ^Renderer, cx, cy, x, y: f32) {
// 	path := renderer_path_get(renderer)
// 	curve_quadratic_init(
// 		&curves[curve_index],
// 		curve_last,
// 		{ cx, cy },
// 		{ x, y },
// 		renderer.path_index,
// 	)
// 	curve_index += 1
// 	path.curve_index_current = i32(curve_index)
// 	curve_last = { x, y }
// }

// renderer_quadratic_to_rel :: proc(using renderer: ^Renderer, cx, cy, x, y: f32) {
// 	path := renderer_path_get(renderer)
// 	curve_quadratic_init(
// 		&curves[curve_index],
// 		curve_last,
// 		curve_last + { cx, cy },
// 		curve_last + { x, y },
// 		renderer.path_index,
// 	)
// 	curve_index += 1
// 	path.curve_index_current = i32(curve_index)
// 	curve_last = curve_last + { x, y }
// }

// renderer_cubic_to :: proc(using renderer: ^Renderer, c1x, c1y, c2x, c2y, x, y: f32) {
// 	path := renderer_path_get(renderer)
// 	curve_cubic_init(
// 		&curves[curve_index],
// 		curve_last,
// 		{ c1x, c1y },
// 		{ c2x, c2y },
// 		{ x, y },
// 		renderer.path_index,
// 	)
// 	curve_index += 1
// 	path.curve_index_current = i32(curve_index)
// 	curve_last = { x, y }
// 	curve_last_control = { c2x, c2y }
// }

// renderer_cubic_to_rel :: proc(using renderer: ^Renderer, c1x, c1y, c2x, c2y, x, y: f32) {
// 	path := renderer_path_get(renderer)
// 	curve_cubic_init(
// 		&curves[curve_index],
// 		curve_last,
// 		curve_last + { c1x, c1y },
// 		curve_last + { c2x, c2y },
// 		curve_last + { x, y },
// 		renderer.path_index,
// 	)
// 	curve_index += 1
// 	path.curve_index_current = i32(curve_index)
// 	curve_last = curve_last + { x, y }
// }

// renderer_close :: proc(using renderer: ^Renderer) {
// 	if curve_index > 0 {
// 		path := renderer_path_get(renderer)
// 		curve_start := curves[0].B[0]
// 		curve_final := curve_last

// 		if curve_start != curve_final {
// 			curve_linear_init(
// 				&curves[curve_index],
// 				curve_final,
// 				curve_start,
// 				renderer.path_index,
// 			)
// 		}

// 		curve_index += 1
// 		curve_last = { curve_start.x, curve_start.y }
// 		curve_last_control = curve_last
// 	}

// // TODO still looks weird
// // arc to for svg
// renderer_arc_to :: proc(
// 	renderer: ^Renderer,
// 	rx, ry: f32,
// 	rotation: f32,
// 	large_arc: f32,
// 	sweep_direction: f32,
// 	x2, y2: f32,
// ) {
// 	PI :: 3.14159265358979323846264338327

// 	square :: #force_inline proc(a: f32) -> f32 {
// 		return a * a
// 	}

// 	vmag :: #force_inline proc(x, y: f32) -> f32 {
// 		return math.sqrt(x*x + y*y)
// 	}

// 	vecrat :: proc(ux, uy, vx, vy: f32) -> f32 {
// 		return (ux*vx + uy*vy) / (vmag(ux,uy) * vmag(vx,vy))
// 	}

// 	vecang :: proc(ux, uy, vx, vy: f32) -> f32 {
// 		r := vecrat(ux,uy, vx,vy)

// 		if r < -1.0 {
// 			r = -1
// 		}

// 		if r > 1.0 {
// 			r = 1
// 		}

// 		return ((ux*vy < uy*vx) ? -1 : 1) * math.acos(r)
// 	}

// 	// Ported from canvg (https://code.google.com/p/canvg/)
// 	rx := abs(rx)				// y radius
// 	ry := abs(ry)				// x radius
// 	rotx := rotation / 180.0 * PI		// x rotation angle
// 	fa := abs(large_arc) > 1e-6 ? 1 : 0	// Large arc
// 	fs := abs(sweep_direction) > 1e-6 ? 1 : 0	// Sweep direction
// 	// fs = 1
// 	// fa = 0
// 	x1 := renderer.curve_last.x // start point
// 	y1 := renderer.curve_last.y

// 	dx := x1 - x2
// 	dy := y1 - y2
// 	d := math.sqrt(dx*dx + dy*dy)
// 	if d < 1e-6 || rx < 1e-6 || ry < 1e-6 {
// 		// The arc degenerates to a line
// 		renderer_line_to(renderer, x2, y2)
// 		return
// 	}

// 	sinrx := math.sin(rotx)
// 	cosrx := math.cos(rotx)

// 	// Convert to center point parameterization.
// 	// http://www.w3.org/TR/SVG11/implnote.html#ArcImplementationNotes
// 	// 1) Compute x1', y1'
// 	x1p := cosrx * dx / 2.0 + sinrx * dy / 2.0
// 	y1p := -sinrx * dx / 2.0 + cosrx * dy / 2.0
// 	d = square(x1p)/square(rx) + square(y1p)/square(ry)
// 	if d > 1 {
// 		d = math.sqrt(d)
// 		rx *= d
// 		ry *= d
// 	}
// 	// 2) Compute cx', cy'
// 	s := f32(0)
// 	sa := square(rx)*square(ry) - square(rx)*square(y1p) - square(ry)*square(x1p)
// 	sb := square(rx)*square(y1p) + square(ry)*square(x1p)
// 	if sa < 0.0 {
// 		sa = 0
// 	}
// 	if sb > 0.0 {
// 		s = math.sqrt(sa / sb)
// 	}
// 	if fa == fs {
// 		s = -s
// 	}
// 	cxp := s * rx * y1p / ry
// 	cyp := s * -ry * x1p / rx

// 	// 3) Compute cx,cy from cx',cy'
// 	cx := (x1 + x2)/2.0 + cosrx*cxp - sinrx*cyp
// 	cy := (y1 + y2)/2.0 + sinrx*cxp + cosrx*cyp

// 	// 4) Calculate theta1, and delta theta.
// 	ux := (x1p - cxp) / rx
// 	uy := (y1p - cyp) / ry
// 	vx := (-x1p - cxp) / rx
// 	vy := (-y1p - cyp) / ry
// 	a1 := vecang(1, 0, ux, uy)	// Initial angle
// 	da := vecang(ux, uy, vx, vy)		// Delta angle

// 	if fs == 0 && da > 0.0 {
// 		da -= 2 * PI
// 	} else if fs == 1.0 && da < 0.0 {
// 		da += 2 * PI
// 	}

// 	// cosrx += 0.1

// 	// Approximate the arc using cubic spline segments.
// 	t := Xform {
// 		cosrx, sinrx,
// 		-sinrx, cosrx,
// 		cx, cy,
// 	}

// 	// Split arc into max 90 degree segments.
// 	// The loop assumes an iteration per end point (including start and end), this +1.
// 	ndivs := int(abs(da) / (PI*0.5) + 1)
// 	hda := (da / f32(ndivs)) / 2.0
// 	// Fix for ticket #179: division by 0: avoid cotangens around 0 (infinite)
// 	if hda < 1e-3 && hda > -1e-3 {
// 		hda *= 0.5
// 	} else {
// 		hda = (1 - math.cos(hda)) / math.sin(hda)
// 	}

// 	kappa := abs(4.0 / 3.0 * hda)
// 	if da < 0.0 {
// 		kappa = -kappa
// 	}

// 	path := renderer_path_get(renderer)
// 	p, ptan: [2]f32
// 	for i := 0; i <= ndivs; i += 1 {
// 		a := a1 + da * (f32(i)/f32(ndivs))
// 		dx = math.cos(a)
// 		dy = math.sin(a)

// 		curr := xform_point_v2(t, { dx * rx, dy * ry }) // position
// 		tan := xform_v2(t, { -dy*rx * kappa, dx*ry * kappa }) // tangent

// 		if i > 0 {
// 			renderer_cubic_to(renderer, p.x+ptan.x, p.y+ptan.y, curr.x-tan.x, curr.y-tan.y, curr.x, curr.y)
// 		}

// 		p = curr
// 		ptan = tan
// 	}
// }
