package src

import "core:fmt"
import "core:os"
import stbtt "vendor:stb/truetype"

// font state storing scaling information
// simple map to retrieve already created glyphs, could do a LUT
Font :: struct {
	info: stbtt.fontinfo,
	info_data: []byte,

	scaling: f32,
	ascender: f32,
	descender: f32,
	line_height: f32,

	gc: Glyph_Compiler,
	glyph_map: map[rune]Glyph,
}

// builds vertices for a wanted glyph
Glyph_Compiler :: struct {
	curves: []Curve,
	curve_index: int,
	current_x: f32,
	current_y: f32,
	contour_count: int,
	glyph: ^Glyph, // glyph that gets modified
}

// glyph storing its vertices that have to be copied to the renderer
Glyph :: struct {
	curves: []Curve, // copied from glyph_compiler
	index: i32,
	advance: f32,
}

font_make :: proc(path: string) -> (res: Font) {
	font_init(&res, path)
	return
}

// init a font from a path
font_init :: proc(font: ^Font, path: string) {
	ok: bool
	font.info_data, ok = os.read_entire_file(path)
	assert(ok)
	stbtt.InitFont(&font.info, raw_data(font.info_data), 0)

	// properties we want
	a, d, l: i32
	stbtt.GetFontVMetrics(&font.info, &a, &d, &l)
	fh := f32(a - d)
	font.ascender = f32(a) / fh
	font.descender = f32(d) / fh
	font.line_height = f32(l) / fh
	font.scaling = 1.0 / fh

	font.glyph_map = make(map[rune]Glyph, 128)
	glyph_compiler_init(&font.gc, 1028)
}

font_destroy :: proc(using font: Font) {
	delete(info_data)
	
	// for _, glyph in glyph_map {
	// 	delete(glyph.vertices)
	// }
	delete(glyph_map)

	glyph_compiler_destroy(gc)
}

// retrieve cached or generate the wanted glyph vertices and its bounding box
font_get_glyph :: proc(font: ^Font, codepoint: rune) -> (res: ^Glyph) {
	if glyph, ok := &font.glyph_map[codepoint]; ok {
		res = glyph
	} else {
		glyph_index := stbtt.FindGlyphIndex(&font.info, codepoint)

		if glyph_index == 0 {
			return
		}

		font.glyph_map[codepoint] = {}
		res = &font.glyph_map[codepoint]
		res.index = glyph_index

		// retrieve vertice info
		codepoint_vertices: [^]stbtt.vertex
		number_of_vertices := stbtt.GetGlyphShape(&font.info, glyph_index, &codepoint_vertices)
		defer stbtt.FreeShape(&font.info, codepoint_vertices)

		// push glyph properties from stbtt
		advance, lsb: i32
		stbtt.GetGlyphHMetrics(&font.info, glyph_index, &advance, &lsb)
		res.advance = f32(advance) * font.scaling

		gc := &font.gc
		assert(gc.curves != nil)
		glyph_compiler_begin(gc, res)

		for i := i32(0); i < number_of_vertices; i += 1 {
			v := codepoint_vertices[i]

			if v.type == u8(stbtt.vmove.vmove) {
				glyph_compiler_move_to(
					gc, 
					f32(v.x) * font.scaling, 
					-f32(v.y) * font.scaling + font.ascender * font.scaling,
				)
			} else if v.type == u8(stbtt.vmove.vline) {
				glyph_compiler_line_to(
					gc, 
					f32(v.x) * font.scaling, 
					-f32(v.y) * font.scaling + font.ascender * font.scaling,
				)
			} else if v.type == u8(stbtt.vmove.vcurve) {
				glyph_compiler_curve_to(
					gc, 
					f32(v.cx) * font.scaling,
					-f32(v.cy) * font.scaling + font.ascender * font.scaling,
					f32(v.x) * font.scaling, 
					-f32(v.y) * font.scaling + font.ascender * font.scaling,
				)
			}
		}

		glyph_compiler_end(gc)
	}

	return	
}

// could just be in font_init :)
glyph_compiler_init :: proc(gc: ^Glyph_Compiler, cap: int) {
	gc.curves = make([]Curve, cap)
	gc.current_x = 0
	gc.current_y = 0
}

