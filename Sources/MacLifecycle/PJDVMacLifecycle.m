#import <AppKit/AppKit.h>
#import <IOKit/IOKitLib.h>
@protocol PJDVMacHardware
+ (NSDictionary *)hardwareSnapshot;
@end
@protocol PJDVMacDisplay
+ (NSDictionary *)displaySnapshot;
@end
@protocol PJDVMacTermination
+ (void)terminateApplication;
@end
@protocol PJDVMacFileSelection
+ (void)chooseLocalItemWithTitle:(NSString *)title directory:(BOOL)directory
                     completion:(void (^)(NSURL * _Nullable))completion;
@end
@interface PJDVMacLifecycle : NSObject <PJDVMacTermination, PJDVMacFileSelection, PJDVMacHardware, PJDVMacDisplay>
+ (void)terminateApplication;
@end
@implementation PJDVMacLifecycle
+ (NSDictionary *)displaySnapshot {
    NSAssert(NSThread.isMainThread, @"Display queries must run on the main thread");
    static dispatch_once_t once;
    static NSMutableArray *observers;
    dispatch_once(&once, ^{
        observers = [NSMutableArray array];
        for (NSNotificationName name in @[NSWindowDidChangeScreenNotification, NSWindowDidChangeBackingPropertiesNotification, NSApplicationDidChangeScreenParametersNotification]) {
            [observers addObject:[NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                [NSNotificationCenter.defaultCenter postNotificationName:@"PJDVHostDisplayDidChange" object:nil];
            }]];
        }
    });
    NSWindow *window = NSApplication.sharedApplication.mainWindow ?: NSApplication.sharedApplication.keyWindow;
    NSScreen *screen = window.screen ?: NSScreen.mainScreen;
    if (!screen) return @{};
    // Desktop backing pixels follow the current display scaling mode. Do not
    // cache mainScreen: the game may move between Retina/non-Retina monitors.
    NSRect desktop = [screen convertRectToBacking:screen.frame];
    NSView *content = window.contentView;
    NSRect backing = content ? [content convertRectToBacking:content.bounds] : NSZeroRect;
    return @{@"desktopWidth":@(desktop.size.width), @"desktopHeight":@(desktop.size.height),
             @"contentWidth":@(backing.size.width), @"contentHeight":@(backing.size.height)};
}
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
