package src

import "core:fmt"

Path :: struct {
	curves: []Curve,
	offset: int,
	last: [2]f32,
}

path_init :: proc(path: ^Path, curves: []Curve) {
	path.curves = curves
}

path_make :: proc(curves: []Curve) -> (res: Path) {
	path_init(&res, curves)
	return
}

path_move_to :: proc(path: ^Path, x, y: f32) {
	path.last = { x, y }
}

path_line_to :: proc(path: ^Path, x, y: f32) {
	path.curves[path.offset] = c1_make(path.last, { x, y })
	path.offset += 1
	path.last = { x, y }
}

path_quadratic_to :: proc(path: ^Path, x, y, cx, cy: f32) {
	path.curves[path.offset] = c2_make(path.last, { cx, cy }, { x, y })
	path.offset += 1
	path.last = { x, y }
}

path_cubic_to :: proc(path: ^Path, x, y, c1x, c1y, c2x, c2y: f32) {
	path.curves[path.offset] = c3_make(path.last, { c1x, c1y }, { c2x, c2y }, { x, y })
	path.offset += 1
	path.last = { x, y }
}

path_close :: proc(path: ^Path) {
	if path.offset > 0 {
		start := path.curves[0].B[0]
		path_line_to(path, start.x, start.y)
	}
}

path_finish_curves :: proc(path: ^Path, curves: ^[]Curve) {
	curves^ = curves[path.offset:]
}

path_triangle :: proc(path: ^Path, x, y, r: f32) {
	path_move_to(path, x, y - r/2)
	path_line_to(path, x - r/2, y + r/2)
	path_line_to(path, x + r/2, y + r/2)
	path_close(path)	
}

path_rect_test :: proc(path: ^Path, x, y, w, h: f32) {
	path_move_to(path, x, y)
	path_line_to(path, x - 50, y + h + 50)
	path_line_to(path, x + w - 50, y + h)
	path_line_to(path, x + w, y)
	path_close(path)
}

path_rect :: proc(path: ^Path, x, y, w, h: f32) {
	path_move_to(path, x, y)
	path_line_to(path, x, y + h)
	path_line_to(path, x + w, y + h)
	path_line_to(path, x + w, y)
	path_close(path)
}

path_print :: proc(path: ^Path) {
	fmt.eprintln("~~~")
	for i in 0..<path.offset {
		curve := path.curves[i]
		fmt.eprintln(curve.B[0], curve.B[1])
	}
}

path_ellipse :: proc(path: ^Path, cx, cy, rx, ry: f32) {
	path_move_to(path, cx-rx, cy)
	path_cubic_to(path, cx, cy+ry, cx-rx, cy+ry*KAPPA90, cx-rx*KAPPA90, cy+ry)
	path_cubic_to(path, cx+rx, cy, cx+rx*KAPPA90, cy+ry, cx+rx, cy+ry*KAPPA90)
	path_cubic_to(path, cx, cy-ry, cx+rx, cy-ry*KAPPA90, cx+rx*KAPPA90, cy-ry)
	path_cubic_to(path, cx-rx, cy, cx-rx*KAPPA90, cy-ry, cx-rx, cy-ry*KAPPA90)
	// path_close(path)
}

path_circle :: proc(path: ^Path, cx, cy, r: f32) {
	path_ellipse(path, cx, cy, r, r)
}

Renderer :: struct {
	output: []Implicit_Curve,
	output_index: int,

	curves: []Curve,
	curve_index: int,

	contexts: []Implicizitation_Context,
	roots: []Roots,
}

renderer_init :: proc(renderer: ^Renderer) {
	renderer.output = make([]Implicit_Curve, 256)
	renderer.roots = make([]Roots, 256)
	renderer.contexts = make([]Implicizitation_Context, 256)
	renderer.curves = make([]Curve, 256)
}

renderer_destroy :: proc(renderer: ^Renderer) {
	delete(renderer.output)
	delete(renderer.curves)
	delete(renderer.roots)
	delete(renderer.contexts)
}

renderer_make :: proc() -> (res: Renderer) {
	renderer_init(&res)
	return
}

renderer_clear :: proc(renderer: ^Renderer) {
	renderer.curve_index = 0
	renderer.output_index = 0
}

renderer_path_make :: proc(renderer: ^Renderer) -> (res: Path) {
	path_init(&res, renderer.curves[renderer.curve_index:])
	return
}

renderer_path_finish :: proc(renderer: ^Renderer, path: ^Path) {
	renderer.curve_index += path.offset
}

renderer_process :: proc(using renderer: ^Renderer, scale, offset: [2]f32) {
	results := curves[:curve_index]

	for c, i in results {
		preprocess1[c.count](c, &roots[i], &contexts[i])
	}

	for c, i in results {
		root := &roots[i]
		ctx := &contexts[i]
		preprocess2[c.count](output, &renderer.output_index, c, root, scale, offset, ctx)
	}
}
