// MacLinuxGPU observer user client: the IOKit calls StudioTelemetry needs.
//
// iPadOS has IOKitLib (for apps holding
// com.apple.developer.driverkit.communicates-with-drivers) but no Swift
// module for it. These wrappers keep IOKit's types out of Swift: ports are
// uint32_t, results are IOReturn values as int32_t.
//
// The ABI the calls carry is mac_linuxgpu's dext/sources/session_state.h.

#ifndef MLG_OBSERVER_H
#define MLG_OBSERVER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Registry entry IDs of the services named `service_name` ("MacLinuxGPU"),
/// in registry order. Writes at most `capacity` IDs and returns how many
/// services exist (which may exceed `capacity`); a negative value is an
/// IOReturn from the matching call.
int64_t mlg_service_ids(const char *service_name, uint64_t *ids, uint32_t capacity);

/// Opens user client `type` (1: observer) on the service with this registry
/// entry ID. On success `*connection` is the connection port.
int32_t mlg_open(uint64_t registry_id, uint32_t type, uint32_t *connection);

/// IOConnectCallMethod. `*output_count` and `*output_struct_size` are
/// capacities on entry and the returned sizes on exit.
int32_t mlg_call(uint32_t connection, uint32_t selector,
                 const uint64_t *input, uint32_t input_count,
                 const void *input_struct, size_t input_struct_size,
                 uint64_t *output, uint32_t *output_count,
                 void *output_struct, size_t *output_struct_size);

/// IOServiceClose.
int32_t mlg_close(uint32_t connection);

#ifdef __cplusplus
}
#endif

#endif
