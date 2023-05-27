package vg

import "core:mem"
import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:unicode"

// works ONLY without closed since THREE moves
svg_shield_path := "M12,1L3,5V11C3,16.55 6.84,21.74 12,23C17.16,21.74 21,16.55 21,11V5L12,1M12,5A3,3 0 0,1 15,8A3,3 0 0,1 12,11A3,3 0 0,1 9,8A3,3 0 0,1 12,5M17.13,17C15.92,18.85 14.11,20.24 12,20.92C9.89,20.24 8.08,18.85 6.87,17C6.53,16.5 6.24,16 6,15.47C6,13.82 8.71,12.47 12,12.47C15.29,12.47 18,13.79 18,15.47C17.76,16 17.47,16.5 17.13,17Z"

// works ONLY without closed since TWO moves
svg_F := "M9,7V17H11V13H14V11H11V9H15V7H9M5,3H19A2,2 0 0,1 21,5V19A2,2 0 0,1 19,21H5A2,2 0 0,1 3,19V5A2,2 0 0,1 5,3Z"

// too many / too little operation space
svg_aws := "M7.64,10.38C7.64,10.63 7.66,10.83 7.71,11C7.76,11.12 7.83,11.28 7.92,11.46C7.96,11.5 7.97,11.56 7.97,11.61C7.97,11.68 7.93,11.74 7.84,11.81L7.42,12.09C7.36,12.13 7.3,12.15 7.25,12.15C7.18,12.15 7.12,12.11 7.05,12.05C6.96,11.95 6.88,11.85 6.81,11.74C6.75,11.63 6.68,11.5 6.61,11.35C6.09,11.96 5.44,12.27 4.65,12.27C4.09,12.27 3.65,12.11 3.32,11.79C3,11.47 2.83,11.04 2.83,10.5C2.83,9.95 3.03,9.5 3.43,9.14C3.84,8.8 4.38,8.62 5.06,8.62C5.29,8.62 5.5,8.64 5.77,8.68C6,8.71 6.27,8.76 6.53,8.82V8.34C6.53,7.83 6.43,7.5 6.22,7.27C6,7.06 5.65,6.97 5.14,6.97C4.9,6.97 4.66,7 4.42,7.05C4.17,7.11 3.93,7.18 3.7,7.28C3.59,7.32 3.5,7.35 3.47,7.36C3.42,7.38 3.39,7.38 3.36,7.38C3.27,7.38 3.22,7.32 3.22,7.18V6.85C3.22,6.75 3.23,6.67 3.27,6.62C3.3,6.57 3.36,6.53 3.45,6.5C3.69,6.36 3.96,6.26 4.29,6.18C4.62,6.09 4.96,6.05 5.33,6.05C6.12,6.05 6.7,6.23 7.07,6.59C7.44,6.95 7.62,7.5 7.62,8.23V10.38H7.64M4.94,11.4C5.16,11.4 5.38,11.36 5.62,11.28C5.86,11.2 6.07,11.05 6.25,10.85C6.36,10.72 6.44,10.58 6.5,10.42C6.5,10.26 6.55,10.07 6.55,9.84V9.57C6.35,9.5 6.15,9.5 5.93,9.45C5.72,9.43 5.5,9.41 5.31,9.41C4.86,9.41 4.54,9.5 4.32,9.68C4.1,9.86 4,10.11 4,10.44C4,10.76 4.07,11 4.24,11.15C4.4,11.32 4.63,11.4 4.94,11.4M10.28,12.11C10.16,12.11 10.08,12.09 10,12.05C9.97,12 9.92,11.91 9.88,11.79L8.32,6.65C8.28,6.5 8.26,6.43 8.26,6.38C8.26,6.27 8.31,6.21 8.42,6.21H9.07C9.2,6.21 9.29,6.23 9.33,6.28C9.39,6.32 9.43,6.41 9.47,6.54L10.58,10.94L11.62,6.54C11.65,6.41 11.69,6.32 11.75,6.28C11.8,6.24 11.89,6.21 12,6.21H12.55C12.67,6.21 12.76,6.23 12.81,6.28C12.86,6.32 12.91,6.41 12.94,6.54L14,11L15.14,6.54C15.18,6.41 15.23,6.32 15.27,6.28C15.33,6.24 15.41,6.21 15.53,6.21H16.15C16.26,6.21 16.32,6.27 16.32,6.38C16.32,6.41 16.31,6.45 16.3,6.5C16.3,6.5 16.28,6.58 16.26,6.65L14.65,11.79C14.61,11.93 14.57,12 14.5,12.05C14.46,12.09 14.37,12.12 14.26,12.12H13.69C13.56,12.12 13.5,12.1 13.42,12.05C13.37,12 13.32,11.92 13.3,11.79L12.27,7.5L11.24,11.78C11.21,11.91 11.17,12 11.12,12.05C11.06,12.09 10.97,12.11 10.85,12.11H10.28M18.83,12.29C18.5,12.29 18.13,12.25 17.8,12.17C17.47,12.09 17.21,12 17.04,11.91C16.93,11.85 16.86,11.78 16.83,11.72C16.8,11.66 16.79,11.6 16.79,11.54V11.2C16.79,11.06 16.84,11 16.94,11C17,11 17,11 17.06,11C17.1,11 17.16,11.05 17.23,11.08C17.45,11.18 17.7,11.26 17.96,11.31C18.23,11.36 18.5,11.39 18.75,11.39C19.17,11.39 19.5,11.32 19.72,11.17C19.95,11 20.07,10.81 20.07,10.54C20.07,10.35 20,10.2 19.89,10.07C19.77,9.95 19.54,9.83 19.22,9.73L18.25,9.43C17.77,9.27 17.41,9.05 17.19,8.75C16.97,8.46 16.86,8.13 16.86,7.78C16.86,7.5 16.92,7.26 17.04,7.05C17.16,6.83 17.32,6.65 17.5,6.5C17.72,6.35 17.94,6.24 18.21,6.16C18.47,6.08 18.75,6.04 19.05,6.04C19.19,6.04 19.34,6.05 19.5,6.07C19.64,6.09 19.78,6.12 19.92,6.14C20.06,6.18 20.18,6.21 20.3,6.25C20.42,6.29 20.5,6.33 20.58,6.37C20.67,6.42 20.74,6.47 20.78,6.53C20.82,6.59 20.84,6.66 20.84,6.75V7.07C20.84,7.21 20.79,7.28 20.69,7.28C20.64,7.28 20.55,7.25 20.43,7.2C20.06,7.03 19.63,6.94 19.16,6.94C18.78,6.94 18.5,7 18.27,7.13C18.07,7.25 17.96,7.45 17.96,7.72C17.96,7.91 18.03,8.07 18.16,8.19C18.29,8.32 18.54,8.44 18.89,8.56L19.84,8.86C20.32,9 20.66,9.22 20.87,9.5C21.07,9.77 21.17,10.08 21.17,10.43C21.17,10.71 21.11,10.97 21,11.2C20.88,11.42 20.72,11.62 20.5,11.78C20.31,11.95 20.06,12.07 19.78,12.16C19.5,12.25 19.16,12.29 18.83,12.29M20.08,15.53C17.89,17.14 14.71,18 12,18C8.15,18 4.7,16.58 2.09,14.23C1.88,14.04 2.07,13.79 2.32,13.94C5.14,15.57 8.61,16.56 12.21,16.56C14.64,16.56 17.31,16.06 19.76,15C20.13,14.85 20.44,15.26 20.08,15.53M21,14.5C20.71,14.13 19.14,14.32 18.43,14.4C18.22,14.43 18.19,14.24 18.38,14.1C19.63,13.23 21.69,13.5 21.92,13.77C22.16,14.07 21.86,16.13 20.69,17.11C20.5,17.26 20.33,17.18 20.41,17C20.68,16.32 21.27,14.84 21,14.5Z"

