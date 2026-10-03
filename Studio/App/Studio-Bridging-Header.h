// The iPadOS SDK ships IOKitLib's headers but no Swift module for them.
// The Studio uses them to find the embedded driver's "MacLinuxGPU" service.
#include <IOKit/IOKitLib.h>
#include <IOKit/IOReturn.h>
