package vg

import "core:os"
import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import stbtt "vendor:stb/truetype"

GLYPH_LUT_SIZE :: 512
GLYPH_COUNT :: 1028

// font state storing scaling information
// simple map to retrieve already created glyphs, could do a LUT
Font :: struct {
	name: string,

	info: stbtt.fontinfo,
	info_data: []byte,
	free_loaded_data: bool,

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
	index: i32,
	next: int,

	// box unscaled
	x0, y0, x1, y1: f32,
}

// init a font from a path
font_init :: proc(font: ^Font, name: string, data: []byte, free_loaded_data: bool) {
	font.name = strings.clone(name)

	font.free_loaded_data = free_loaded_data
	font.info_data = data
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
	delete(font.glyphs)
	delete(font.name)

	for i in 0..<font.glyph_index {
		delete(font.glyphs[i].vertices)
	}

	if font.free_loaded_data {
		delete(font.info_data)
	}
}

font_glyph_get :: proc(font: ^Font, codepoint: rune, loc := #caller_location) -> ^Glyph {
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
	glyph.index = glyph_index
	glyph.advance = f32(advance)
	glyph.next = font.lut[hash_value]

	x0, y0, x1, y1: i32
	stbtt.GetGlyphBox(&font.info, glyph_index, &x0, &y0, &x1, &y1)
	glyph.x0 = f32(x0)
	glyph.x1 = f32(x1)
	glyph.y0 = f32(y0)
	glyph.y1 = f32(y1)

	font.lut[hash_value] = font.glyph_index
	font.glyph_index += 1
	return glyph
}

// retrieve cached or generate the wanted glyph vertices and its bounding box
font_glyph_render :: proc(
	ctx: ^Context, 
	font: ^Font, 
	glyph: ^Glyph,
	offset_x, offset_y: f32,
	size: f32,
) -> f32 {
	scaling := font.scaling * size
	path_add(ctx)

	for i := 0; i < len(glyph.vertices); i += 1 {
		v := glyph.vertices[i]

		switch v.type {
		case u8(stbtt.vmove.vmove): 
			x := offset_x + f32(v.x) * scaling
			y := offset_y + f32(-v.y) * scaling
			ctx.point_last = { x, y }
		
		case u8(stbtt.vmove.vline):
			x := offset_x + f32(v.x) * scaling
			y := offset_y + f32(-v.y) * scaling
			line_to(ctx, x, y)

		case u8(stbtt.vmove.vcurve):
			x := offset_x + f32(v.x) * scaling
			y := offset_y + f32(-v.y) * scaling
			cx := offset_x + f32(v.cx) * scaling
			cy := offset_y + f32(-v.cy) * scaling
			quadratic_to(ctx, cx, cy, x, y)

		case u8(stbtt.vmove.vcubic):
			unimplemented("cubic")
		}
	}

	// NOTE: NO CLOSING
	return glyph.advance * scaling
}

font_glyph_kern_advance :: proc(font: ^Font, glyph1, glyph2: i32) -> f32 {
	return f32(stbtt.GetGlyphKernAdvance(&font.info, glyph1, glyph2))
}

font_glyph_step :: proc(
	font: ^Font, 
	previous_glyph_index: i32,
	glyph: ^Glyph,

	scaling: f32,
	spacing: f32,

	x: ^f32,
	y: ^f32,
) {
	// TODO kerning
	if previous_glyph_index != -1 {
		adv := f32(font_glyph_kern_advance(font, previous_glyph_index, glyph.index)) * scaling
		x^ += adv + spacing + 0.5
	}

	x^ += f32(glyph.advance) * scaling
}

font_text_bounds :: proc(
	font: ^Font, 
	input: string, 

	// offset
	x: f32,
	y: f32,
	
	// options
	size: f32,
	letter_spacing: f32,
	ah: Align_Horizontal,
) -> f32 {
	scaling := font.scaling * size

	x := x
	start_x := x
	minx := x
	maxx := x
	miny := y 
	maxy := y

	utf8state: rune
	codepoint: rune
	previous_glyph_index := i32(-1)
	for byte_offset in 0..<len(input) {
		if __decutf8(&utf8state, &codepoint, input[byte_offset]) {
			glyph := font_glyph_get(font, codepoint)

			if glyph != nil {
				font_glyph_step(font, previous_glyph_index, glyph, scaling, letter_spacing, &x, nil)

				if glyph.x0 < minx {
					minx = glyph.x0
				}

				if glyph.x1 > maxx {
					maxx = glyph.x1
				}

				if glyph.y0 < miny {
					miny = glyph.y0
				}

				if glyph.y1 > maxy {
					maxy = glyph.y1
				}
			}

			previous_glyph_index = glyph == nil ? -1 : glyph.index
		}
	}

	advance := x - start_x
	switch ah {
		case .Left: {}
		case .Center: {
			minx -= advance * 0.5
			maxx -= advance * 0.5
		}
		case .Right: {
			minx -= advance
			maxx -= advance
		}
	}

	return advance
}