// easy - WORKS WITHOUT CLOSE
svg_angular := "M12,2.5L20.84,5.65L19.5,17.35L12,21.5L4.5,17.35L3.16,5.65L12,2.5M12,4.6L6.47,17H8.53L9.64,14.22H14.34L15.45,17H17.5L12,4.6M13.62,12.5H10.39L12,8.63L13.62,12.5Z"

// has winding issues
svg_debian := "M18.5,10.57L18.3,10.94C18.56,10.16 18.41,9.31 18.45,8.57L18.38,8.55C18.31,6.7 16.71,4.73 15.29,4.07C14.06,3.5 12.17,3.4 11.3,3.83C11.42,3.72 11.9,3.68 11.75,3.6C10.38,3.73 10.69,4.07 9.64,4.34C9.35,4.62 10.5,4.12 9.87,4.5C9.31,4.63 9.05,4.38 8.22,5.24C8.29,5.36 8.75,4.89 8.37,5.36C7.58,5.27 5.89,7.16 5.53,7.78L5.72,7.82C5.41,8.59 5,9.08 4.95,9.54C4.87,10.68 4.5,12.75 5.03,13.39L4.97,13.92L5.2,14.37L5.08,14.38C5.66,16.21 5.7,14.42 6.47,16.32C6.36,16.28 6.24,16.24 6.08,16C6.06,16.19 6.32,16.69 6.62,17.08L6.5,17.22C6.66,17.53 6.82,17.6 6.93,17.71C6.3,17.36 7.5,18.84 7.63,19.03L7.73,18.86C7.71,19.1 7.9,19.42 8.26,19.87L8.56,19.86C8.69,20.1 9.14,20.54 9.41,20.56L9.23,20.8C9.92,21 9.56,21.09 10.41,21.39L10.24,21.09C10.67,21.46 10.8,21.79 11.41,22.07C12.26,22.37 12.37,22.25 13.23,22.5C12.5,22.5 11.64,22.5 11.06,22.28C7.1,21.21 3.5,16.56 3.74,11.78C3.68,10.81 3.84,9.6 3.68,9.36C3.9,8.62 4.16,7.72 4.69,6.65C4.65,6.58 4.78,6.86 5.05,6.41C5.21,6.05 5.34,5.66 5.55,5.31L5.65,5.28C5.76,4.67 7.08,3.73 7.5,3.26V3.44C8.36,2.63 9.9,2.09 10.76,1.71C10.53,1.96 11.27,1.68 11.8,1.65L11.31,1.93C11.94,1.77 11.91,2 12.56,1.9C12.33,1.93 12.06,2 12.1,2.06C12.82,2.14 12.94,1.84 13.61,2.06L13.56,1.86C14.5,2.2 14.69,2.14 15.7,2.68C16.06,2.69 16.1,2.46 16.63,2.68C16.73,2.84 16.61,2.87 17.27,3.27C17.34,3.24 17.14,3.05 17,2.9C18.3,3.61 19.75,5.12 20.18,6.74C19.77,6 20.14,7.13 20,7.07C20.18,7.56 20.33,8.07 20.43,8.6C20.31,8.17 20.04,7.12 19.57,6.45C19.54,6.88 18.97,6.15 19.28,7.11C19.5,7.45 19.33,6.76 19.62,7.36C19.62,7.65 19.73,7.94 19.8,8.31C19.7,8.29 19.58,7.9 19.5,8C19.6,8.5 19.77,8.72 19.83,8.76C19.8,8.84 19.71,8.68 19.71,9C19.75,9.74 19.92,9.43 20,9.46C19.91,9.83 19.59,10.25 19.75,10.88L19.55,10.32C19.5,10.85 19.66,10.95 19.42,11.6C19.6,11 19.58,10.5 19.41,10.75C19.5,11.57 18.76,12.2 18.83,12.73L18.62,12.44C18.05,13.27 18.61,12.89 18.22,13.5C18.36,13.27 18.15,13.42 18.33,13.14C18.21,13.15 17.78,13.67 17.39,13.97C15.85,15.2 14,15.37 12.24,14.7H12.23C12.24,14.66 12.23,14.61 12.11,14.53C10.6,13.38 9.71,12.4 10,10.12C10.25,9.95 10.31,9 10.84,8.67C11.16,7.96 12.12,7.31 13.15,7.29C14.2,7.23 15.09,7.85 15.54,8.43C14.72,7.68 13.4,7.45 12.26,8C11.11,8.53 10.42,9.8 10.5,11.07C10.56,11 10.6,11.05 10.62,10.89C10.59,13.36 13.28,15.17 15.22,14.26L15.25,14.31C16.03,14.09 15.93,13.92 16.44,13.56C16.4,13.65 16.1,13.86 16.28,13.86C16.53,13.8 17.31,13.07 17.7,12.73C17.87,12.35 17.6,12.5 17.85,12.04L18.15,11.89C18.32,11.41 18.5,11.14 18.5,10.57"

