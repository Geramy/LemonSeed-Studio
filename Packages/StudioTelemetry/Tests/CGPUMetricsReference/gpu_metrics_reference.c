// Fills upstream struct gpu_metrics_v1_3 as amdgpu_mtopg's
// check_linux_model.sh does, for the decoder test.

#include "gpu_metrics_reference.h"

#include <string.h>

size_t gpu_metrics_v1_3_reference(uint8_t *out, size_t capacity)
{
	struct gpu_metrics_v1_3 m;
	if (capacity < sizeof(m))
		return 0;
	memset(&m, 0xff, sizeof(m));
	m.common_header.structure_size = sizeof(m);
	m.common_header.format_revision = 1;
	m.common_header.content_revision = 3;
	m.temperature_edge = 45;
	m.temperature_hotspot = 61;
	m.average_gfx_activity = 37;
	m.average_umc_activity = 12;
	m.average_socket_power = 123;
	m.current_gfxclk = 2450;
	m.average_gfxclk_frequency = 2400;
	m.current_uclk = 1258;
	m.throttle_status = 0x10;
	m.indep_throttle_status = (1ull << 0) | (1ull << 36);
	m.pcie_link_width = 16;
	m.pcie_link_speed = 160;
	memcpy(out, &m, sizeof(m));
	return sizeof(m);
}