// get alignment based on font
@private
font_vertical_align :: proc(
	font: ^Font,
	av: Align_Vertical,
	scaling: f32,
) -> (res: f32) {
	switch av {
		case .Top: res = font.ascender * scaling
		case .Middle: res = (font.ascender + font.descender) / 2 * scaling
		case .Baseline:
		case .Bottom: res = font.descender * scaling
	}

	return
}

///////////////////////////////////////////////////////////
// UTF8 fast iteration
///////////////////////////////////////////////////////////

@(private)
UTF8_ACCEPT :: 0

@(private)
UTF8_REJECT :: 1

@(private)
utf8d := [400]u8 {
	0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, // 00..1f
	0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, // 20..3f
	0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, // 40..5f
	0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, // 60..7f
	1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9, // 80..9f
	7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7, // a0..bf
	8,8,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2, // c0..df
	0xa,0x3,0x3,0x3,0x3,0x3,0x3,0x3,0x3,0x3,0x3,0x3,0x3,0x4,0x3,0x3, // e0..ef
	0xb,0x6,0x6,0x6,0x5,0x8,0x8,0x8,0x8,0x8,0x8,0x8,0x8,0x8,0x8,0x8, // f0..ff
	0x0,0x1,0x2,0x3,0x5,0x8,0x7,0x1,0x1,0x1,0x4,0x6,0x1,0x1,0x1,0x1, // s0..s0
	1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,0,1,1,1,1,1,0,1,0,1,1,1,1,1,1, // s1..s2
	1,2,1,1,1,1,1,2,1,2,1,1,1,1,1,1,1,1,1,1,1,1,1,2,1,1,1,1,1,1,1,1, // s3..s4
	1,2,1,1,1,1,1,1,1,2,1,1,1,1,1,1,1,1,1,1,1,1,1,3,1,3,1,1,1,1,1,1, // s5..s6
	1,3,1,1,1,1,1,3,1,3,1,1,1,1,1,1,1,3,1,1,1,1,1,1,1,1,1,1,1,1,1,1, // s7..s8
}

// decode codepoints from a state
@(private)
__decutf8 :: #force_inline proc(state: ^rune, codep: ^rune, b: byte) -> bool {
	b := rune(b)
	type := utf8d[b]
	codep^ = (state^ != UTF8_ACCEPT) ? ((b & 0x3f) | (codep^ << 6)) : ((0xff >> type) & (b))
	state^ = rune(utf8d[256 + state^ * 16 + rune(type)])
	return state^ == UTF8_ACCEPT
}

///////////////////////////////////////////////////////////
// Text Iteration
///////////////////////////////////////////////////////////

// text iteration with custom settings
Text_Iter :: struct {
	x, y, nextx, nexty, spacing: f32,
	scaling: f32,

	font: ^Font,
	previous_glyph_index: i32,

	// unicode iteration
	utf8state: rune, // utf8
	codepoint: rune,
	query: string,
	codepoint_count: int,

	// byte indices
	str: int,
	next: int,
	end: int,
}

// init text iter struct with settings
text_iter_init :: proc(
	font: ^Font,
	query: string,
	
	x: f32,
	y: f32,

	size: f32,
	spacing: f32,
	ah: Align_Horizontal,
	av: Align_Vertical,
) -> (res: Text_Iter) {
	res.scaling = size * font.scaling
	res.font = font

	// align horizontally
	x := x
	y := y
	switch ah {
	case .Left: 
	case .Center:
		width := font_text_bounds(font, query, x, y, size, spacing, ah)
		x = math.round(x - width * 0.5)
	case .Right:
		width := font_text_bounds(font, query, x, y, size, spacing, ah)
		x -= width
	}

	// align vertically
	y = y + font_vertical_align(font, av, size)

	// set positions
	res.x = x
	res.nextx = x
	res.y = y
	res.nexty = y
	res.previous_glyph_index = -1
	res.spacing = spacing
	res.query = query

	res.str = 0
	res.next = 0
	res.end = len(query)

	return
}

// step through each codepoint
text_iter_next :: proc(iter: ^Text_Iter) -> (glyph: ^Glyph, ok: bool) {
	str := iter.next
	iter.str = iter.next

	for str < iter.end {
		defer str += 1

		if __decutf8(&iter.utf8state, &iter.codepoint, iter.query[str]) {
			iter.x = iter.nextx
			iter.y = iter.nexty
			iter.codepoint_count += 1
			glyph = font_glyph_get(iter.font, iter.codepoint)
			
			if glyph != nil {
				font_glyph_step(iter.font, iter.previous_glyph_index, glyph, iter.scaling, iter.spacing, &iter.nextx, &iter.nexty)
			}
			iter.previous_glyph_index = glyph == nil ? -1 : glyph.index
			ok = true
			break
		}
	}

	iter.next = str
	return
}