package src

import "core:mem"
import "core:runtime"

// Non aligned buffer
// pretty much a writer with finite size
// used for network packet creation, task operation buffer
// easy to use with temp arena regions
Blob :: struct {
	data_buffer: []byte,
	data_index: int,
}

blob_init :: proc(blob: ^Blob, cap: int, allocator := context.allocator) {
	blob.data_buffer = make([]byte, cap)
}

blob_make :: proc(cap: int, allocator := context.allocator) -> (res: Blob) {
	blob_init(&res, cap, allocator)
	return
}

blob_destroy :: proc(blob: Blob) {
	delete(blob.data_buffer)
}

blob_clear :: proc(blob: ^Blob) {
	blob.data_index = 0
}

blob_result :: proc(blob: Blob) -> []byte #no_bounds_check {
	return blob.data_buffer[:blob.data_index]
}

blob_write_byte :: proc(using blob: ^Blob, b: byte, loc := #caller_location) #no_bounds_check {
	runtime.bounds_check_error_loc(loc, data_index + 1, len(data_buffer))
	data_buffer[data_index] = b
	data_index += 1
}

blob_write_ptr :: proc(using blob: ^Blob, ptr: rawptr, size: int, loc := #caller_location) #no_bounds_check {
	runtime.bounds_check_error_loc(loc, data_index + size, len(data_buffer))
	mem.copy(&data_buffer[data_index], ptr, size)
	data_index += size
}

blob_write_slice :: proc(using blob: ^Blob, slice: []byte, loc := #caller_location) #no_bounds_check {
	runtime.bounds_check_error_loc(loc, data_index + len(slice), len(data_buffer))
	if len(slice) != 0 {
		copy(data_buffer[data_index:], slice)
		data_index += len(slice)
	}
}

blob_valid :: #force_inline proc(blob: ^Blob) -> bool {
	return blob.data_index > 0
}

////////////////////////////////////////////////////////////////////////////////
// READER with finite size
////////////////////////////////////////////////////////////////////////////////

// same as Blob but reverse
// simple way to read byte/ptr/slices 
Read :: struct {
	data_buffer: []byte,
	data_index: int,
}

read_make :: proc(data: []byte) -> (res: Read) {
	read_init(&res, data)
	return
}

read_init :: proc(read: ^Read, data: []byte) {
	read.data_buffer = data
	read.data_index = 0
}

read_is_reading :: proc(read: ^Read, index: int) -> bool {
	return read.data_index < index
}

read_byte :: proc(using read: ^Read, loc := #caller_location) -> (res: byte) #no_bounds_check {
	runtime.bounds_check_error_loc(loc, data_index + 1, len(data_buffer) + 1)
	res = data_buffer[data_index]
	data_index += 1
	return
}

read_ptr :: proc(using read: ^Read, data: rawptr, size: int, loc := #caller_location) #no_bounds_check {
	runtime.bounds_check_error_loc(loc, data_index + size, len(data_buffer) + 1)
	mem.copy(data, &data_buffer[data_index], size)
	data_index += size
}

read_slice :: proc(using read: ^Read, size: int, loc := #caller_location) -> (slice: []byte) #no_bounds_check {
	runtime.bounds_check_error_loc(loc, data_index + size, len(data_buffer) + 1)
	slice = data_buffer[data_index:data_index + size]
	data_index += size
	return
}

read_slice_copy :: proc(using read: ^Read, slice: []byte, loc := #caller_location) #no_bounds_check {
	runtime.bounds_check_error_loc(loc, data_index + len(slice), len(data_buffer) + 1)
	copy(slice, data_buffer[data_index:data_index + len(slice)])
	data_index += len(slice)
}

read_skip_byte :: proc(using read: ^Read, loc := #caller_location) {
	runtime.bounds_check_error_loc(loc, data_index + 1, len(data_buffer) + 1)
	data_index += 1
}

read_skip_size :: proc(using read: ^Read, size: int, loc := #caller_location) {
	runtime.bounds_check_error_loc(loc, data_index + size, len(data_buffer) + 1)
	data_index += size
}

read_rest :: proc(using read: ^Read) -> (slice: []byte) #no_bounds_check {
	slice = data_buffer[data_index:]
	data_index = len(data_buffer)
	return
}
