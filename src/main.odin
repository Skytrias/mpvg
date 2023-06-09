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
	ctx: vg.Context,
	ctrl: bool,
	shift: bool,

	window: glfw.WindowHandle,
	window_width: int,
	window_height: int,

	line_join: vg.Line_Join,
	line_cap: vg.Line_Cap,
}
app: App

Mouse :: struct {
	using pos: vg.V2,
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

	switch key {
	case glfw.KEY_1: app.line_join = vg.Line_Join(0)
	case glfw.KEY_2: app.line_join = vg.Line_Join(1)
	case glfw.KEY_3: app.line_join = vg.Line_Join(2)

	case glfw.KEY_Q: app.line_cap = vg.Line_Cap(0)
	case glfw.KEY_W: app.line_cap = vg.Line_Cap(1)
	case glfw.KEY_E: app.line_cap = vg.Line_Cap(2)
	case glfw.KEY_S: 
		if action == glfw.PRESS {
			app.ctx.stroke_joints = !app.ctx.stroke_joints
		}
	}
}

window_size_callback :: proc "c" (handle: glfw.WindowHandle, width, height: i32) {
	app.window_width = int(width)
	app.window_height = int(height)
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
	glfw.WindowHint(glfw.OPENGL_FORWARD_COMPAT, 1)
	glfw.WindowHint(glfw.OPENGL_DEBUG_CONTEXT, 1)
	glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)

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

	app.ctx = vg.ctx_make()
	defer vg.ctx_destroy(&app.ctx)

	// load bindless texture calls
	gl_GetTextureHandle := glfw.GetProcAddress("glGetTextureHandleARB")
	if gl_GetTextureHandle == nil {
		gl_GetTextureHandle = glfw.GetProcAddress("glGetTextureHandleNV")
	}
	gl_MakeTextureHandleResident := glfw.GetProcAddress("glMakeTextureHandleResidentARB")
	if gl_MakeTextureHandleResident == nil {
		gl_MakeTextureHandleResident = glfw.GetProcAddress("glMakeTextureHandleResidentNV")
	}
	if gl_GetTextureHandle == nil || gl_MakeTextureHandleResident == nil {
		fmt.eprintln("Required OpenGL extensions:")
		fmt.eprintln("\tglGetTextureHandleARB")
		fmt.eprintln("\tglMakeTextureHandleResidentARB")
		os.exit(1)
	}

	// load texture handle calls
	app.ctx.renderer.gl_GetTextureHandle = auto_cast gl_GetTextureHandle
	app.ctx.renderer.gl_MakeTextureHandleResident = auto_cast gl_MakeTextureHandleResident

	vg.font_push(&app.ctx, "regular", "Lato-Regular.ttf", true)

	// svg_curves := vg.svg_gen_temp(svg_AB)
	// defer vg.delete(svg_curves)

	fmt.eprintln("PATH", size_of(vg.Path))

	count: int
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
			mouse_tile_x + mouse_tile_y * app.ctx.renderer.tiles_x,
			int(app.mouse.x),
			int(app.mouse.y),
		)
		glfw.SetWindowTitle(app.window, window_text)

		gl.Viewport(0, 0, i32(app.window_width), i32(app.window_height))
		gl.ClearColor(1, 1, 1, 1)
		gl.Clear(gl.COLOR_BUFFER_BIT)

		{
			ctx := &app.ctx

			// TODO add px ratio
			vg.ctx_frame_begin(ctx, app.window_width, app.window_height, 1)
			defer vg.ctx_frame_end(ctx)

			// vg.ctx_test_primitives(ctx, app.mouse.pos, count)
			// vg.ctx_test_glyphs(ctx, app.mouse.pos, count)

			vg.line_join(ctx, app.line_join)
			vg.line_cap(ctx, app.line_cap)
			// vg.ctx_test_primitives_stroke(ctx, app.mouse.pos, count)

			// vg.ctx_test_clip(ctx, app.mouse.pos)
			// vg.ctx_test_line_strokes(ctx, app.mouse.pos)
			// vg.ctx_test_quadratic_strokes(ctx, app.mouse.pos)
			// vg.ctx_test_cubic_strokes(ctx, app.mouse.pos)
			// vg.ctx_test_quadratic_stroke_bug(ctx, app.mouse.pos, f32(count) * 0.1)
			// vg.ctx_test_tangents_and_normals(ctx, app.mouse.pos)
			vg.ctx_test_texture(ctx, app.mouse.pos)
		}

		glfw.SwapBuffers(app.window)
		glfw.PollEvents()
		count += 1
	}
}