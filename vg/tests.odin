package vg

import "core:math"

ctx_test_primitives_fill :: proc(ctx: ^Context, mouse: V2, count: f32) {
	{
		save_scoped(ctx)
		fill_color(ctx, { 0, 1, 0, 1 })
		path_begin(ctx)
		rect(ctx, 100, 100, 50, 50)
		fill(ctx)
	}

	{
		save_scoped(ctx)
		path_begin(ctx)
		fill_color(ctx, { 1, 0, 0, 1 })
		translate(ctx, mouse.x, mouse.y)
		rotate(ctx, count * 0.01)
		rect(ctx, -100, -100, 200, 200)
		fill(ctx)
	}

	{
		save_scoped(ctx)
		path_begin(ctx)
		fill_color(ctx, { 0, 0, 1, 1 })
		circle(ctx, 300, 300, 50)
		fill(ctx)
	}

	{
		save_scoped(ctx)
		fill_color(ctx, { 0, 0, 0, 1 })
		font_face(ctx, "regular")
		// text(ctx, "o", 100, 200)
		// text(ctx, "xyz", mouse.x, mouse.y)
		font_size(ctx, math.sin(count * 0.05) * 25 + 50)
		text(ctx, "mpvg is awesome :)", mouse.x, mouse.y)
	}

	{
		save_scoped(ctx)
		fill_color(ctx, { 0, 0.5, 0.5, 1 })
		path_begin(ctx)
		rounded_rect(ctx, 300, 100, 200, 100, 30)
		fill(ctx)
	}
}

ctx_test_glyphs :: proc(ctx: ^Context, mouse: V2, count: int) {
	font_face(ctx, "regular")
	size := math.sin(f32(count) * 0.05) * 25 + 50
	font_size(ctx, size)
	
	fill_color(ctx, { 0, 0, 0, 1 })
	text(ctx, "testing", mouse.x, mouse.y)
	text(ctx, "Lorem ipsum dolor sit amet, consetetur sadipscing elitr, sed diam nonumy eirmod tempor invidunt ut labore et dolore magna ", mouse.x, mouse.y + size)
}

ctx_test_line_strokes :: proc(ctx: ^Context, mouse: V2) {
	temp := V2 { 120, 110 }

	{
		save_scoped(ctx)
		stroke_color(ctx, { 0, 0, 0, 1 })
		stroke_width(ctx, 10)

		path_begin(ctx)
		move_to(ctx, temp.x, temp.y)
		line_to(ctx, 200, 100)
		line_to(ctx, 300, 200)
		line_to(ctx, mouse.x, mouse.y)
		stroke(ctx)
	}

	// circle
	if false {
		save_scoped(ctx)
		fill_color(ctx, { 0, 1, 0, 1 })

		path_begin(ctx)
		circle(ctx, temp.x, temp.y, 5)
		fill(ctx)

		path_begin(ctx)
		circle(ctx, mouse.x, mouse.y, 5)
		fill(ctx)
	}
}

ctx_test_quadratic_strokes :: proc(ctx: ^Context, mouse: V2) {
	start := V2 { 120, 110 }
	control := start + 100
	end := mouse

	{
		save_scoped(ctx)
		stroke_color(ctx, { 0, 0, 0, 1 })
		stroke_width(ctx, 20)

		path_begin(ctx)
		move_to(ctx, start.x - 100, start.y - 100)
		line_to(ctx, start.x, start.y)
		quadratic_to(ctx, control.x, control.y, mouse.x, mouse.y)
		line_to(ctx, 500, 500)
		line_to(ctx, 600, 550)
		stroke(ctx)
	}

	// circle
	{
		save_scoped(ctx)
		fill_color(ctx, { 0, 1, 0, 1 })

		path_begin(ctx)
		circle(ctx, start.x, start.y, 5)
		fill(ctx)

		path_begin(ctx)
		circle(ctx, end.x, end.y, 5)
		fill(ctx)

		t := f32(0.5)
		curve := Curve {
			p = { 0 = start, 1 = control, 2 = end }, count = 1,
		}
		tp := quadratic_bezier_point(curve, t)
		path_begin(ctx)
		circle(ctx, tp.x, tp.y, 5)
		fill(ctx)

		fill_color(ctx, { 1, 0, 0, 1 })
		path_begin(ctx)
		circle(ctx, control.x, control.y, 5)
		fill(ctx)
	}
}

ctx_test_tangents_and_normals :: proc(ctx: ^Context, mouse: V2) {
	start := V2 { 120, 100 }
	control := start + 100
	end := mouse

	curve := Curve {
		p = { 0 = start, 1 = control, 2 = end }, 
		count = 1,
	}

	{
		// save_scoped(ctx)
		// stroke_color(ctx, { 0, 0, 0, 1 })
		// stroke_width(ctx, 20)

		stroke_width(ctx, 4)

		last := curve.p[0]
		STEPS :: 10
		for i in 0..<STEPS {
			t := f32(i) / f32(STEPS)
			tp := quadratic_bezier_point(curve, t)
			path_begin(ctx)
			circle(ctx, tp.x, tp.y, 4)
			fill(ctx)

			path_begin(ctx)
			move_to(ctx, tp.x, tp.y)
			tangent1 := v2_normalize(tp - last)
			p := tp + tangent1 * 20
			line_to(ctx, p.x, p.y)
			stroke_color(ctx, { 0, 0, 1, 1 })
			stroke(ctx)

			path_begin(ctx)
			move_to(ctx, tp.x, tp.y)
			normal1 := v2_perpendicular(v2_normalize(tp - last))
			p = tp + normal1 * 20
			line_to(ctx, p.x, p.y)
			stroke_color(ctx, { 0, 1, 0, 1 })
			stroke(ctx)

			last = tp
		}
	}
}

