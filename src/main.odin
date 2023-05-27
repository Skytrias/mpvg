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
import "../vg"
import glm "core:math/linalg/glsl"
import glfw "vendor:glfw"
import gl "vendor:OpenGL"

length :: linalg.vector_length

App :: struct {
	mouse: Mouse,
	renderer: vg.Renderer,
	ctrl: bool,
	shift: bool,

	window: glfw.WindowHandle,
	window_width: int,
	window_height: int,
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
}

window_size_callback :: proc "c" (handle: glfw.WindowHandle, width, height: i32) {
	app.window_width = int(width)
	app.window_height = int(height)
}

// main :: proc() {
// 	vg.sparse_set_test()
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
	glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)

	app.window_width = 800
	app.window_height = 800
	app.window = glfw.CreateWindow(i32(app.window_width), i32(app.window_height), "mpvg", nil, nil)
	defer glfw.DestroyWindow(app.window)
	if app.window == nil {
		return
	}

	glfw.SetCursorPosCallback(app.window, window_cursor_pos_callback)
	glfw.SetMouseButtonCallback(app.window, window_mouse_button_callback)
	glfw.SetKeyCallback(app.window, window_key_callback)
	glfw.SetWindowSizeCallback(app.window, window_size_callback)

	glfw.MakeContextCurrent(app.window)
	gl.load_up_to(4, 5, glfw.gl_set_proc_address)

	ctx := vg.ctx_make()
	defer vg.ctx_destroy(&ctx)

	// vg.renderer_init(&app.renderer)
	// defer vg.renderer_destroy(&app.renderer)

	// vg.renderer_font_push(&app.renderer, "Lato-Regular.ttf")

	// svg_curves := vg.svg_gen_temp(svg_AB)
	// defer vg.delete(svg_curves)

	count: f32
	duration: time.Duration
	for !glfw.WindowShouldClose(app.window) {
		time.SCOPED_TICK_DURATION(&duration)
		free_all(context.temp_allocator)

		mouse_tile_x := clamp(int(app.mouse.x), 0, app.window_width) / vg.TILE_SIZE
		mouse_tile_y := clamp(int(app.mouse.y), 0, app.window_height) / vg.TILE_SIZE
		window_text := fmt.ctprintf(
			"mpvg %fms, tilex: %d, tiley: %d, tileid: %d, mousex: %d, mousey: %d", 
			time.duration_milliseconds(duration),
			mouse_tile_x,
			mouse_tile_y,
			mouse_tile_x + mouse_tile_y * app.renderer.tiles_x,
			int(app.mouse.x),
			int(app.mouse.y),
		)
		glfw.SetWindowTitle(app.window, window_text)

		gl.Viewport(0, 0, i32(app.window_width), i32(app.window_height))
		gl.ClearColor(1, 1, 1, 1)
		gl.Clear(gl.COLOR_BUFFER_BIT)

		{
			// TODO add px ratio
			vg.ctx_frame_begin(&ctx, app.window_width, app.window_height, 1)
			defer vg.ctx_frame_end(&ctx)

			vg.path_begin(&ctx)
			vg.ctx_translate(&ctx, app.mouse.x, app.mouse.y)
			vg.ctx_rotate(&ctx, count * 0.01)
			vg.push_rect(&ctx, -100, -100, 200, 200)
			// vg.push_rect(&ctx, 100, 100, 200, 200)
			// vg.push_move_to(&ctx, 100, 100)
			// vg.push_line_to(&ctx, 200, 200)
			vg.fill(&ctx)
		}

		// {
		// 	vg.renderer_start(&app.renderer, app.window_width, app.window_height)
		// 	defer vg.renderer_end(&app.renderer)

		// 	// NOTE: NEW
		// 	// renderer_path_translate(&app.renderer, 200, 200)
		// 	vg.renderer_path_color(&app.renderer, { 1, 0, 0, 1 })
		// 	vg.renderer_path_translate(&app.renderer, app.mouse.x, app.mouse.y)
		// 	vg.renderer_path_rotate(&app.renderer, count * 0.01)
		// 	vg.renderer_rect(&app.renderer, -100, -50, 200, 100)
		// 	vg.renderer_path_push(&app.renderer)

		// 	// renderer_path_translate(&app.renderer, app.mouse.x, app.mouse.y)
		// 	// // renderer_path_translate(&app.renderer, 100, 100)
		// 	// // renderer_path_scale(&app.renderer, 5, 5)
		// 	// // renderer_path_scale(&app.renderer, 10, 10)
		// 	// renderer_path_scale(&app.renderer, 20, 20)
		// 	// // renderer_path_scale(&app.renderer, 50, 50)
		// 	// renderer_svg(&app.renderer, svg_curves)

		// 	// path := renderer_path_get(&app.renderer)
		// 	// path.stroke = true
		// 	vg.renderer_path_color(&app.renderer, { 0, 0, 0, 1 })
		// 	vg.renderer_path_translate(&app.renderer, app.mouse.x, app.mouse.y)
		// 	vg.renderer_path_scale(&app.renderer, 1, 1)
		// 	// renderer_text_push(&app.renderer, "xyzlp", 0, 0, math.sin(count * 0.05) * 20 + 200)
		// 	vg.renderer_text_push(&app.renderer, "text works", 0, 0, math.sin(count * 0.05) * 20 + 100)
		// 	// renderer_text_push(&app.renderer, "Lorem ipsum dolor sit amet, consetetur sadipscing elitr, sed diam nonumy eirmod tempor invidunt ut labore et dolore magna ", 0, 0, math.sin(count * 0.05) * 10 + 40)
		// }	

		glfw.SwapBuffers(app.window)
		glfw.PollEvents()
		count += 1
	}
}