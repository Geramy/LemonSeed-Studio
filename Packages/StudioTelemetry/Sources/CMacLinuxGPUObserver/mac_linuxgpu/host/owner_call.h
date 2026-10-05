/* A MacLinuxGPU selector called the way the driver runs every call that can
 * sleep (dext/sources/session_state.h, "Calls that never sleep, and every
 * other call"): with IOConnectCallAsyncMethod, the completion awaited on the
 * calling thread, and the structure output, if any, fetched with
 * OWNER_RESULT. To its caller it behaves as IOConnectCallMethod does: the
 * selector's IOReturn, its scalar outputs and its structure output.
 *
 * Header only (static inline), for the host app (through its bridging
 * header), the HSA runtime and libmlg_drm. Each call has a notification
 * port of its own (header-only code keeps no state: Swift imports these
 * functions, not static variables). */
#ifndef MLG_OWNER_CALL_H
#define MLG_OWNER_CALL_H

#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <time.h>

/* session_state.h's numbers (scripts/test-owner-call.sh checks they match). */
#define MLG_OWNER_CALL_SELECTOR_PING	0u
#define MLG_OWNER_CALL_SELECTOR_RESULT	88u
#define MLG_OWNER_CALL_HEADER		4u
#define MLG_OWNER_CALL_SCALARS		12u
#define MLG_OWNER_CALL_WORDS		(MLG_OWNER_CALL_HEADER + MLG_OWNER_CALL_SCALARS)
#define MLG_OWNER_CALL_MAX_SCALARS	16u

struct mlg_owner_call_waiter {
	bool done;
	kern_return_t status;
	uint64_t args[MLG_OWNER_CALL_WORDS];
	uint32_t nargs;
};

static inline void mlg_owner_call_completed(void *refcon, IOReturn result, void **args,
					    uint32_t nargs)
{
	struct mlg_owner_call_waiter *w = (struct mlg_owner_call_waiter *)refcon;

	w->status = result;
	w->nargs = nargs < MLG_OWNER_CALL_WORDS ? nargs : MLG_OWNER_CALL_WORDS;
	for (uint32_t i = 0; i < w->nargs; ++i)
		w->args[i] = (uint64_t)(uintptr_t)args[i];
	w->done = true;
}

/* Wait for @w's completion on @port. The driver ends every call itself (a
 * session call's own bounds, the session's close); each second without
 * one, a Ping notices a driver that went away (kIOReturnNotAttached).
 * With @timeout_ms (0: none), a completion that has not arrived by then
 * is kIOReturnTimeout: for a caller that must not wait on a driver that
 * answers Ping but never completes the call. */
static inline kern_return_t mlg_owner_call_wait(io_connect_t connection, IONotificationPortRef port,
						struct mlg_owner_call_waiter *w, uint32_t timeout_ms)
{
	union {
		mach_msg_header_t header;
		uint8_t bytes[4096];
	} msg;
	const uint64_t deadline = timeout_ms ? clock_gettime_nsec_np(CLOCK_UPTIME_RAW) +
						       (uint64_t)timeout_ms * 1000000ull : 0;

	while (!w->done) {
		kern_return_t kr;
		mach_msg_timeout_t slice = 1000;

		if (deadline) {
			const uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);

			if (now >= deadline)
				return kIOReturnTimeout;
			if ((deadline - now) / 1000000ull < slice)
				slice = (mach_msg_timeout_t)((deadline - now + 999999ull) / 1000000ull);
		}
		memset(&msg.header, 0, sizeof(msg.header));
		kr = mach_msg(&msg.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(msg),
			      IONotificationPortGetMachPort(port), slice, MACH_PORT_NULL);
		if (kr == MACH_RCV_TIMED_OUT) {
			uint64_t pong = 0;
			uint32_t n = 1;

			if (IOConnectCallScalarMethod(connection, MLG_OWNER_CALL_SELECTOR_PING, NULL, 0,
						      &pong, &n) != kIOReturnSuccess)
				return kIOReturnNotAttached;
			continue;
		}
		if (kr != MACH_MSG_SUCCESS)
			return kIOReturnIPCError;
		IODispatchCalloutFromMessage(NULL, &msg.header, port);
	}
	return kIOReturnSuccess;
}

