#import <AppKit/AppKit.h>
#import <IOKit/IOKitLib.h>
@protocol PJDVMacHardware
+ (NSDictionary *)hardwareSnapshot;
@end
@protocol PJDVMacTermination
+ (void)terminateApplication;
@end
@protocol PJDVMacFileSelection
+ (void)chooseLocalItemWithTitle:(NSString *)title directory:(BOOL)directory
                     completion:(void (^)(NSURL * _Nullable))completion;
@end
@interface PJDVMacLifecycle : NSObject <PJDVMacTermination, PJDVMacFileSelection, PJDVMacHardware>
+ (void)terminateApplication;
@end
@implementation PJDVMacLifecycle
+ (NSDictionary *)hardwareSnapshot {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSScreen *screen = NSApplication.sharedApplication.keyWindow.screen ?: NSScreen.mainScreen;
    if (@available(macOS 12.0, *)) result[@"maximumRefresh"] = @(screen.maximumFramesPerSecond);
    // Read the actual enabled GPU core count; SoC names alone do not identify
    // Mac GPU bins. No private Metal selectors or external command execution.
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceMatching("AGXAccelerator"), &iterator) == KERN_SUCCESS) {
        io_object_t service; unsigned total = 0;
        while ((service = IOIteratorNext(iterator))) {
            CFTypeRef value = IORegistryEntryCreateCFProperty(service, CFSTR("gpu-core-count"), kCFAllocatorDefault, 0);
            if (value && CFGetTypeID(value) == CFNumberGetTypeID()) { int cores = 0; if (CFNumberGetValue(value, kCFNumberIntType, &cores) && cores > 0) total += cores; }
            if (value) CFRelease(value); IOObjectRelease(service);
        }
        IOObjectRelease(iterator); if (total) result[@"gpuCores"] = @(total);
    }
    return result;
}
static NSOpenPanel *activeFilePanel;
+ (void)chooseLocalItemWithTitle:(NSString *)title directory:(BOOL)directory
                     completion:(void (^)(NSURL * _Nullable))completion {
    NSAssert(NSThread.isMainThread, @"File panels must run on the main thread");
    if (activeFilePanel) { completion(nil); return; }
    NSOpenPanel *panel = NSOpenPanel.openPanel;
    activeFilePanel = panel;
    panel.title = title;
    panel.canChooseFiles = !directory;
    panel.canChooseDirectories = directory;
    panel.canCreateDirectories = directory;
    panel.allowsMultipleSelection = NO;
    panel.resolvesAliases = YES;
    // XCI / .keys may have no registered UTType on another Mac. Let the
    // importer validate the selected file instead of silently filtering it.
    panel.allowedContentTypes = @[];
    panel.allowsOtherFileTypes = YES;
    [panel beginWithCompletionHandler:^(NSModalResponse result) {
        NSURL *url = result == NSModalResponseOK ? panel.URL : nil;
        [panel orderOut:nil];
        activeFilePanel = nil;
        // The next panel (XCI -> destination) starts after this one closes.
        dispatch_async(dispatch_get_main_queue(), ^{ completion(url); });
    }];
}
+ (void)terminateApplication {
    dispatch_async(dispatch_get_main_queue(), ^{ [NSApplication.sharedApplication terminate:nil]; });
}
@end
