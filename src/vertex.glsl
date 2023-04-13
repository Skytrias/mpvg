#version 430 core

layout (location = 0) in vec2 i_pos;
layout (location = 1) in vec2 i_uv;
out vec2 v_uv;
uniform mat4 projection;

void main() {
	v_uv = i_uv;
	gl_Position = projection * vec4(i_pos, 0.0, 1.0);
}