ctx_test_quadratic_stroke_bug :: proc(ctx: ^Context, mouse: V2, count: f32) {
	start := V2 { 150, 151 } + V2 { count, count }

	{
		save_scoped(ctx)
		stroke_color(ctx, { 0, 0, 0, 1 })
		stroke_width(ctx, 18)

		path_begin(ctx)
		move_to(ctx, start.x - 100, start.y - 100)
		// line_to(ctx, start.x, start.y)
		quadratic_to(ctx, start.x - 60, start.y - 60, start.x, start.y)
		// quadratic_to(ctx, start.x - 50, start.y - 50, mouse.x, mouse.y)
		stroke(ctx)
	}
}

ctx_test_cubic_strokes :: proc(ctx: ^Context, mouse: V2) {
	start := V2 { 200, 200 }
	c1 := start + { 100, -100 }
	c2 := start + { 400, -100 }
	c1, c2 = c2, c1
	end := mouse
	start.x += 200

	{
		save_scoped(ctx)
		stroke_color(ctx, { 0, 0, 0, 1 })
		stroke_width(ctx, 20)

		path_begin(ctx)
		move_to(ctx, start.x - 50, start.y - 50)
		line_to(ctx, start.x, start.y)
		cubic_to(ctx, c1.x, c1.y, c2.x, c2.y, end.x, end.y)
		line_to(ctx, 500, 500)
		// cubic_to(ctx, 510, 510, 520, 520, 400, 600)
		stroke(ctx)
	}

	// circle
	{
		save_scoped(ctx)
		fill_color(ctx, { 0, 1, 0, 1 })

		path_begin(ctx)
		circle(ctx, start.x, start.y, 5)
		fill(ctx)

		stroke_width(ctx, 2)
		stroke_color(ctx, { 1, 0, 0, 1 })
		path_begin(ctx)
		move_to(ctx, start.x, start.y)
		line_to(ctx, c1.x, c1.y)
		line_to(ctx, c2.x, c2.y)
		line_to(ctx, end.x, end.y)
		stroke(ctx)

		path_begin(ctx)
		circle(ctx, end.x, end.y, 5)
		fill(ctx)

		fill_color(ctx, { 1, 0, 0, 1 })
		path_begin(ctx)
		circle(ctx, c1.x, c1.y, 5)
		fill(ctx)

		path_begin(ctx)
		circle(ctx, c2.x, c2.y, 5)
		fill(ctx)
	}
}

ctx_test_primitives_stroke :: proc(ctx: ^Context, mouse: V2, count: int) {
	{
		save_scoped(ctx)
		path_begin(ctx)

		translate(ctx, 100, 100)
		rotate(ctx, f32(count) * 0.01)
		rect(ctx, -50, -50, 100, 100)

		fill_color(ctx, RED)
		fill(ctx)

		stroke_color(ctx, BLACK)
		stroke_width(ctx, 10)
		stroke(ctx)

		path_begin(ctx)
		move_to(ctx, -50, -50)
		reset_transform(ctx)
		line_to(ctx, 300, 300)
		quadratic_to(ctx, 450, 320, 350, 500)
		close(ctx)
		stroke_color(ctx, GREEN)
		stroke_width(ctx, 10)
		stroke(ctx)
	}

	{
		save_scoped(ctx)

		path_begin(ctx)
		rounded_rect(ctx, mouse.x, mouse.y, 200, 200, 20)
		fill_color(ctx, BLUE)
		fill(ctx)

		stroke_width(ctx, 10)
		stroke_color(ctx, GREEN)
		stroke(ctx)
	}
}

ctx_test_clip :: proc(ctx: ^Context, mouse: V2) {
	{
		save_scoped(ctx)
		path_begin(ctx)
		rect(ctx, mouse.x, mouse.y, 100, 100)
		fill(ctx)
	}

	{
		save_scoped(ctx)
		path_begin(ctx)
		rect(ctx, mouse.x, mouse.y, 50, 50)
		scissor(ctx, 50, 50, 200, 200)
		fill_color(ctx, BLUE)
		fill(ctx)

		stroke_width(ctx, 10)
		stroke_color(ctx, BLACK)
		stroke(ctx)
	}

	{
		save_scoped(ctx)
		translate(ctx, mouse.x, mouse.y)
		font_face(ctx, "regular")
		font_size(ctx, 80)
		
		scissor(ctx, 50, 50, 200, 200)
		fill_color(ctx, GREEN)
		text(ctx, "testing")
	}
}