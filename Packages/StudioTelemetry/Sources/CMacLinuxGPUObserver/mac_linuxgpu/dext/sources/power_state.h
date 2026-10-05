/* Device power state: what the driver does when the host sleeps, when the
 * device is idled, and when a client asks for low power ahead of either,
 * and what clients see of it. Cached state only; shared by the user client
 * (MacLinuxGPUXcode.mm), its host tests and scripts/read-driver-log.py.
 *
 * Transitions and the upstream paths behind them
 * ----------------------------------------------
 * Quiesce (VRAM kept). A client's PowerControl PREPARE, or DriverKit
 * reporting the device in a reduced power state while the system runs
 * (SetPowerState(kIOServicePowerCapabilityLow)): upstream amdkfd's suspend,
 * kgd2kfd_suspend(kfd, true), the KFD half of amdgpu_device_suspend()
 * (rt/power.h). Every user queue is unmapped through MES with its running
 * waves saved, the GPU idles, VRAM and page tables stay as they are.
 * Resume is kgd2kfd_resume(kfd, true): the same queues are mapped back and
 * the saved work continues. State ACTIVE -> SUSPENDING -> SUSPENDED (VRAM
 * preserved) -> RESUMING -> ACTIVE.
 *
 * Host sleep (VRAM lost). SetPowerState(kIOServicePowerCapabilityOff): the
 * system is going to sleep and the Thunderbolt link with it, which resets
 * the endpoint; nothing in VRAM survives, and upstream's only dGPU answer
 * (amdgpu_device_suspend's amdgpu_device_evict_resources, moving all VRAM
 * to system RAM through SDMA) cannot fit on the iPad and is the bulk SDMA
 * path that has hung the link. The driver therefore closes the compute
 * session through its ordinary close path (upstream removal,
 * amdgpu_pci_remove, interrupt drain, endpoint reset with bus mastering
 * off) before it acknowledges the power change, and lets IOPCIFamily put
 * the function in D3 for the sleep. On wake the state is LOST if a session
 * was closed (clients reload; the next InitDevice probes the device afresh
 * and the state returns to ACTIVE), ACTIVE if there was none. A quiesced
 * session is resumed first, so the close always starts from upstream's
 * normal state.
 *
 * Every wait on the way is bounded: MES completions by MES's own timeout,
 * the session close by the interrupt drain, and the acknowledgement of a
 * power change by a deadline after which the driver acknowledges anyway.
 * The work runs on the driver's default queue after SetPowerState has
 * returned; the change is acknowledged (passed to the superclass) when it
 * is done.
 * A step that cannot prove the GPU idle leaves the session to the existing
 * quarantine (the GPU may still be using the memory), never to a guess.
 *
 * Client protocol
 * ---------------
 * QueryInfo MLG_QUERY_POWER_STATE (one scalar in, MLG_POWER_STATE_WORDS
 * out; observers too):
 *   out[0]  layout version (MLG_POWER_STATE_VERSION)
 *   out[1]  state (enum mlg_power_state)
 *   out[2]  generation: increments on every state change
 *   out[3]  MLG_POWER_FLAG_* bits
 *   out[4]  cause of the last transition (enum mlg_power_cause)
 *   out[5]  error of the last failed step, sign-extended (0 if none)
 *   out[6]  clients holding a PREPARE
 *   out[7]  quiesces completed (VRAM kept)
 *   out[8]  transitions that lost device memory
 *   out[9]  duration of the last completed transition, microseconds
 *   out[10] session generation the state refers to
 *   out[11] reserved (0)
 *
 * Selector MLG_SELECTOR_POWER (PowerControl), scalar in [0] op:
 *   QUERY   out as the QueryInfo tag.
 *   PREPARE this client asks for low power: no new GPU work is admitted
 *           and the compute session is quiesced (the first hold does it).
 *           Returns when the transition finished; out as QUERY.
 *   RESUME  this client drops its hold; the last hold resumes. out as QUERY.
 *   WAIT    async (IOConnectCallAsyncScalarMethod) with in[1] the
 *           generation the client knows: completes at once when the
 *           current generation differs, else at the next change, with
 *           async data [0] state, [1] generation, [2] flags. A client's
 *           pending waits complete with kIOReturnAborted when it closes.
 * Session clients may hold; observers may QUERY and WAIT, and PREPARE or
 * RESUME only with the session-release entitlement (the host app).
 *
 * While the state is SUSPENDING, SUSPENDED or RESUMING, selectors that
 * would put work on the GPU (allocation, transfers, queue creation, kicks,
 * dispatches, initialization) are refused with kIOReturnOffline, which a
 * client retries after resume; freeing buffers, destroying queues and the
 * cached queries stay available (mlg_power_admits). In LOST the client's
 * session no longer exists: its selectors fail as for any closed session
 * (kIOReturnNotOpen) and InitDevice starts a new one. */