svg_firefox := "M9.27 7.94C9.27 7.94 9.27 7.94 9.27 7.94M6.85 6.74C6.86 6.74 6.86 6.74 6.85 6.74M21.28 8.6C20.85 7.55 19.96 6.42 19.27 6.06C19.83 7.17 20.16 8.28 20.29 9.1L20.29 9.12C19.16 6.3 17.24 5.16 15.67 2.68C15.59 2.56 15.5 2.43 15.43 2.3C15.39 2.23 15.36 2.16 15.32 2.09C15.26 1.96 15.2 1.83 15.17 1.69C15.17 1.68 15.16 1.67 15.15 1.67H15.13L15.12 1.67L15.12 1.67L15.12 1.67C12.9 2.97 11.97 5.26 11.74 6.71C11.05 6.75 10.37 6.92 9.75 7.22C9.63 7.27 9.58 7.41 9.62 7.53C9.67 7.67 9.83 7.74 9.96 7.68C10.5 7.42 11.1 7.27 11.7 7.23L11.75 7.23C11.83 7.22 11.92 7.22 12 7.22C12.5 7.21 12.97 7.28 13.44 7.42L13.5 7.44C13.6 7.46 13.67 7.5 13.75 7.5C13.8 7.54 13.86 7.56 13.91 7.58L14.05 7.64C14.12 7.67 14.19 7.7 14.25 7.73C14.28 7.75 14.31 7.76 14.34 7.78C14.41 7.82 14.5 7.85 14.54 7.89C14.58 7.91 14.62 7.94 14.66 7.96C15.39 8.41 16 9.03 16.41 9.77C15.88 9.4 14.92 9.03 14 9.19C17.6 11 16.63 17.19 11.64 16.95C11.2 16.94 10.76 16.85 10.34 16.7C10.24 16.67 10.14 16.63 10.05 16.58C10 16.56 9.93 16.53 9.88 16.5C8.65 15.87 7.64 14.68 7.5 13.23C7.5 13.23 8 11.5 10.83 11.5C11.14 11.5 12 10.64 12.03 10.4C12.03 10.31 10.29 9.62 9.61 8.95C9.24 8.59 9.07 8.42 8.92 8.29C8.84 8.22 8.75 8.16 8.66 8.1C8.43 7.3 8.42 6.45 8.63 5.65C7.6 6.12 6.8 6.86 6.22 7.5H6.22C5.82 7 5.85 5.35 5.87 5C5.86 5 5.57 5.16 5.54 5.18C5.19 5.43 4.86 5.71 4.56 6C4.21 6.37 3.9 6.74 3.62 7.14C3 8.05 2.5 9.09 2.28 10.18C2.28 10.19 2.18 10.59 2.11 11.1L2.08 11.33C2.06 11.5 2.04 11.65 2 11.91L2 11.94L2 12.27L2 12.32C2 17.85 6.5 22.33 12 22.33C16.97 22.33 21.08 18.74 21.88 14C21.9 13.89 21.91 13.76 21.93 13.63C22.13 11.91 21.91 10.11 21.28 8.6Z"

