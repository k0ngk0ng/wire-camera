#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdio.h>

int main(void) {
    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) != KERN_SUCCESS) return 1;
    io_service_t service;
    int found = 0;
    while ((service = IOIteratorNext(iterator))) {
        IOCFPlugInInterface **plugin = NULL;
        IOUSBDeviceInterface **device = NULL;
        SInt32 score = 0;
        if (IOCreatePlugInInterfaceForService(service, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score) == KERN_SUCCESS) {
            (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&device);
            IODestroyPlugInInterface(plugin);
        }
        IOObjectRelease(service);
        if (!device) continue;
        UInt16 vendor = 0, product = 0;
        (*device)->GetDeviceVendor(device, &vendor);
        (*device)->GetDeviceProduct(device, &product);
        if (vendor == 1133 && product == 2085) {
            IOUSBConfigurationDescriptorPtr configuration = NULL;
            if ((*device)->GetConfigurationDescriptorPtr(device, 0, &configuration) == KERN_SUCCESS) {
                const unsigned char *bytes = (const unsigned char *)configuration;
                unsigned int total = bytes[2] | (bytes[3] << 8);
                int videoControl = 0;
                for (unsigned int offset = 0; offset + 2 <= total && bytes[offset] >= 2; offset += bytes[offset]) {
                    const unsigned char *descriptor = bytes + offset;
                    if (offset + descriptor[0] > total) break;
                    if (descriptor[1] == 4 && descriptor[0] >= 9) videoControl = descriptor[5] == 14 && descriptor[6] == 1;
                    if (videoControl && descriptor[1] == 0x24 && descriptor[0] >= 18 && descriptor[2] == 2 && descriptor[4] == 1 && descriptor[5] == 2) {
                        unsigned int controls = descriptor[15] | (descriptor[16] << 8) | (descriptor[17] << 16);
                        printf("{\"vendor\":%u,\"product\":%u,\"cameraTerminal\":%u,\"controls\":%u,\"focusAbsolute\":%s,\"focusRelative\":%s,\"autoFocus\":%s,\"zoomAbsolute\":%s,\"zoomRelative\":%s}\n", vendor, product, descriptor[3], controls,
                            controls & (1 << 5) ? "true" : "false", controls & (1 << 6) ? "true" : "false", controls & (1 << 17) ? "true" : "false",
                            controls & (1 << 9) ? "true" : "false", controls & (1 << 10) ? "true" : "false");
                        found = 1;
                    }
                }
            }
        }
        (*device)->Release(device);
    }
    IOObjectRelease(iterator);
    return found ? 0 : 2;
}