#ifndef MACLINUXGPU_POWER_STATE_H
#define MACLINUXGPU_POWER_STATE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define MLG_POWER_STATE_VERSION 1u
#define MLG_POWER_STATE_WORDS   12u
#define MLG_QUERY_POWER_STATE   0x4c505752ULL /* "LPWR" */
#define MLG_SELECTOR_POWER      83u
/* How long a power-change acknowledgement may wait for the work it needs
 * (a session close, a quiesce). The kernel gives a dext a bounded time to
 * acknowledge (xnu's IOUserServer allows 20 s); this stays under it. */
#define MLG_POWER_ACK_DEADLINE_MS 15000u

enum mlg_power_state {
	MLG_POWER_ACTIVE     = 0,
	MLG_POWER_SUSPENDING = 1,
	MLG_POWER_SUSPENDED  = 2,
	MLG_POWER_RESUMING   = 3,
	MLG_POWER_LOST       = 4,
};

enum mlg_power_flag {
	MLG_POWER_FLAG_VRAM_PRESERVED = 1u << 0, /* device memory is what clients left */
	MLG_POWER_FLAG_SYSTEM_SLEEP   = 1u << 1, /* SetPowerState(Off) until the wake */
	MLG_POWER_FLAG_DEVICE_LOW     = 1u << 2, /* SetPowerState(Low) until On */
	MLG_POWER_FLAG_CLIENT_HOLD    = 1u << 3, /* at least one PREPARE held */
	MLG_POWER_FLAG_KFD_QUIESCED   = 1u << 4, /* upstream KFD suspended */
	MLG_POWER_FLAG_SESSION_CLOSED = 1u << 5, /* the session was closed for a sleep */
	MLG_POWER_FLAG_ACK_PENDING    = 1u << 6, /* a power change awaits acknowledgement */
	MLG_POWER_FLAG_LINK_DOWN      = 1u << 7, /* config space did not answer after wake */
};

enum mlg_power_cause {
	MLG_POWER_CAUSE_NONE           = 0,
	MLG_POWER_CAUSE_CLIENT_PREPARE = 1,
	MLG_POWER_CAUSE_CLIENT_RESUME  = 2,
	MLG_POWER_CAUSE_CLIENT_EXIT    = 3,  /* a holding client closed */
	MLG_POWER_CAUSE_SYSTEM_SLEEP   = 4,
	MLG_POWER_CAUSE_SYSTEM_WAKE    = 5,
	MLG_POWER_CAUSE_DEVICE_LOW     = 6,
	MLG_POWER_CAUSE_DEVICE_ON      = 7,
	MLG_POWER_CAUSE_QUIESCE_FAILED = 8,  /* upstream KFD suspend reported a failure */
	MLG_POWER_CAUSE_RESUME_FAILED  = 9,  /* upstream KFD resume failed */
	MLG_POWER_CAUSE_LINK_DOWN      = 10, /* the device was gone after wake */
	MLG_POWER_CAUSE_REPROBED       = 11, /* a new session after LOST */
	MLG_POWER_CAUSE_SESSION_CLOSED = 12, /* the session closed while suspended */
	MLG_POWER_CAUSE_DEVICE_REMOVED = 13, /* the device left the bus (unplugged) */
};

