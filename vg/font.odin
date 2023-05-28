package vg

import "core:os"
import "core:fmt"
import "core:slice"
import stbtt "vendor:stb/truetype"

GLYPH_LUT_SIZE :: 256
GLYPH_COUNT :: 1028

// font state storing scaling information
// simple map to retrieve already created glyphs, could do a LUT
Font :: struct {
	info: stbtt.fontinfo,
	info_data: []byte,

	scaling: f32,
	ascender: f32,
	descender: f32,
	line_height: f32,

	glyphs: []Glyph,
	glyph_index: int,
	lut: [GLYPH_LUT_SIZE]int,
}

Glyph :: struct {
	vertices: []stbtt.vertex,
	advance: f32,
	codepoint: rune,
	next: int,
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

	// set lut
	for i in 0..<GLYPH_LUT_SIZE {
		font.lut[i] = -1
	}

	font.glyphs = make([]Glyph, GLYPH_COUNT)
	font.glyph_index = 0
}

font_destroy :: proc(font: Font) {
	delete(font.info_data)
	delete(font.glyphs)

	for i in 0..<font.glyph_index {
		delete(font.glyphs[i].vertices)
	}
}

font_glyph_get :: proc(font: ^Font, codepoint: rune) -> ^Glyph {
	hash_int :: proc(a: u32) -> u32 {
		a := a
		a += ~(a << 15)
		a ~=  (a >> 10)
		a +=  (a << 3)
		a ~=  (a >> 6)
		a +=  (a << 11)
		a ~=  (a >> 16)
		return a
	}

	// check for preexisting glyph 
	hash_value := hash_int(u32(codepoint)) & (GLYPH_LUT_SIZE - 1)
	i := font.lut[hash_value]
	for i != -1 {
		glyph := &font.glyphs[i]

		if glyph.codepoint == codepoint {
			return glyph
		}

		i = glyph.next
	}

	glyph_index := stbtt.FindGlyphIndex(&font.info, codepoint)
	if glyph_index == 0 {
		return nil
	}

	// retrieve vertice info
	codepoint_vertices: [^]stbtt.vertex
	number_of_vertices := stbtt.GetGlyphShape(&font.info, glyph_index, &codepoint_vertices)
	defer stbtt.FreeShape(&font.info, codepoint_vertices)

	// push glyph properties from stbtt
	advance, lsb: i32
	stbtt.GetGlyphHMetrics(&font.info, glyph_index, &advance, &lsb)	

	// push glyph
	glyph := &font.glyphs[font.glyph_index]
	assert(font.glyph_index < GLYPH_COUNT)
	glyph.vertices = slice.clone(codepoint_vertices[:number_of_vertices])
	glyph.codepoint = codepoint
	glyph.advance = f32(advance)
	glyph.next = font.lut[hash_value]

	font.lut[hash_value] = font.glyph_index
	font.glyph_index += 1
	return glyph
}

// retrieve cached or generate the wanted glyph vertices and its bounding box
push_font_glyph :: proc(
	ctx: ^Context, 
	font: ^Font, 
	codepoint: rune,
	offset_x, offset_y: f32,
	size: f32,
) -> f32 {
	glyph := font_glyph_get(font, codepoint)
	scaling := font.scaling * size
	// fmt.eprintln("GLYPH", codepoint)

	path_add(ctx)

	for i := 0; i < len(glyph.vertices); i += 1 {
		v := glyph.vertices[i]

		switch v.type {
		case u8(stbtt.vmove.vmove): 
			x := offset_x + f32(v.x) * scaling
			y := offset_y + f32(-v.y) * scaling + font.ascender * scaling
			// push_move_to(ctx, x, y)
			ctx.point_last = { x, y }
			// fmt.eprintln("MOVE", i)
		
		case u8(stbtt.vmove.vline):
			x := offset_x + f32(v.x) * scaling
			y := offset_y + f32(-v.y) * scaling + font.ascender * scaling
			push_line_to(ctx, x, y)

		case u8(stbtt.vmove.vcurve):
			x := offset_x + f32(v.x) * scaling
			y := offset_y + f32(-v.y) * scaling + font.ascender * scaling
			cx := offset_x + f32(v.cx) * scaling
			cy := offset_y + f32(-v.cy) * scaling + font.ascender * scaling
			push_quadratic_to(ctx, cx, cy, x, y)

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
	return glyph.advance * scaling
}
