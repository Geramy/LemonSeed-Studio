// MacLinuxGPU observer user client: IOKit wrappers (see mlg_observer.h).

#include "mlg_observer.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>

// mac_linuxgpu's selector call, copied unchanged with its layout from
// third_party/mac_linuxgpu (StudioAppTests checks the copies match).
#include "mac_linuxgpu/host/selector_call.h"

int64_t mlg_service_ids(const char *service_name, uint64_t *ids, uint32_t capacity)
{
	io_iterator_t iterator = IO_OBJECT_NULL;
	// IOServiceGetMatchingServices consumes the matching dictionary.
	kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault,
	                                                IOServiceNameMatching(service_name),
	                                                &iterator);
	if (kr != KERN_SUCCESS)
		return kr < 0 ? kr : -(int64_t)kr;
	int64_t count = 0;
	io_service_t service;
	while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
		uint64_t id = 0;
		if (IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS) {
			if (ids && (uint64_t)count < capacity)
				ids[count] = id;
			count++;
		}
		IOObjectRelease(service);
	}
	IOObjectRelease(iterator);
	return count;
}

int32_t mlg_open(uint64_t registry_id, uint32_t type, uint32_t *connection)
{
	if (!connection)
		return kIOReturnBadArgument;
	*connection = IO_OBJECT_NULL;
	io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault,
	                                                   IORegistryEntryIDMatching(registry_id));
	if (service == IO_OBJECT_NULL)
		return kIOReturnNotFound;
	io_connect_t port = IO_OBJECT_NULL;
	kern_return_t kr = IOServiceOpen(service, mach_task_self(), type, &port);
	IOObjectRelease(service);
	if (kr == KERN_SUCCESS)
		*connection = port;
	return kr;
}

int32_t mlg_call(uint32_t connection, uint32_t selector,
                 const uint64_t *input, uint32_t input_count,
                 const void *input_struct, size_t input_struct_size,
                 uint64_t *output, uint32_t *output_count,
                 void *output_struct, size_t *output_struct_size)
{
	// As the driver serves the selector: synchronously when it never sleeps
	// or is a bounded read, else as an awaited async call (build 243 on).
	return mlg_selector_call(connection, selector, input, input_count,
	                         input_struct, input_struct_size,
	                         output, output_count, output_struct, output_struct_size);
}

bool mlg_selector_is_synchronous(uint32_t selector, const uint64_t *input, uint32_t input_count)
{
	return mlg_call_is_synchronous(selector, input, input_count);
}

int32_t mlg_close(uint32_t connection)
{
	return IOServiceClose(connection);
}
