// MIT License.
// Made by Dylearn
// 2D adaptation of clouds.gdshaderinc — no uniform declarations here;
// the including shader provides them as local uniforms.

vec2 rotate_vec2(vec2 vector, float angle) {
	float angle_deg = angle * (PI / 180.0);
	float rotated_x  = (vector.x * cos(angle_deg)) - (vector.y * sin(angle_deg));
	float rotated_y  = (vector.x * sin(angle_deg)) + (vector.y * cos(angle_deg));
	return vec2 (rotated_x, rotated_y);
}

// 2D adaptation — samples noise directly at world_pos (no 3D ray-plane intersection)
float get_cloud_noise_2d(vec2 world_pos) {
	float inv_scale = 1.0 / cloud_scale;

	//// Non-repeating clouds
	// Rotate wind noise direction left and right
	vec2 cloud_direction1 = rotate_vec2(cloud_direction, cloud_diverge_angle);
	vec2 cloud_direction2 = rotate_vec2(cloud_direction, -cloud_diverge_angle);
	// Scroll noises using time
	vec2 cloud_time_direction1 = TIME * cloud_speed * normalize(cloud_direction1);
	vec2 cloud_time_direction2 = TIME * cloud_speed * normalize(cloud_direction2);
	// Sample noise value (change speed and scale of 2nd one to avoid obvious repeating of texture)
	float cloud_sample1 = texture(cloud_noise, world_pos * inv_scale + cloud_time_direction1).r;
	float cloud_sample2 = texture(cloud_noise, world_pos * (inv_scale * 0.8) + (cloud_time_direction2 * 0.89 * PI / 3.0)).r;
	// Combine noise samples
	float cloud_sample = (cloud_sample1 * cloud_sample2);
	float light_value = clamp(cloud_sample + cloud_threshold, 0.0, 1.0);

	light_value = (light_value - 0.5) * cloud_contrast + 0.5;
	light_value = clamp(light_value + cloud_threshold, cloud_shadow_min, 1.0);
	return light_value;
}