glyph_compiler_destroy :: proc(gc: Glyph_Compiler) {
	delete(gc.curves)
}

// begin vertex building
glyph_compiler_begin :: proc(using gc: ^Glyph_Compiler, glyph_modify: ^Glyph) {
	curve_index = 0
	glyph = glyph_modify
}

glyph_compiler_move_to :: proc(using gc: ^Glyph_Compiler, x, y: f32) {
	current_x = x
	current_y = y
	contour_count = 0
}

glyph_compiler_line_to :: proc(using gc: ^Glyph_Compiler, x, y: f32) {
	contour_count += 1

	curve_linear_init(
		&gc.curves[gc.curve_index], 
		{ current_x, current_y }, 
		{ x, y },
		0,
	)

	gc.curve_index += 1
	current_x = x
	current_y = y
}

glyph_compiler_curve_to :: proc(using gc: ^Glyph_Compiler, cx, cy, x, y: f32) {
	contour_count += 1

	curve_linear_init(&gc.curves[gc.curve_index], { current_x, current_y }, { x, y }, 0)
	gc.curve_index += 1

	curve_quadratic_init(&gc.curves[gc.curve_index], { current_x, current_y }, { cx, cy }, { x, y }, 0)
	gc.curve_index += 1
	
	current_x = x
	current_y = y
}

// NOTE could just have giant glyph storage instead of seperate ones, or offset the glyph_compiler
// copy data over to glyph
glyph_compiler_end :: proc(using gc: ^Glyph_Compiler) {
	assert(glyph.curves == nil)
	glyph.curves = make([]Curve, curve_index)
	copy(glyph.curves, curves[:curve_index])
}

// retrieve cached or generate the wanted glyph vertices and its bounding box
renderer_font_glyph :: proc(
	renderer: ^Renderer, 
	font: ^Font, 
	codepoint: rune,
	offset_x, offset_y: f32,
	size: f32,
) -> f32 {
	glyph_index := stbtt.FindGlyphIndex(&font.info, codepoint)
	if glyph_index == 0 {
		return 0
	}

	// retrieve vertice info
	codepoint_vertices: [^]stbtt.vertex
	number_of_vertices := stbtt.GetGlyphShape(&font.info, glyph_index, &codepoint_vertices)
	defer stbtt.FreeShape(&font.info, codepoint_vertices)

	// push glyph properties from stbtt
	advance, lsb: i32
	stbtt.GetGlyphHMetrics(&font.info, glyph_index, &advance, &lsb)
	
	gc := &font.gc
	assert(gc.curves != nil)
	scaling := font.scaling * size

	for i := i32(0); i < number_of_vertices; i += 1 {
		v := codepoint_vertices[i]

		switch v.type {
		case u8(stbtt.vmove.vmove): 
			x := offset_x + f32(v.x) * scaling
			y := offset_y + f32(-v.y) * scaling + font.ascender * scaling
			renderer_move_to(renderer, x, y)
		
		case u8(stbtt.vmove.vline):
			x := offset_x + f32(v.x) * scaling
			y := offset_y + f32(-v.y) * scaling + font.ascender * scaling
			renderer_line_to(renderer, x, y)

		case u8(stbtt.vmove.vcurve):
			x := offset_x + f32(v.x) * scaling
			y := offset_y + f32(-v.y) * scaling + font.ascender * scaling
			cx := offset_x + f32(v.cx) * scaling
			cy := offset_y + f32(-v.cy) * scaling + font.ascender * scaling
			renderer_quadratic_to(renderer, cx, cy, x, y)

		case u8(stbtt.vmove.vcubic):
			unimplemented("cubic")

		// 	x := f32(v.x) * font.scaling
		// 	y := f32(-v.y) * font.scaling + font.ascender * font.scaling
		// 	cx := f32(v.cx) * font.scaling
		// 	cy := f32(-v.cy) * font.scaling + font.ascender * font.scaling
		// 	renderer_quadratic_to(renderer, cx, cy, x, y)
		}
	}

	// NOTE: NO CLOSING
	return f32(advance) * scaling
}