enum mlg_power_op {
	MLG_POWER_OP_QUERY   = 0,
	MLG_POWER_OP_PREPARE = 1,
	MLG_POWER_OP_RESUME  = 2,
	MLG_POWER_OP_WAIT    = 3,
};

/* DriverKit's SetPowerState capability flags (IOService.iig). */
#define MLG_POWER_CAPABILITY_OFF 0x00000000u
#define MLG_POWER_CAPABILITY_ON  0x00000002u
#define MLG_POWER_CAPABILITY_LOW 0x00010000u

struct mlg_power {
	uint32_t state, flags, cause, holds;
	int32_t error;
	uint64_t generation, quiesces, losses, last_us, session;
};

static inline void mlg_power_init(struct mlg_power *p)
{
	memset(p, 0, sizeof(*p));
	p->state = MLG_POWER_ACTIVE;
	p->flags = MLG_POWER_FLAG_VRAM_PRESERVED;
	p->generation = 1;
}

static inline bool mlg_power_transition_allowed(uint32_t from, uint32_t to)
{
	switch (from) {
	case MLG_POWER_ACTIVE:
		return to == MLG_POWER_SUSPENDING || to == MLG_POWER_LOST;
	case MLG_POWER_SUSPENDING:
		/* Done, failed into a lost session, or nothing could be done. */
		return to == MLG_POWER_SUSPENDED || to == MLG_POWER_LOST || to == MLG_POWER_ACTIVE;
	case MLG_POWER_SUSPENDED:
		/* Resume, or deepen to a sleep (the session closes). */
		return to == MLG_POWER_RESUMING || to == MLG_POWER_SUSPENDING || to == MLG_POWER_LOST;
	case MLG_POWER_RESUMING:
		return to == MLG_POWER_ACTIVE || to == MLG_POWER_LOST;
	case MLG_POWER_LOST:
		/* A new session, or a sleep with nothing left to close. */
		return to == MLG_POWER_ACTIVE || to == MLG_POWER_SUSPENDING;
	default:
		return false;
	}
}

/* Move to @to for @cause; @error is the failing step's code (0 if none).
 * Every change bumps the generation. Returns false (and changes nothing)
 * for a transition the machine does not have. */
static inline bool mlg_power_set(struct mlg_power *p, uint32_t to, uint32_t cause, int32_t error)
{
	if (to == p->state || !mlg_power_transition_allowed(p->state, to))
		return false;
	p->state = to;
	p->cause = cause;
	if (error)
		p->error = error;
	++p->generation;
	if (to == MLG_POWER_LOST) {
		p->flags &= ~(uint32_t)MLG_POWER_FLAG_VRAM_PRESERVED;
		++p->losses;
	}
	return true;
}

static inline void mlg_power_snapshot(const struct mlg_power *p, uint64_t out[MLG_POWER_STATE_WORDS])
{
	out[0] = MLG_POWER_STATE_VERSION;
	out[1] = p->state;
	out[2] = p->generation;
	out[3] = p->flags | (p->holds ? MLG_POWER_FLAG_CLIENT_HOLD : 0u);
	out[4] = p->cause;
	out[5] = (uint64_t)(int64_t)p->error;
	out[6] = p->holds;
	out[7] = p->quiesces;
	out[8] = p->losses;
	out[9] = p->last_us;
	out[10] = p->session;
	out[11] = 0;
}

/* Whether the power state lets a session client's selector run. Only the
 * transitional and suspended states refuse anything; LOST is the closed
 * session's own business. Selectors that may open a session (GetIdentity,
 * HostWindow, InitDevice) wait too. Numbers are the MacAMDGPU selectors. */
