#include <CoreFoundation/CoreFoundation.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <QuickLook/QuickLook.h>

// Must match Info.plist CFPlugInFactories UUID.
#define kParquetPluginFactoryUUID "4D31B2DE-6EE4-4D0A-87E9-112CA5C124F0"

// Implemented in GeneratePreviewForURL.c
OSStatus GenerateThumbnailForURL(void *thisInterface,
                                 QLThumbnailRequestRef thumbnail,
                                 CFURLRef url,
                                 CFStringRef contentTypeUTI,
                                 CFDictionaryRef options,
                                 CGSize maxSize);
void CancelThumbnailGeneration(void *thisInterface, QLThumbnailRequestRef thumbnail);
OSStatus GeneratePreviewForURL(void *thisInterface,
                               QLPreviewRequestRef preview,
                               CFURLRef url,
                               CFStringRef contentTypeUTI,
                               CFDictionaryRef options);
void CancelPreviewGeneration(void *thisInterface, QLPreviewRequestRef preview);

typedef struct ParquetQLGenerator {
    QLGeneratorInterfaceStruct *interface;
    CFUUIDRef factoryID;
    UInt32 refCount;
} ParquetQLGenerator;

static HRESULT ParquetQueryInterface(void *thisInstance, REFIID iid, LPVOID *ppv);
static ULONG ParquetAddRef(void *thisInstance);
static ULONG ParquetRelease(void *thisInstance);

void *QuickLookGeneratorPluginFactory(CFAllocatorRef allocator, CFUUIDRef typeID) {
    if (!CFEqual(typeID, kQLGeneratorTypeID)) {
        return NULL;
    }

    ParquetQLGenerator *plugin =
        (ParquetQLGenerator *)CFAllocatorAllocate(allocator, sizeof(ParquetQLGenerator), 0);
    if (plugin == NULL) {
        return NULL;
    }

    plugin->interface =
        (QLGeneratorInterfaceStruct *)CFAllocatorAllocate(allocator, sizeof(QLGeneratorInterfaceStruct), 0);
    if (plugin->interface == NULL) {
        CFAllocatorDeallocate(allocator, plugin);
        return NULL;
    }

    plugin->interface->_reserved = NULL;
    plugin->interface->QueryInterface = ParquetQueryInterface;
    plugin->interface->AddRef = ParquetAddRef;
    plugin->interface->Release = ParquetRelease;
    plugin->interface->GenerateThumbnailForURL = GenerateThumbnailForURL;
    plugin->interface->CancelThumbnailGeneration = CancelThumbnailGeneration;
    plugin->interface->GeneratePreviewForURL = GeneratePreviewForURL;
    plugin->interface->CancelPreviewGeneration = CancelPreviewGeneration;

    plugin->factoryID = CFUUIDCreateFromString(kCFAllocatorDefault, CFSTR(kParquetPluginFactoryUUID));
    plugin->refCount = 1;
    CFPlugInAddInstanceForFactory(plugin->factoryID);

    return plugin;
}

static HRESULT ParquetQueryInterface(void *thisInstance, REFIID iid, LPVOID *ppv) {
    if (ppv == NULL) {
        return E_POINTER;
    }

    CFUUIDRef interfaceID = CFUUIDCreateFromUUIDBytes(kCFAllocatorDefault, iid);
    if (interfaceID == NULL) {
        *ppv = NULL;
        return E_NOINTERFACE;
    }

    HRESULT result = E_NOINTERFACE;
    if (CFEqual(interfaceID, IUnknownUUID) || CFEqual(interfaceID, kQLGeneratorCallbacksInterfaceID)) {
        *ppv = thisInstance;
        ParquetAddRef(thisInstance);
        result = S_OK;
    } else {
        *ppv = NULL;
    }

    CFRelease(interfaceID);
    return result;
}

static ULONG ParquetAddRef(void *thisInstance) {
    ParquetQLGenerator *plugin = (ParquetQLGenerator *)thisInstance;
    plugin->refCount += 1;
    return plugin->refCount;
}

static ULONG ParquetRelease(void *thisInstance) {
    ParquetQLGenerator *plugin = (ParquetQLGenerator *)thisInstance;
    if (plugin->refCount > 0) {
        plugin->refCount -= 1;
    }

    if (plugin->refCount == 0) {
        CFPlugInRemoveInstanceForFactory(plugin->factoryID);
        CFRelease(plugin->factoryID);
        CFAllocatorDeallocate(kCFAllocatorDefault, plugin->interface);
        CFAllocatorDeallocate(kCFAllocatorDefault, plugin);
        return 0;
    }

    return plugin->refCount;
}

