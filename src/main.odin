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
KAPPA90 :: 0.5522847493

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

Path :: struct {
	curves: ^[dynamic]Curve,
	start: int,
	last: [2]f32,
}

path_init :: proc(path: ^Path, curves: ^[dynamic]Curve) {
	path.curves = curves
	path.start = len(curves)
}

path_make :: proc(curves: ^[dynamic]Curve) -> (res: Path) {
	path_init(&res, curves)
	return
}

path_move_to :: proc(path: ^Path, x, y: f32) {
	path.last = { x, y }
}

path_line_to :: proc(path: ^Path, x, y: f32) {
	append(path.curves, c1_make(path.last, { x, y }))
	path.last = { x, y }
}

path_quadratic_to :: proc(path: ^Path, x, y, cx, cy: f32) {
	append(path.curves, c2_make(path.last, { cx, cy }, { x, y }))
	path.last = { x, y }
}

path_cubic_to :: proc(path: ^Path, x, y, c1x, c1y, c2x, c2y: f32) {
	append(path.curves, c3_make(path.last, { c1x, c1y }, { c2x, c2y }, { x, y }))
	path.last = { x, y }
}

path_close :: proc(path: ^Path) {
	if len(path.curves) > 0 {
		start := path.curves[path.start].B[0]
		path_line_to(path, start.x, start.y)
	}
}

path_triangle :: proc(path: ^Path, x, y, r: f32) {
	path_move_to(path, x, y - r/2)
	path_line_to(path, x - r/2, y + r/2)
	path_line_to(path, x + r/2, y + r/2)
	path_close(path)

	// path_move_to(path, x - r/2, y + r/2)
	// path_line_to(path, x + r/2, y + r/2)
	// path_line_to(path, x, y - r/2)
	// path_close(path)
	
	path_print(path)
}

path_rect :: proc(path: ^Path, x, y, w, h: f32) {
	path_move_to(path, x, y)
	// path_line_to(path, x, y + h)
	path_line_to(path, x + 10, y + h)
	// path_line_to(path, x - 50, y + h)
	// path_line_to(path, x + w, y + h - 50)
	path_line_to(path, x + w, y + h)
	path_line_to(path, x + w, y)
	path_close(path)

	path_print(path)
}

path_print :: proc(path: ^Path) {
	fmt.eprintln("~~~")
	for i in path.start..<len(path.curves) {
		curve := path.curves[i]
		fmt.eprintln(curve.B[0], curve.B[1])
	}
}

path_ellipse :: proc(path: ^Path, cx, cy, rx, ry: f32) {
	path_move_to(path, cx-rx, cy)
	path_cubic_to(path, cx-rx, cy+ry*KAPPA90, cx-rx*KAPPA90, cy+ry, cx, cy+ry)
	path_cubic_to(path, cx+rx*KAPPA90, cy+ry, cx+rx, cy+ry*KAPPA90, cx+rx, cy)
	path_cubic_to(path, cx+rx, cy-ry*KAPPA90, cx+rx*KAPPA90, cy-ry, cx, cy-ry)
	path_cubic_to(path, cx-rx*KAPPA90, cy-ry, cx-rx, cy-ry*KAPPA90, cx-rx, cy)
	path_close(path)
}

path_circle :: proc(path: ^Path, cx, cy, r: f32) {
	path_ellipse(path, cx, cy, r, r)
}

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
		// { shader_compute, .COMPUTE },
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

	compute_ssbo: u32
	gl.GenBuffers(1, &compute_ssbo)
	gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, compute_ssbo)

	output := make([dynamic]Implicit_Curve, 0, 32)
	defer delete(output)

	curves := make([dynamic]Curve, 0, 32)

	for !glfw.WindowShouldClose(window) {
		free_all(context.temp_allocator)
		width := 800
		height := 800

		{
			gl.UseProgram(compute_program)

			clear(&curves)
			path := path_make(&curves)
			path_rect(&path, mouse.x,	 mouse.y, 200, 100)
			// path_triangle(&path, mouse.x, mouse.y, 100)
			// path_circle(&path, mouse.x + 50, mouse.y + 50, 50)

			// path_move_to(&path, 0, 0)
			// path_line_to(&path, 100, 100)
			// // path_line_to(&path, 75, 150)
			// path_line_to(&path, 150, 75)
			// path_line_to(&path, 200, 50)
			// path_close(&path)

			clear(&output)
			scale := [2]f32 { 1, 1 }
			offset := [2]f32 { 50, 50 }
			curves_preprocess(&output, curves[:], scale, offset)

			fmt.eprintln("~~~~~~~~~~~~~~~", len(output))
			for i in 0..<len(output) {
				c := output[i]
				fmt.eprintln(c.orientation)
			}

			// fmt.eprintln("~~~~~~~~~~~~~~~", len(output))
			// fmt.eprintf("%#v\n", output[:])

			gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 0, compute_ssbo)
			gl.BindBuffer(gl.SHADER_STORAGE_BUFFER, compute_ssbo)
			gl.BufferData(gl.SHADER_STORAGE_BUFFER, len(output) * size_of(Implicit_Curve), raw_data(output), gl.STREAM_DRAW)

			gl.DispatchCompute(800, 800, 1)
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
				{{ w, 0 }, { 1, 0 }},
				{{ 0, h }, { 0, 1 }},
				{{ 0, h }, { 0, 1 }},
				{{ w, h }, { 1, 1 }},
				{{ w, 0 }, { 1, 0 }},
			}
			gl.BufferData(gl.ARRAY_BUFFER, size_of(data), &data[0], gl.STREAM_DRAW)
			gl.DrawArrays(gl.TRIANGLES, 0, 6)
		}

		glfw.SwapBuffers(window)
		glfw.PollEvents()
	}
}