static inline bool mlg_power_admits(uint32_t state, uint64_t selector)
{
	if (state == MLG_POWER_ACTIVE || state == MLG_POWER_LOST)
		return true;
	switch (selector) {
	case 0:   /* Ping */
	case 2:   /* GetBARInfo */
	case 17:  /* BOFree: unmapping only */
	case 18:  /* BOGetInfo */
	case 21:  /* QueryInfo: cached */
	case 36:  /* BOMap: client mapping of host pages */
	case 41:  /* GetReBARInfo */
	case 42:  /* ShutdownGPU */
	case 43:  /* RuntimeBuild */
	case 58:  /* AQLQueueDestroy: an unmapped queue */
	case 60:  /* AtomicRequester: no configuration write */
	case 61:  /* ReleaseQuarantine */
	case MLG_SELECTOR_POWER:
		return true;
	default:
		return false;
	}
}

/* What a power event asks the driver to do, from cached state. */
enum mlg_power_action {
	MLG_POWER_DO_NOTHING = 0,
	MLG_POWER_DO_QUIESCE,       /* kgd2kfd_suspend; VRAM kept */
	MLG_POWER_DO_RESUME,        /* kgd2kfd_resume */
	MLG_POWER_DO_IDLE,          /* no session: just stop admitting work */
	MLG_POWER_DO_WAKE_IDLE,     /* no session: admit work again */
	MLG_POWER_DO_CLOSE_SESSION, /* sleep: resume if quiesced, then close */
	MLG_POWER_DO_WAKE_LOST,     /* wake after a closed session: LOST */
};

/* @session: a compute session is open with the upstream driver running.
 * Events: a client PREPARE (a hold taken; p->holds counts it already), a
 * RESUME or a holding client's exit (a hold dropped; p->holds is the count
 * after it), and the SetPowerState capability. */
static inline enum mlg_power_action mlg_power_plan_hold(const struct mlg_power *p, bool session)
{
	if (p->state != MLG_POWER_ACTIVE || !p->holds)
		return MLG_POWER_DO_NOTHING;
	return session ? MLG_POWER_DO_QUIESCE : MLG_POWER_DO_IDLE;
}

static inline enum mlg_power_action mlg_power_plan_release(const struct mlg_power *p)
{
	if (p->holds || (p->flags & (MLG_POWER_FLAG_DEVICE_LOW | MLG_POWER_FLAG_SYSTEM_SLEEP)) ||
	    p->state != MLG_POWER_SUSPENDED || (p->flags & MLG_POWER_FLAG_SESSION_CLOSED))
		return MLG_POWER_DO_NOTHING;
	return (p->flags & MLG_POWER_FLAG_KFD_QUIESCED) ? MLG_POWER_DO_RESUME : MLG_POWER_DO_WAKE_IDLE;
}

static inline enum mlg_power_action mlg_power_plan_capability(const struct mlg_power *p,
							      uint32_t capability, bool session)
{
	if (capability == MLG_POWER_CAPABILITY_OFF) {
		if (session)
			return MLG_POWER_DO_CLOSE_SESSION;
		return p->state == MLG_POWER_ACTIVE ? MLG_POWER_DO_IDLE : MLG_POWER_DO_NOTHING;
	}
	if (capability & MLG_POWER_CAPABILITY_ON) {
		if (p->flags & MLG_POWER_FLAG_SESSION_CLOSED)
			return MLG_POWER_DO_WAKE_LOST;
		if (p->holds || p->state != MLG_POWER_SUSPENDED)
			return MLG_POWER_DO_NOTHING;
		return (p->flags & MLG_POWER_FLAG_KFD_QUIESCED) ? MLG_POWER_DO_RESUME : MLG_POWER_DO_WAKE_IDLE;
	}
	if (capability & MLG_POWER_CAPABILITY_LOW) {
		if (p->state != MLG_POWER_ACTIVE)
			return MLG_POWER_DO_NOTHING;
		return session ? MLG_POWER_DO_QUIESCE : MLG_POWER_DO_IDLE;
	}
	return MLG_POWER_DO_NOTHING;
}

#endif
