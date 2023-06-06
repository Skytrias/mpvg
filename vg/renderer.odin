package vg

import "core:os"
import "core:fmt"
import "core:mem"
import "core:math"
import "core:strings"

import glm "core:math/linalg/glsl"
import sa "core:container/small_array"
import gl "vendor:OpenGL"

TILE_SIZE :: 32 // has to match compute header
MAX_CURVES :: 4048 * 8
MAX_PATHS :: 1028 * 4
SIZE_IMPLICIT_CURVES :: mem.Megabyte * 2
SIZE_TILE_QUEUES :: mem.Megabyte * 2
SIZE_TILE_OPERATIONS :: mem.Megabyte * 4
SIZE_SCREEN_TILES :: mem.Megabyte * 2

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

	stroke: b32, // fill default - stroke does fills for winding non 0
	curve_start: i32, // start index
	curve_end: i32, // end index
	closed: b32, // closed path
}

// curve Linear, Quadratic, Cubic in flat structure
Curve :: struct #packed {
	p: [4][2]f32,
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
	// tile_backprop_program = renderer_gpu_shader_compute(&builder, compute_header, compute_tile_backprop, 16, 1)
	tile_backprop_program = renderer_gpu_shader_compute(&builder, compute_header, compute_tile_backprop, 1, 1)
	path_setup_program = renderer_gpu_shader_compute(&builder, compute_header, compute_path_setup, 1, 1)
	tile_merge_program = renderer_gpu_shader_compute(&builder, compute_header, compute_tile_merge, 1, 1)

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
	renderer.tiles_x = int(math.ceil(f32(width) / TILE_SIZE))
	renderer.tiles_y = int(math.ceil(f32(height) / TILE_SIZE))

	fa_clear(&renderer.curves)
	fa_clear(&renderer.paths)

	renderer.indices = {}
	renderer.indices.tiles_x = i32(renderer.tiles_x)
	renderer.indices.tiles_y = i32(renderer.tiles_y)

	renderer.window_width = width
	renderer.window_height = height
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
	strings.write_byte(builder, '\n')

	// write rest of the data
	strings.write_bytes(builder, data)

	// // fmt.eprintln("FINAL", strings.to_string(builder^))
	// os.write_entire_file("debug.comp", builder.buf[:])

	// write result
	program, ok := gl.load_compute_source(strings.to_string(builder^))
	if !ok {
		panic("failed loading compute shader", loc)
	}

	return program
}

renderer_end :: proc(using renderer: ^Renderer) {	
	if renderer.curves.index == 0 {
		return
	}

	// write in the final path count
	path_count := renderer.paths.index
	renderer.indices.paths = i32(path_count)
	// fmt.eprintln("PATH COUNT", path_count)

	// for i in 0..<renderer.curves.index {
	// 	curve := renderer.curves.data[i]
	// 	curve_print(curve)
	// }

	// bind
	{
		gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, indices_ssbo)
		gl.NamedBufferSubData(indices_ssbo, 0, size_of(Indices), &renderer.indices)

		gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, paths_ssbo)
		gl.NamedBufferSubData(paths_ssbo, 0, path_count * size_of(Path), fa_raw(&renderer.paths))

		gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, curves_ssbo)
		gl.NamedBufferSubData(curves_ssbo, 0, renderer.curves.index * size_of(Curve), fa_raw(&renderer.curves))
	}

	// path setup
	{
		gl.UseProgram(path_setup_program)
		gl.DispatchCompute(u32(path_count), 1, 1)
		gl.MemoryBarrier(gl.ALL_BARRIER_BITS)
	}

	// implicitize stage
	{
		gl.UseProgram(curve_implicitize_program)
		gl.DispatchCompute(u32(renderer.curves.index), 1, 1)
		gl.MemoryBarrier(gl.ALL_BARRIER_BITS)
	}

	// tile backprop stage go by 0->tiles_y
	{
		gl.UseProgram(tile_backprop_program)
		gl.DispatchCompute(u32(path_count), 1, 1)
		gl.MemoryBarrier(gl.ALL_BARRIER_BITS)
	}

	// tile merging to screen tiles
	{
		gl.UseProgram(tile_merge_program)
		gl.DispatchCompute(u32(renderer.tiles_x), u32(renderer.tiles_y), 1)
		gl.MemoryBarrier(gl.ALL_BARRIER_BITS)
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