// needs to be separated
svg_AB := "M4 2A2 2 0 0 0 2 4V12H4V8H6V12H8V4A2 2 0 0 0 6 2H4M4 4H6V6H4M22 15.5V14A2 2 0 0 0 20 12H16V22H20A2 2 0 0 0 22 20V18.5A1.54 1.54 0 0 0 20.5 17A1.54 1.54 0 0 0 22 15.5M20 20H18V18H20V20M20 16H18V14H20M5.79 21.61L4.21 20.39L18.21 2.39L19.79 3.61Z"

svg_cowboy := "M20 22H4V20C4 17.8 7.6 16 12 16S20 17.8 20 20M8 9H16V10C16 12.2 14.2 14 12 14S8 12.2 8 10M19 4C18.4 4 18 4.4 18 5V6H16.5L15.1 3C15 2.8 14.9 2.6 14.7 2.5C14.2 2 13.4 1.9 12.7 2.2L12 2.4L11.3 2.1C10.6 1.8 9.8 1.9 9.3 2.4C9.1 2.6 9 2.8 8.9 3L7.5 6H6V5C6 4.4 5.6 4 5 4S4 4.4 4 5V6C4 7.1 4.9 8 6 8H18C19.1 8 20 7.1 20 6V5C20 4.5 19.6 4 19 4Z"

