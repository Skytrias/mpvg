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
import glfw "vendor:GLFW"
import gl "vendor:OpenGL"

length :: linalg.vector_length

App :: struct {
	mouse: Mouse,
	renderer: Renderer,
	ctrl: bool,
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

	if mods != 0 {
		return
	}

	if key == glfw.KEY_LEFT_CONTROL {
		app.ctrl = down
	}

	if down {
		switch key {
		case glfw.KEY_1: app.renderer.color_mode = 0
		case glfw.KEY_2: app.renderer.color_mode = 1
		case glfw.KEY_3: app.renderer.color_mode = 2
		case glfw.KEY_4: app.renderer.color_mode = 3

		case glfw.KEY_Q: app.renderer.fill_rule = 0
		case glfw.KEY_W: app.renderer.fill_rule = 1
		case glfw.KEY_E: app.renderer.fill_rule = 2
		case glfw.KEY_R: app.renderer.fill_rule = 3

		case glfw.KEY_SPACE: app.renderer.ignore_temp = app.renderer.ignore_temp == 0 ? 1 : 0
		}
	}
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
	
	read_ptr(&read, &app.renderer.color_mode, size_of(int))
	read_ptr(&read, &app.renderer.fill_rule, size_of(int))
}

points_write :: proc(p1, p2, p3: ^[2]f32) {
	fixed: [512]u8
	blob: Blob
	blob.data_buffer = fixed[:]

	size := size_of([2]f32)
	blob_write_ptr(&blob, p1, size)
	blob_write_ptr(&blob, p2, size)
	blob_write_ptr(&blob, p3, size)

	blob_write_ptr(&blob, &app.renderer.color_mode, size_of(int))
	blob_write_ptr(&blob, &app.renderer.fill_rule, size_of(int))

	os.write_entire_file(POINTS_PATH, blob_result(blob))
}

// World :: struct {
// 	resources: map[typeid]rawptr,
// }

// get_resource :: proc(world: ^World, $T: typeid) -> Maybe(^T) {
// 	if !(T in world.resources) {
// 		return nil
// 	}

// 	return cast(^T) &world.resources[T]
// }

// main :: proc() {
// 	world: World
// 	world.resources = make(map[typeid]rawptr, 32)

// 	Test :: struct {
// 		value: int,
// 	}

// 	world.resources[Test] = nil
// 	res := get_resource(&world, Test)
// 	fmt.eprintln(res.?)

// 	// path_svg(nil, svg_shield_path)
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
	glfw.SetMouseButtonCallback(window, window_mouse_button_callback)
	glfw.SetKeyCallback(window, window_key_callback)

	glfw.MakeContextCurrent(window)
	gl.load_up_to(4, 3, glfw.gl_set_proc_address)

	renderer_init(&app.renderer)
	defer renderer_destroy(&app.renderer)

	renderer_font_push(&app.renderer, "Lato-Regular.ttf")

	p1, p2, p3: [2]f32
	points_read(&p1, &p2, &p3)
	defer points_write(&p1, &p2, &p3)
	scale: [2]f32
	offset: [2]f32

	svg_curves := path_svg_make(svg_shield_path)
	defer delete(svg_curves)

	count: f32
	duration: time.Duration
	for !glfw.WindowShouldClose(window) {
		time.SCOPED_TICK_DURATION(&duration)
		free_all(context.temp_allocator)
		width := 800
		height := 800

		TILE_SIZE :: 32
		tiles_x := width / TILE_SIZE
		tiles_y := height / TILE_SIZE
		// fmt.eprintln("tiles_x", tiles_x, tiles_y)

		mouse_tile_x := clamp(int(app.mouse.x), 0, width) / TILE_SIZE
		mouse_tile_y := clamp(int(app.mouse.y), 0, height) / TILE_SIZE
		window_text := fmt.ctprintf(
			"mpvg %fms, tilex: %d, tiley: %d, tileid: %d", 
			time.duration_milliseconds(duration),
			mouse_tile_x,
			mouse_tile_y,
			mouse_tile_x + mouse_tile_y * tiles_x,
		)
		glfw.SetWindowTitle(window, window_text)

		gl.Viewport(0, 0, i32(width), i32(height))
		gl.ClearColor(1, 1, 1, 1)
		gl.Clear(gl.COLOR_BUFFER_BIT)

		{
			renderer_start(&app.renderer, tiles_x * tiles_y, tiles_x, tiles_y)
			defer renderer_end(&app.renderer, width, height)
			
			path := renderer_path_make(&app.renderer)
			// path_move_to(&path, p1.x, p1.y)
			// path_line_to(&path, p2.x, p2.y)
			// path_line_to(&path, p3.x, p3.y)
			// path_close(&path)
			// renderer_path_finish(&app.renderer, &path)

			// if app.mouse.left {
			// 	p := app.ctrl ? &p1 : &p2
			// 	p.x = app.mouse.x - offset.x
			// 	p.y = app.mouse.y - offset.y
			// }

			// if app.mouse.right {
			// 	p3.x = app.mouse.x - offset.x
			// 	p3.y = app.mouse.y - offset.y
			// }

			// path_quadratic_test(&path, app.mouse.x, app.mouse.y)
			// path_cubic_test(&path, app.mouse.x, app.mouse.y, 100, count)

			// path_rect_test(&path, app.mouse.x, app.mouse.y, 200, 100)
			// path_triangle(&path, app.mouse.x, app.mouse.y, 200)
			// path_circle(&path, app.mouse.x, app.mouse.y, 100)

			// renderer_text_push(&app.renderer, "e", 400, app.mouse.x, app.mouse.y)

			// path_svg(&path, svg_shield_path)
			// path_mpvg_test(&path, app.mouse.x, app.mouse.y)
			// renderer_path_finish(&app.renderer, &path)

			renderer_curves_push(&app.renderer, svg_curves)

			// path_move_to(&path, 0, 0)
			// path_line_to(&path, 100, 100)
			// // path_line_to(&path, 75, 150)
			// path_line_to(&path, 150, 75)
			// path_line_to(&path, 200, 50)
			// path_close(&path)

			// scale = [2]f32 { 1, 1 }
			// offset = [2]f32 { 0, 0 }
			scale = [2]f32 { 5, 5 }
			offset = [2]f32 { app.mouse.x, app.mouse.y }
			renderer_process(&app.renderer, scale, offset)

			// fmt.eprintln("len:", renderer.curve_index, renderer.output_index)

			// fmt.eprint(renderer.output_index, ' ')
			// for i in 0..<renderer.output_index {
			// 	c := renderer.output[i]
			// 	fmt.eprint(c.orientation, ' ')
			// }
		}

		glfw.SwapBuffers(window)
		glfw.PollEvents()
		count += 1
	}
}