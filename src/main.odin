package src

import "core:time"
import "core:fmt"
import "core:math"
import "core:os"
import "core:bytes"
import "core:strings"
import "core:runtime"
import "core:strconv"
import "core:math/linalg"
import glm "core:math/linalg/glsl"
import glfw "vendor:glfw"
import gl "vendor:OpenGL"



length :: linalg.vector_length

App :: struct {
	mouse: Mouse,
	renderer: Renderer,
	ctrl: bool,
	shift: bool,
}
app: App

Mouse :: struct {
	x: f32,
	y: f32,
	left: bool,
	right: bool,
}

TESTING :: #config(TESTING, true)

window_cursor_pos_callback :: proc "c" (handle: glfw.WindowHandle, x, y: f64) {
	app.mouse.x = f32(x)
	app.mouse.y = f32(y)
}

window_mouse_button_callback :: proc "c" (handle: glfw.WindowHandle, button, action, mods: i32) {
	if button == glfw.MOUSE_BUTTON_LEFT {
		app.mouse.left = action == glfw.PRESS
	}

	if button == glfw.MOUSE_BUTTON_RIGHT {
		app.mouse.right = action == glfw.PRESS
	}
}

window_key_callback :: proc "c" (handle: glfw.WindowHandle, key, scancode, action, mods: i32) {
	context = runtime.default_context()
	down := action == glfw.PRESS || action == glfw.REPEAT

	if mods == glfw.MOD_CONTROL {
		app.ctrl = down
	}

	if mods == glfw.MOD_SHIFT {
		app.shift = down
	}

	if mods != 0 {
		return
	}

	if key == glfw.KEY_LEFT_CONTROL {
		app.ctrl = down
	}

	if key == glfw.KEY_LEFT_SHIFT {
		app.shift = down
	}

	// if down {
	// 	switch key {
	// 	case glfw.KEY_1: app.renderer.color_mode = 0
	// 	case glfw.KEY_2: app.renderer.color_mode = 1
	// 	case glfw.KEY_3: app.renderer.color_mode = 2
	// 	case glfw.KEY_4: app.renderer.color_mode = 3

	// 	case glfw.KEY_Q: app.renderer.fill_rule = 0
	// 	case glfw.KEY_W: app.renderer.fill_rule = 1
	// 	case glfw.KEY_E: app.renderer.fill_rule = 2
	// 	case glfw.KEY_R: app.renderer.fill_rule = 3

	// 	case glfw.KEY_SPACE: app.renderer.ignore_temp = app.renderer.ignore_temp == 0 ? 1 : 0
	// 	}
	// }
}

POINTS_PATH :: "test.points"

points_read :: proc(p1, p2, p3: ^[2]f32) {
	content, ok := os.read_entire_file(POINTS_PATH, context.temp_allocator)

	if !ok {
		p1^ = { 0, 0 }
		p2^ = { -50, 100 }
		p3^ = { +50, 100 }
		return
	} 

	read := read_make(content[:])
	size := size_of([2]f32)
	read_ptr(&read, p1, size)
	read_ptr(&read, p2, size)
	read_ptr(&read, p3, size)
}

points_write :: proc(p1, p2, p3: ^[2]f32) {
	fixed: [512]u8
	blob: Blob
	blob.data_buffer = fixed[:]

	size := size_of([2]f32)
	blob_write_ptr(&blob, p1, size)
	blob_write_ptr(&blob, p2, size)
	blob_write_ptr(&blob, p3, size)

	os.write_entire_file(POINTS_PATH, blob_result(blob))
}

print :: proc() {
	def := cast(^runtime.Default_Temp_Allocator) context.temp_allocator.data
	fmt.eprintln(def)		
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
	glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)

	window := glfw.CreateWindow(800, 800, "mpvg", nil, nil)
	defer glfw.DestroyWindow(window)
	if window == nil {
		return
	}

	glfw.SetCursorPosCallback(window, window_cursor_pos_callback)
	glfw.SetMouseButtonCallback(window, window_mouse_button_callback)
	glfw.SetKeyCallback(window, window_key_callback)

	glfw.MakeContextCurrent(window)
	gl.load_up_to(4, 5, glfw.gl_set_proc_address)

	renderer_init(&app.renderer)
	defer renderer_destroy(&app.renderer)

	// renderer_font_push(&app.renderer, "Lato-Regular.ttf")

	p1, p2, p3: [2]f32
	points_read(&p1, &p2, &p3)
	defer points_write(&p1, &p2, &p3)
	scale: [2]f32
	offset: [2]f32

	svg_curves := svg_gen_temp(svg_shield_path)
	defer delete(svg_curves)

	count: f32
	duration: time.Duration
	for !glfw.WindowShouldClose(window) {
		time.SCOPED_TICK_DURATION(&duration)
		free_all(context.temp_allocator)
		width := 800
		height := 800

		mouse_tile_x := clamp(int(app.mouse.x), 0, width) / app.renderer.tiles_size
		mouse_tile_y := clamp(int(app.mouse.y), 0, height) / app.renderer.tiles_size
		window_text := fmt.ctprintf(
			"mpvg %fms, tilex: %d, tiley: %d, tileid: %d, mousex: %d, mousey: %d", 
			time.duration_milliseconds(duration),
			mouse_tile_x,
			mouse_tile_y,
			mouse_tile_x + mouse_tile_y * app.renderer.tiles_x,
			int(app.mouse.x),
			int(app.mouse.y),
		)
		glfw.SetWindowTitle(window, window_text)

		gl.Viewport(0, 0, i32(width), i32(height))
		gl.ClearColor(1, 1, 1, 1)
		gl.Clear(gl.COLOR_BUFFER_BIT)

		{
			renderer_start(&app.renderer, width, height)
			defer renderer_end(&app.renderer, width, height)

			if app.mouse.left {
				p := app.ctrl ? &p1 : &p2
				p.x = app.mouse.x - offset.x
				
				if !app.shift {
					p.y = app.mouse.y - offset.y
				}
			}

			if app.mouse.right {
				p3.x = app.mouse.x - offset.x

				if !app.shift {
					p3.y = app.mouse.y - offset.y
				}
			}

			// renderer_state_translate(&app.renderer, app.mouse.x, app.mouse.y)
			// renderer_circle(&app.renderer, 0, 0, 100)
			
			// renderer_move_to(&app.renderer, 300, 300)
			// renderer_line_to(&app.renderer, app.mouse.x, app.mouse.y)
			// renderer_cubic_to(&app.renderer, p1.x, p1.y, p3.x, p3.y, p2.x, p2.y)
			// renderer_arc_to(&app.renderer, 20, 20, 0, 1, 0, p2.x, p2.y)
			// renderer_quadratic_to(&app.renderer, p3.x, p3.y, p2.x, p2.y)
			renderer_move_to(&app.renderer, p1.x, p1.y)
			renderer_line_to(&app.renderer, p2.x, p2.y)
			renderer_close(&app.renderer)

			// NOTE: NEW
			// renderer_state_translate(&app.renderer, 200, 200)
			// renderer_state_rotate(&app.renderer, count * 0.01)
			// // renderer_state_translate(&app.renderer, app.mouse.x, app.mouse.y)
			// renderer_rect(&app.renderer, -100, -50, 200, 100)

			// // renderer_path_translate(&app.renderer, app.mouse.x, app.mouse.y)
			// renderer_path_translate(&app.renderer, 100, 100)
			// renderer_path_scale(&app.renderer, 10, 10)
			// renderer_svg(&app.renderer, svg_curves)
		}

		glfw.SwapBuffers(window)
		glfw.PollEvents()
		count += 1
	}
}