SVG_Path_Command :: struct {
	type: byte,
	points: [8]f32,
}

// get a float value and its last non matching number character
value_till :: proc(input: string) -> (res: string, last: u8) {
	for i := 0; i < len(input); i += 1 {
		b := input[i]

		if !(b == '.' || unicode.is_number(rune(b))) {
			res = input[:i]
			last = b
			return
		}
	}

	return
}

svg_gen :: proc(commands: []SVG_Path_Command, svg: string) -> []SVG_Path_Command {
	points: [10]f32
	svg_index: int
	command_index: int

	for svg_index < len(svg) {
		command := &commands[command_index]
		command.type = svg[svg_index]
		command_index += 1
		svg_index += 1
		point_index: int
	
		// gather points from textual representation		
		for svg_index < len(svg) {
			res, last := value_till(svg[svg_index:])

			if len(res) == 0 {
				break
			}

			svg_index += len(res)
			points[point_index] = f32(strconv.atof(res))
			point_index += 1

			// allow space or comma
			if last == ' ' || last == ',' {
				svg_index	+= 1
			} else {
				break
			}
		}

		mem.copy(&command.points[0], &points[0], size_of(points))
	}

	return commands[:command_index]
}

svg_gen_temp :: proc(svg: string, allocator := context.allocator) -> []SVG_Path_Command {
	commands: [1028]SVG_Path_Command
	fin := svg_gen(commands[:], svg)
	return slice.clone(fin, allocator)
}

// renderer_svg :: proc(using renderer: ^Renderer, svg: []SVG_Path_Command) {
// 	for cmd in svg {
// 		p := cmd.points

// 		switch cmd.type {
// 		case 'M': 
// 			renderer_move_to(renderer, p[0], p[1])

// 		case 'm': renderer_move_to_rel(renderer, p[0], p[1])

// 		case 'L': renderer_line_to(renderer, p[0], p[1])
// 		case 'l': renderer_line_to_rel(renderer, p[0], p[1])

// 		case 'V': renderer_vertical_line_to(renderer, p[0])
// 		case 'H': renderer_horizontal_line_to(renderer, p[0])

// 		case 'A': 
// 			// 0  1  2               3              4          5 6
// 			// rx ry x-axis-rotation large-arc-flag sweep-flag x y
// 			renderer_arc_to(renderer, p[0], p[1], p[2], p[3], p[4], p[5], p[6])

// 		case 'a': unimplemented("A relative")

// 		case 'Q': renderer_quadratic_to(renderer, p[0], p[1], p[2], p[3])
// 		case 'q': unimplemented("q relativee")

// 		case 'C': renderer_cubic_to(renderer, p[0], p[1], p[2], p[3], p[4], p[5])
// 		case 'c': unimplemented("c RELATIVE")

// 		case 'S': renderer_cubic_bezier_short_to(renderer, p[0], p[1], p[2], p[3])
// 		case 's': unimplemented("SHORT relative")

// 		case 'T': unimplemented("QUAD T")
// 		case 't': unimplemented("QUAD t")

// 		case 'Z', 'z':
// 			// fmt.eprintln("CLOSE")
// 			// renderer_close(renderer)
// 		}
// 	}
// }

// renderer_cubic_bezier_short_to :: proc(
// 	using renderer: ^Renderer,
// 	c2x, c2y: f32,
// 	x, y: f32,
// ) {
// 	c1x := 2 * curve_last.x - curve_last_control.x
// 	c1y := 2 * curve_last.y - curve_last_control.y
// 	renderer_cubic_to(renderer, c1x, c1y, c2x, c2y, x, y)
// 	curve_last = { x, y }
// 	curve_last_control = { c2x, c2y }
// }