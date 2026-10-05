/* A MacLinuxGPU selector called as the driver serves it
 * (dext/sources/session_state.h): synchronously when it never sleeps (or is
 * a bounded read), else as an async session call awaited on this thread
 * (owner_call.h). Either way the caller sees what IOConnectCallMethod
 * returns: the selector's IOReturn, its scalars and its structure output.
 * Header only, for the host app (bridging header), the HSA runtime and
 * libmlg_drm. */
#ifndef MLG_SELECTOR_CALL_H
#define MLG_SELECTOR_CALL_H

#include "owner_call.h"
#include "../dext/sources/session_state.h"

/* Whether the driver behind @connection serves session calls async: 1,
 * 0 for an older driver (which answers them synchronously and would never
 * complete an async call), or -1 when RuntimeBuild itself failed. */
static inline int mlg_driver_async_session_calls(io_connect_t connection)
{
	uint64_t build[4] = {0, 0, 0, 0};
	uint32_t count = 4;

	if (IOConnectCallScalarMethod(connection, MLG_SELECTOR_RUNTIME_BUILD, NULL, 0, build,
				      &count) != kIOReturnSuccess)
		return -1;
	return count >= 4 && build[3] >= MLG_SESSION_CALLS_ASYNC_BUILD;
}

/* As mlg_selector_call, with the driver's protocol remembered in *@state
 * (0 before the first call; the caller keeps it per connection). A
 * selector that must be async, against a driver older than
 * MLG_SESSION_CALLS_ASYNC_BUILD, fails at once with kIOReturnUnsupported:
 * never a wait for a completion that will not come. */
static inline kern_return_t mlg_selector_call_on(io_connect_t connection, int *state,
						 uint32_t selector,
						 const uint64_t *input, uint32_t input_count,
						 const void *input_struct, size_t input_struct_size,
						 uint64_t *output, uint32_t *output_count,
						 void *output_struct, size_t *output_struct_size)
{
#ifndef MLG_SELECTOR_CALL_TEST_SYNC
	if (mlg_call_is_synchronous(selector, input, input_count))
#endif
	{
		/* (Tests that replace the IOKit calls define
		 * MLG_SELECTOR_CALL_TEST_SYNC to see every selector here.) */
		if (!input_struct && !output_struct)
			return IOConnectCallScalarMethod(connection, selector, input, input_count,
							 output, output_count);
		return IOConnectCallMethod(connection, selector, input, input_count, input_struct,
					   input_struct_size, output, output_count, output_struct,
					   output_struct_size);
	}
	if (*state == 0) {
		const int async = mlg_driver_async_session_calls(connection);

		if (async < 0)
			return kIOReturnNotAttached;
		*state = async ? 1 : -1;
	}
	if (*state < 0)
		return kIOReturnUnsupported;	/* a driver older than build 243 */
	return mlg_owner_call(connection, selector, input, input_count, input_struct,
			      input_struct_size, output, output_count, output_struct,
			      output_struct_size);
}

/* @selector as the driver serves it (the protocol checked on each async
 * call: for callers that make few). */
static inline kern_return_t mlg_selector_call(io_connect_t connection, uint32_t selector,
					      const uint64_t *input, uint32_t input_count,
					      const void *input_struct, size_t input_struct_size,
					      uint64_t *output, uint32_t *output_count,
					      void *output_struct, size_t *output_struct_size)
{
	int state = 0;

	return mlg_selector_call_on(connection, &state, selector, input, input_count,
				    input_struct, input_struct_size, output, output_count,
				    output_struct, output_struct_size);
}

#endif