/* The longest a session call's completion may take. The driver bounds
 * every call itself; this is the backstop for a completion that never
 * comes from a driver that still answers Ping (a selector it serves
 * synchronously, sent async: build 243's LX_MMAP_COMMIT hung every
 * Vulkan client so). Generous: bringing the GPU up (InitDevice, with the
 * firmware it asks for), closing it and the submission self-test take the
 * longest. */
#ifndef MLG_OWNER_CALL_BOUND_MS		/* (tests shorten them) */
#define MLG_OWNER_CALL_BOUND_MS		120000u
#define MLG_OWNER_CALL_LONG_BOUND_MS	300000u
#endif

static inline uint32_t mlg_owner_call_bound_ms(uint32_t selector)
{
	switch (selector) {
	case 9u:	/* InitDevice */
	case 42u:	/* ShutdownGPU */
	case 82u:	/* DrmSelftest */
		return MLG_OWNER_CALL_LONG_BOUND_MS;
	default:
		return MLG_OWNER_CALL_BOUND_MS;
	}
}

/* @selector with @input and @input_struct, as IOConnectCallMethod would
 * call it: on return *@output_count scalars are in @output and
 * *@output_struct_size bytes in @output_struct (pass NULLs for none). The
 * result is the selector's IOReturn, or a transport failure (the call did
 * not start, or the driver went away), or kIOReturnTimeout past
 * @timeout_ms (0: the selector's bound, mlg_owner_call_bound_ms). */
static inline kern_return_t mlg_owner_call_on(IONotificationPortRef port, io_connect_t connection,
					      uint32_t timeout_ms, uint32_t selector,
					      const uint64_t *input, uint32_t input_count,
					      const void *input_struct, size_t input_struct_size,
					      uint64_t *output, uint32_t *output_count,
					      void *output_struct, size_t *output_struct_size)
{
	struct mlg_owner_call_waiter w;
	io_user_reference_t ref[kIOAsyncCalloutCount];
	uint64_t immediate[MLG_OWNER_CALL_MAX_SCALARS];
	uint32_t want = output_count ? *output_count : 0, n;
	size_t struct_cap = output_struct_size ? *output_struct_size : 0;
	uint8_t struct_probe = 0;
	kern_return_t kr;

	/* Up to IOKit's 16; the driver returns those its completion cannot
	 * hold (more than MLG_OWNER_CALL_SCALARS) through OWNER_RESULT. */
	if (want > MLG_OWNER_CALL_MAX_SCALARS)
		want = MLG_OWNER_CALL_MAX_SCALARS;
	memset(&w, 0, sizeof(w));
	memset(ref, 0, sizeof(ref));
	ref[kIOAsyncCalloutFuncIndex] = (io_user_reference_t)(uintptr_t)mlg_owner_call_completed;
	ref[kIOAsyncCalloutRefconIndex] = (io_user_reference_t)(uintptr_t)&w;
	/* The immediate reply carries only the token; the scalar and structure
	 * capacities tell the driver what the caller asked of the selector. */
	n = want;
	{
		size_t probe_size = struct_cap;

		kr = IOConnectCallAsyncMethod(connection, selector, IONotificationPortGetMachPort(port),
					      ref, kIOAsyncCalloutCount, input, input_count,
					      input_struct, input_struct_size, immediate, &n,
					      struct_cap ? output_struct : (void *)&struct_probe,
					      struct_cap ? &probe_size : NULL);
	}
	if (kr != kIOReturnSuccess)
		return kr;
	if (!timeout_ms)
		timeout_ms = mlg_owner_call_bound_ms(selector);	/* never unbounded */
	kr = mlg_owner_call_wait(connection, port, &w, timeout_ms);
	if (kr != kIOReturnSuccess)
		return kr;
	if (w.status != kIOReturnSuccess)
		return w.status;
	if (w.nargs < MLG_OWNER_CALL_HEADER || w.args[2] > want)
		return kIOReturnIPCError;
	if ((kern_return_t)w.args[1] != kIOReturnSuccess)
		return (kern_return_t)w.args[1];
	n = (uint32_t)w.args[2];
	if (n <= MLG_OWNER_CALL_SCALARS) {
		if (w.nargs < MLG_OWNER_CALL_HEADER + n)
			return kIOReturnIPCError;
		for (uint32_t i = 0; i < n; ++i)
			output[i] = w.args[MLG_OWNER_CALL_HEADER + i];
		if (output_count)
			*output_count = n;
		n = 0;	/* none in the kept result */
	}
	if (n || w.args[3]) {
		/* Kept by the driver until fetched: the scalars the completion
		 * could not hold, then the structure output. */
		uint64_t token = w.args[0];
		const size_t scalar_bytes = (size_t)n * sizeof(uint64_t);
		const size_t bytes = scalar_bytes + (size_t)w.args[3];
		uint8_t local[MLG_OWNER_CALL_MAX_SCALARS * sizeof(uint64_t)];
		uint8_t *buffer = scalar_bytes ? local : (uint8_t *)output_struct;
		size_t size = bytes;
		uint32_t none = 0;

		if (w.args[3] && (!output_struct || w.args[3] > struct_cap))
			return kIOReturnNoSpace;
		if (scalar_bytes && w.args[3]) {
			buffer = (uint8_t *)malloc(bytes);
			if (!buffer)
				return kIOReturnNoMemory;
		}
		kr = IOConnectCallMethod(connection, MLG_OWNER_CALL_SELECTOR_RESULT, &token, 1, NULL, 0,
					 NULL, &none, buffer, &size);
		if (kr == kIOReturnSuccess && size != bytes)
			kr = kIOReturnIPCError;
		if (kr == kIOReturnSuccess && scalar_bytes) {
			memcpy(output, buffer, scalar_bytes);
			*output_count = n;
			if (w.args[3])
				memcpy(output_struct, buffer + scalar_bytes, (size_t)w.args[3]);
		}
		if (buffer != local && buffer != (uint8_t *)output_struct)
			free(buffer);
		if (kr != kIOReturnSuccess)
			return kr;
		if (output_struct_size)
			*output_struct_size = (size_t)w.args[3];
	} else if (output_struct_size) {
		*output_struct_size = 0;
	}
	return kIOReturnSuccess;
}

