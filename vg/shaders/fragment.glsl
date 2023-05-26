#version 430 core

in vec2 v_uv;
uniform sampler2D texture_main;
out vec4 fragment_color;

void main() {
	vec4 color_texture = texture(texture_main, v_uv);
	fragment_color = color_texture;
}
