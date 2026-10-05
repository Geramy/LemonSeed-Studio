// The iPadOS SDK ships IOKitLib's headers but no Swift module for them.
// The Studio uses them to find the embedded driver's "MacLinuxGPU" service.
#include <IOKit/IOKitLib.h>
#include <IOKit/IOReturn.h>

// mac_linuxgpu's firmware servicer (host/fw_mailbox_service.h), compiled
// into device builds from $(MAC_LINUXGPU_DIR)/host (Device/dext.yml) for the
// Diagnostics screen's manual bring-up.
#if __has_include("fw_mailbox_service.h")
#include "fw_mailbox_service.h"
#endif

// mac_linuxgpu's selector call (host/selector_call.h, device builds): every
// DriverClient call goes through it, synchronous or async as the driver
// serves the selector.
#if __has_include("selector_call.h")
#include "selector_call.h"
#endif
