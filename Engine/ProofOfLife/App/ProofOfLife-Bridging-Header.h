// The iPadOS SDK ships IOKitLib's headers but no Swift module for them.
#include <IOKit/IOKitLib.h>
#include <IOKit/IOReturn.h>

// mac_linuxgpu's firmware servicer (host/fw_mailbox_service.h), compiled
// into this app from $(MAC_LINUXGPU_DIR)/host.
#include "fw_mailbox_service.h"
