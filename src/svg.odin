package src

import "core:mem"
import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:unicode"

// svg_shield_path := "M12,1L3,5V11C3,16.55 6.84,21.74 12,23C17.16,21.74 21,16.55 21,11V5L12,1M12,5A3,3 0 0,1 15,8A3,3 0 0,1 12,11A3,3 0 0,1 9,8A3,3 0 0,1 12,5M17.13,17C15.92,18.85 14.11,20.24 12,20.92C9.89,20.24 8.08,18.85 6.87,17C6.53,16.5 6.24,16 6,15.47C6,13.82 8.71,12.47 12,12.47C15.29,12.47 18,13.79 18,15.47C17.76,16 17.47,16.5 17.13,17Z"
svg_shield_path := "M12,1L3,5V11C3,16.55 6.84,21.74 12,23C17.16,21.74 21,16.55 21,11V5L12,1Z"

SVG_Path_Command_Type :: enum {
	Move_To_Absolute,
	Move_To_Relative,
	Line_To_Absolute,
	Line_To_Relative,
	Horizontal_Line_To_Absolute,
	Horizontal_Line_To_Relative,
	Vertical_Line_To_Absolute,
	Vertical_Line_To_Relative,
	Curve_To_Absolute,
	Curve_To_Relative,
	Close_Path,
}

SVG_Path_Command :: struct {
	type: SVG_Path_Command_Type,
	points: [8e]f32,
}

path_command_table := [256]SVG_Path_Command_Type {
	'm' = .Move_To_Relative,
	'M' = .Move_To_Absolute,

	'l' = .Line_To_Relative,
	'L' = .Line_To_Absolute,

	'h' = .Horizontal_Line_To_Relative,
	'H' = .Horizontal_Line_To_Absolute,

	'v' = .Vertical_Line_To_Relative,
	'V' = .Vertical_Line_To_Absolute,

	'c' = .Curve_To_Relative,
	'C' = .Curve_To_Absolute,

	'z' = .Close_Path,
	'Z' = .Close_Path,
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

// path_svg :: proc(path: ^Path, svg: string) {
// 	points: [10]f32
// 	svg_index: int

// 	for svg_index < len(svg) {
// 		command := path_command_table[svg[svg_index]]
// 		svg_index += 1
// 		point_index: int
		
// 		for svg_index < len(svg) {
// 			res, last := value_till(svg[svg_index:])

// 			if len(res) == 0 {
// 				break
// 			}

// 			svg_index += len(res)
// 			points[point_index] = f32(strconv.atof(res))
// 			point_index += 1

// 			// allow space or comma
// 			if last == ' ' || last == ',' {
// 				svg_index	+= 1
// 			} else {
// 				break
// 			}
// 		}

// 		#partial switch command {
// 		case .Move_To_Absolute: path_move_to(path, points[0], points[1])
// 		case .Move_To_Relative: path_move_to_rel(path, points[0], points[1])

// 		case .Line_To_Absolute: path_line_to(path, points[0], points[1])
// 		case .Line_To_Relative: path_line_to_rel(path, points[0], points[1])

// 		case .Vertical_Line_To_Absolute: path_line_to(path, path.last.x, points[0])
// 		case .Vertical_Line_To_Relative: path_line_to_rel(path, 0, points[0])

// 		case .Horizontal_Line_To_Absolute: path_line_to(path, points[0], path.last.y)
// 		case .Horizontal_Line_To_Relative: path_line_to_rel(path, points[0], 0)

// 		// TODO check where the control points should be
// 		case .Curve_To_Absolute: 
// 			fmt.eprintln("C", points[:point_index])
// 			path_cubic_to(path, points[4], points[5], points[0], points[1], points[2], points[3])
// 		// case .Curve_To_Absolute: path_line_to(path, points[4], points[5])
// 		case .Curve_To_Relative: path_cubic_to_rel(path, points[4], points[5], points[0], points[1], points[2], points[3])

// 		case .Close_Path: path_close(path)
// 		}

// 		// fmt.eprintln("CMD", command, points[:point_index])
// 	}
// }

// path_svg_make :: proc(svg: string, allocator := context.allocator) -> (res: []Curve) {
// 	curves: [512]Curve
// 	path := path_make(curves[:])
// 	path_svg(&path, svg)
// 	res = slice.clone(curves[:path.offset], allocator)
// 	return
// }

svg_gen :: proc(commands: []SVG_Path_Command, svg: string) -> []SVG_Path_Command {
	points: [10]f32
	svg_index: int
	command_index: int

	for svg_index < len(svg) {
		command := &commands[command_index]
		command.type = path_command_table[svg[svg_index]]
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
	commands: [512]SVG_Path_Command
	fin := svg_gen(commands[:], svg)
	return slice.clone(fin, allocator)
}

renderer_svg :: proc(using renderer: ^Renderer, svg: []SVG_Path_Command) {
	state := renderer_state_get(renderer)

	for cmd in svg {
		#partial switch cmd.type {
		case .Move_To_Absolute: renderer_move_to(renderer, cmd.points[0], cmd.points[1])
		case .Move_To_Relative: renderer_move_to_rel(renderer, cmd.points[0], cmd.points[1])

		case .Line_To_Absolute: renderer_line_to(renderer, cmd.points[0], cmd.points[1])
		case .Line_To_Relative: renderer_line_to_rel(renderer, cmd.points[0], cmd.points[1])

		case .Vertical_Line_To_Absolute: renderer_vertical_line_to(renderer, cmd.points[0])
		case .Horizontal_Line_To_Absolute: renderer_horizontal_line_to(renderer, cmd.points[0])

		// TODO check where the control points should be
		case .Curve_To_Absolute: 
			p := cmd.points
			renderer_cubic_to(renderer, p[4], p[5], p[0], p[1], p[2], p[3])
			// renderer_line_to(renderer, p[4], p[5])
			
			// renderer_cubic_to(renderer, p[0], p[1], p[2], p[3], p[4], p[5])

		// 	fmt.eprintln("C", points[:point_index])
		// 	path_cubic_to(path, points[4], points[5], points[0], points[1], points[2], points[3])

		case .Close_Path: renderer_close(renderer)
		}
	}
}