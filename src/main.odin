package src

import "core:fmt"
import "core:math"
import "core:math/linalg"
import glm "core:math/linalg/glsl"

import "core:os"
import "core:strings"
import "core:runtime"
import "core:strconv"
import glfw "vendor:GLFW"
import gl "vendor:OpenGL"

length :: linalg.vector_length
KAPPA90 :: 0.5522847493 * 2

Mouse :: struct {
	x: f32,
	y: f32,
}
mouse: Mouse

window_cursor_pos_callback :: proc "c" (handle: glfw.WindowHandle, x, y: f64) {
	mouse.x = f32(x)
	mouse.y = f32(y)
}

Vertex :: struct {
	pos: [2]f32,
	uv: [2]f32,
}

shader_vert := #load("vertex.glsl")
shader_frag := #load("fragment.glsl")
shader_compute := #load("mpvg.comp")

// main :: proc() {
// 	values := [5]int { 0, 10, 20, 30, 40 }
// 	output: [5]int

// 	sum: int
// 	for i := len(values) - 1; i >= 0; i -= 1 {
// 		temp := values[i]
// 		output[i] = sum
// 		sum += temp
// 	}

// 	fmt.eprintln(output)
// }

main :: proc() {
	glfw.Init()
	defer glfw.Terminate()

	error_callback :: proc "c" (code: i32, desc: cstring) {
		context = runtime.default_context()
		fmt.eprintln(desc, code)
	}
	glfw.SetErrorCallback(error_callback)

	glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 3)

	window := glfw.CreateWindow(800, 800, "mpvg", nil, nil)
	defer glfw.DestroyWindow(window)
	if window == nil {
		return
	}

	glfw.SetCursorPosCallback(window, window_cursor_pos_callback)

	glfw.MakeContextCurrent(window)
	gl.load_up_to(4, 3, glfw.gl_set_proc_address)

	vao: u32
	gl.GenVertexArrays(1, &vao)
	gl.BindVertexArray(vao)
	defer gl.BindVertexArray(0)

	vbo: u32
	gl.GenBuffers(1, &vbo)
	gl.BindBuffer(gl.ARRAY_BUFFER, vbo)

	size := i32(size_of(Vertex))
	gl.VertexAttribPointer(0, 2, gl.FLOAT, gl.FALSE, size, 0)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(1, 2, gl.FLOAT, gl.FALSE, size, offset_of(Vertex, uv))
	gl.EnableVertexAttribArray(1)

	program, ok := gl.shader_load_sources({ 
		{ shader_vert, .VERTEX }, 
		{ shader_frag, .FRAGMENT },
	})
	if !ok {
		panic("failed loading frag/vert shader")
	}
	loc_projection := gl.GetUniformLocation(program, "projection")

	compute_program, compute_ok := gl.shader_load_sources({{ shader_compute, .COMPUTE }})
	if !compute_ok {
		panic("failed loading compute shader")
	}

	texture_id: u32
	gl.GenTextures(1, &texture_id)
	gl.BindTexture(gl.TEXTURE_2D, texture_id)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.BindImageTexture(0, texture_id, 0, gl.FALSE, 0, gl.WRITE_ONLY, gl.RGBA8)

	{
		w := 800
		h := 800
		gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, i32(w), i32(h), 0, gl.RGBA, gl.UNSIGNED_BYTE, nil)
	}
	gl.BindTexture(gl.TEXTURE_2D, 0)

	compute_curves_ssbo: u32
	gl.GenBuffers(1, &compute_curves_ssbo)
	gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, compute_curves_ssbo)

	compute_tiles_ssbo: u32
	gl.GenBuffers(1, &compute_tiles_ssbo)
	gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, compute_tiles_ssbo)

	compute_commands_ssbo: u32
	gl.GenBuffers(1, &compute_commands_ssbo)
	gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, compute_commands_ssbo)

	renderer := renderer_make()
	defer renderer_destroy(&renderer)

	renderer_font_push(&renderer, "Lato-Regular.ttf")

	count: f32
	for !glfw.WindowShouldClose(window) {
		free_all(context.temp_allocator)
		width := 800
		height := 800

		TILE_SIZE :: 32
		tiles_x := width / TILE_SIZE
		tiles_y := height / TILE_SIZE
		// fmt.eprintln("tiles_x", tiles_x, tiles_y)

		{
			gl.UseProgram(compute_program)

			renderer_clear(&renderer, tiles_x * tiles_y, tiles_x, tiles_y)
			path := renderer_path_make(&renderer)

			// path_quadratic_test(&path, mouse.x, mouse.y)
			// path_cubic_test(&path, mouse.x, mouse.y, 100, count)
			
			// path_rect_test(&path, mouse.x, mouse.y, 200, 200)
			// renderer_path_finish(&renderer, &path)

			path_triangle(&path, mouse.x, mouse.y, 300)
			renderer_path_finish(&renderer, &path)

			// path_circle(&path, mouse.x, mouse.y, 100)

			// renderer_text_push(&renderer, "e", 400, 100, 400)

			// renderer_glyph_push(&renderer, 'y', 200, 100, 100)
			// renderer_path_finish(&renderer, &path)
			// renderer_glyph_push(&renderer, 'x', 200, 150, 100)
			// renderer_path_finish(&renderer, &path)

			// path_move_to(&path, 0, 0)
			// path_line_to(&path, 100, 100)
			// // path_line_to(&path, 75, 150)
			// path_line_to(&path, 150, 75)
			// path_line_to(&path, 200, 50)
			// path_close(&path)

			scale := [2]f32 { 1, 1 }
			// offset := [2]f32 { mouse.x, mouse.y }
			offset := [2]f32 {}
			renderer_process(&renderer, scale, offset)

			renderer_process_tiles(&renderer, f32(width), f32(height))
			// fmt.eprintln("len:", renderer.curve_index, renderer.output_index)

			fmt.eprintln("~~~~~~~~~~~~~~~", renderer.output_index)
			for i in 0..<renderer.output_index {
				c := renderer.output[i]
				fmt.eprint(c.orientation, ' ')
			}
			fmt.eprintln()

			gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 0, compute_curves_ssbo)
			gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, compute_curves_ssbo)
			gl.BufferData(gl.SHADER_STORAGE_BUFFER, renderer.output_index * size_of(Implicit_Curve), raw_data(renderer.output), gl.STREAM_DRAW)

			gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 1, compute_tiles_ssbo)
			gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, compute_tiles_ssbo)
			gl.BufferData(gl.SHADER_STORAGE_BUFFER, renderer.tile_index * size_of(Renderer_Tile), raw_data(renderer.tiles), gl.STREAM_DRAW)

			gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 2, compute_commands_ssbo)
			gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, compute_commands_ssbo)
			gl.BufferData(gl.SHADER_STORAGE_BUFFER, renderer.command_index * size_of(Renderer_Command), raw_data(renderer.commands), gl.STREAM_DRAW)

			gl.DispatchCompute(u32(tiles_x), u32(tiles_y), 1)
		}

		gl.MemoryBarrier(gl.SHADER_IMAGE_ACCESS_BARRIER_BIT)

		gl.Viewport(0, 0, i32(width), i32(height))
		gl.ClearColor(1, 1, 1, 1)
		gl.Clear(gl.COLOR_BUFFER_BIT)

		gl.Enable(gl.BLEND)
		gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
		gl.Disable(gl.CULL_FACE)
		gl.Disable(gl.DEPTH_TEST)
		gl.BindVertexArray(vao)
		gl.UseProgram(program)

		projection := glm.mat4Ortho3d(0, f32(width), f32(height), 0, 0, 1)
		gl.UniformMatrix4fv(loc_projection, 1, gl.FALSE, &projection[0][0])

		gl.BindTexture(gl.TEXTURE_2D, texture_id)
		gl.BindBuffer(gl.ARRAY_BUFFER, vbo)

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

		glfw.SwapBuffers(window)
		glfw.PollEvents()
		count += 1
	}
}