/* mlg_owner_call, with kIOReturnTimeout when the completion has not come
 * within @timeout_ms. A completion that comes later is dropped with the
 * call's notification port. */
static inline kern_return_t mlg_owner_call_timed(io_connect_t connection, uint32_t timeout_ms,
						 uint32_t selector,
						 const uint64_t *input, uint32_t input_count,
						 const void *input_struct, size_t input_struct_size,
						 uint64_t *output, uint32_t *output_count,
						 void *output_struct, size_t *output_struct_size)
{
	IONotificationPortRef port = IONotificationPortCreate(kIOMainPortDefault);
	kern_return_t kr;

	if (!port)
		return kIOReturnNoMemory;
	kr = mlg_owner_call_on(port, connection, timeout_ms, selector, input, input_count,
			       input_struct, input_struct_size, output, output_count, output_struct,
			       output_struct_size);
	IONotificationPortDestroy(port);
	return kr;
}

/* An async session call (mlg_owner_call_timed) within its bound; past it,
 * kIOReturnTimeout and a line on stderr naming the selector. */
static inline kern_return_t mlg_owner_call(io_connect_t connection, uint32_t selector,
					   const uint64_t *input, uint32_t input_count,
					   const void *input_struct, size_t input_struct_size,
					   uint64_t *output, uint32_t *output_count,
					   void *output_struct, size_t *output_struct_size)
{
	const uint32_t bound = mlg_owner_call_bound_ms(selector);
	const kern_return_t kr = mlg_owner_call_timed(connection, 0, selector, input, input_count,
						      input_struct, input_struct_size, output,
						      output_count, output_struct, output_struct_size);

	if (kr == kIOReturnTimeout)
		fprintf(stderr, "mac_linuxgpu: selector %u: no completion within %u s from a driver that "
			"still answers Ping (kIOReturnTimeout)\n", selector, bound / 1000u);
	return kr;
}

#endif
