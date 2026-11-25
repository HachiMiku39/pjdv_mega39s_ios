#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/graphics/IOGraphicsTypes.h>
@protocol PJDVMacHardware
+ (NSDictionary *)hardwareSnapshot;
@end
@protocol PJDVMacDisplay
+ (NSDictionary *)displaySnapshot;
+ (NSDictionary *)displaySnapshotForSystemFrame:(CGRect)frame;
+ (void)configureLaunchWindow;
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

static NSRect PJDVLaunchFrame(NSRect visible, NSSize chrome, NSSize contentPoints) {
    if (contentPoints.width <= 0 || contentPoints.height <= 0) return NSZeroRect;
    CGFloat fit = MIN(1.0, MIN((NSWidth(visible) - chrome.width) / contentPoints.width,
                               (NSHeight(visible) - chrome.height) / contentPoints.height));
    if (fit <= 0) return NSZeroRect;
    NSSize size = NSMakeSize(contentPoints.width * fit + chrome.width,
                             contentPoints.height * fit + chrome.height);
    return NSMakeRect(round(NSMidX(visible) - size.width / 2),
                      round(NSMidY(visible) - size.height / 2), size.width, size.height);
}

static BOOL PJDVIsDocumentWindow(NSWindow *window) {
    return window && window.screen && ![window isKindOfClass:NSPanel.class] &&
        !window.parentWindow && !window.sheetParent && window.level == NSNormalWindowLevel &&
        (window.styleMask & NSWindowStyleMaskResizable);
}

static NSSize PJDVCommonLimit(NSSize a, NSSize b) {
    return NSMakeSize(MIN(a.width, b.width), MIN(a.height, b.height));
}

static NSSize PJDVUnknownDisplayLimit(NSSize desktop) {
    NSSize conservative = desktop.height > desktop.width ? NSMakeSize(720, 1280) : NSMakeSize(1280, 720);
    return desktop.width > 0 && desktop.height > 0 ? PJDVCommonLimit(conservative, desktop) : conservative;
}

static NSSize PJDVPanelLimit(CGDirectDisplayID display, NSSize logicalSize) {
    // Other Retina modes can render *above* the physical panel (supersampling).
    // Only modes identified as native by the display driver describe the panel.
    NSDictionary *options = @{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES};
    NSArray *modes = CFBridgingRelease(CGDisplayCopyAllDisplayModes(display, (__bridge CFDictionaryRef)options));
    BOOL quarterTurn = lround(CGDisplayRotation(display) / 90.0) % 2 != 0;
    NSSize limit = NSZeroSize;
    NSSize smallestMode = NSZeroSize;
    for (id object in modes) {
        CGDisplayModeRef mode = (__bridge CGDisplayModeRef)object;
        uint32_t flags = CGDisplayModeGetIOFlags(mode);
        if (!(flags & (kDisplayModeNativeFlag | kDisplayModeValidFlag))) continue;
        NSSize size = NSMakeSize(CGDisplayModeGetPixelWidth(mode), CGDisplayModeGetPixelHeight(mode));
        if (size.width <= 0 || size.height <= 0) continue;
        // Some drivers expose already-rotated modes. Orient the output once.
        if (quarterTurn && (logicalSize.width == logicalSize.height ||
            ((logicalSize.height > logicalSize.width) != (size.height > size.width)))) {
            size = NSMakeSize(size.height, size.width);
        }
        if (flags & kDisplayModeNativeFlag) {
            limit = limit.width > 0 ? PJDVCommonLimit(limit, size) : size;
        }
        smallestMode = smallestMode.width > 0 ? PJDVCommonLimit(smallestMode, size) : size;
    }
    if (limit.width > 0) return limit;
    if (smallestMode.width > 0) return PJDVCommonLimit(smallestMode, PJDVUnknownDisplayLimit(logicalSize));
    return NSMakeSize(1, 1);
}

static CGDirectDisplayID PJDVMirrorPrimary(CGDirectDisplayID display) {
    CGDirectDisplayID primary = CGDisplayMirrorsDisplay(display);
    return primary ?: CGDisplayPrimaryDisplay(display);
}

static NSSize PJDVDisplayPixelLimit(CGDirectDisplayID display, NSSize desktop) {
    if (!display) return NSMakeSize(1, 1);
    NSSize limit = PJDVPanelLimit(display, desktop);
    if (!CGDisplayIsInMirrorSet(display) && !CGDisplayIsInHWMirrorSet(display)) return limit;
    // Mirrored followers may be online yet inactive and absent from NSScreen.screens.
    uint32_t count = 0, actual = 0;
    if (CGGetOnlineDisplayList(0, NULL, &count) != kCGErrorSuccess || !count) {
        return NSMakeSize(1, 1);
    }
    NSMutableData *storage = [NSMutableData dataWithLength:(count + 1ULL) * sizeof(CGDirectDisplayID)];
    CGDirectDisplayID *online = storage.mutableBytes;
    CGDirectDisplayID primary = PJDVMirrorPrimary(display);
    BOOL foundPeer = NO;
    if (CGGetOnlineDisplayList(count + 1, online, &actual) == kCGErrorSuccess && actual <= count) {
        for (uint32_t i = 0; i < actual; i++) {
            if (online[i] == display || PJDVMirrorPrimary(online[i]) != primary) continue;
            NSSize logical = CGDisplayBounds(online[i]).size;
            if (logical.width <= 0 || logical.height <= 0) logical = desktop;
            limit = PJDVCommonLimit(limit, PJDVPanelLimit(online[i], logical));
            foundPeer = YES;
        }
    }
    return foundPeer ? limit : NSMakeSize(1, 1);
}

// UIWindowScene.systemFrame and Quartz both use a top-left origin on the main
// display. Preserve ties for a window spanning screens exactly equally.
static NSArray<NSScreen *> *PJDVScreensForFrame(CGRect frame) {
    NSMutableArray<NSScreen *> *screens = [NSMutableArray array];
    CGFloat largest = 0;
    for (NSScreen *screen in NSScreen.screens) {
        CGDirectDisplayID display = [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
        CGRect intersection = CGRectIntersection(frame, CGDisplayBounds(display));
        if (CGRectIsEmpty(intersection)) continue;
        CGFloat area = intersection.size.width * intersection.size.height;
        if (area < largest) continue;
        if (area > largest) [screens removeAllObjects];
        [screens addObject:screen];
        largest = area;
    }
    return screens;
}

static BOOL PJDVWindowMatchesSystemFrame(NSWindow *window, CGRect systemFrame) {
    NSRect f = window.frame;
    CGFloat y = CGRectGetMaxY(CGDisplayBounds(CGMainDisplayID())) - NSMaxY(f);
    return fabs(NSMinX(f) - CGRectGetMinX(systemFrame)) < 1 && fabs(y - CGRectGetMinY(systemFrame)) < 1 &&
           fabs(NSWidth(f) - CGRectGetWidth(systemFrame)) < 1 && fabs(NSHeight(f) - CGRectGetHeight(systemFrame)) < 1;
}

@implementation PJDVMacLifecycle
+ (void)configureLaunchWindow {
    NSAssert(NSThread.isMainThread, @"Window sizing must run on the main thread");
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        __block id mainObserver = nil;
        __block id restoreObserver = nil;
        __block BOOL restored = NO;
        void (^apply)(NSWindow *) = ^(NSWindow *preferred) {
            if (!restored || !mainObserver) return;
            NSWindow *window = preferred;
            if (!PJDVIsDocumentWindow(window)) {
                for (NSWindow *candidate in NSApp.orderedWindows) {
                    if (PJDVIsDocumentWindow(candidate)) { window = candidate; break; }
                }
            }
            if (!PJDVIsDocumentWindow(window)) return;
            [center removeObserver:mainObserver];
            mainObserver = nil;
            if (window.styleMask & NSWindowStyleMaskFullScreen) return;
            NSRect layout = window.contentLayoutRect;
            NSSize chrome = NSMakeSize(NSWidth(window.frame) - NSWidth(layout), NSHeight(window.frame) - NSHeight(layout));
            // AppKit window frames are in points. Convert using this window's
            // backing space so a 2x screen gets a 960 x 540 point content area.
            NSSize contentPoints = [window convertRectFromBacking:NSMakeRect(0, 0, 1920, 1080)].size;
            NSRect frame = PJDVLaunchFrame(window.screen.visibleFrame, chrome, contentPoints);
            if (!NSIsEmptyRect(frame)) [window setFrame:frame display:YES];
        };
        // Launch Services may restore the old frame after the UIKit scene has
        // appeared. Wait for AppKit's completion before sizing the first window.
        mainObserver = [center addObserverForName:NSWindowDidBecomeMainNotification object:nil
                                           queue:nil usingBlock:^(NSNotification *note) { apply(note.object); }];
        restoreObserver = [center addObserverForName:NSApplicationDidFinishRestoringWindowsNotification object:nil
                                              queue:nil usingBlock:^(NSNotification *note) {
            [center removeObserver:restoreObserver];
            restoreObserver = nil;
            restored = YES;
            dispatch_async(dispatch_get_main_queue(), ^{ apply(NSApp.mainWindow); });
        }];
    });
}

+ (NSDictionary *)displaySnapshot {
    return [self displaySnapshotForSystemFrame:CGRectZero];
}

+ (NSDictionary *)displaySnapshotForSystemFrame:(CGRect)frame {
    NSAssert(NSThread.isMainThread, @"Display queries must run on the main thread");
    static dispatch_once_t once;
    static NSMutableArray *observers;
    static NSMutableDictionary<NSNumber *, NSValue *> *displayLimits;
    dispatch_once(&once, ^{
        observers = [NSMutableArray array];
        displayLimits = [NSMutableDictionary dictionary];
        for (NSNotificationName name in @[NSWindowDidChangeScreenNotification, NSWindowDidChangeBackingPropertiesNotification, NSApplicationDidChangeScreenParametersNotification]) {
            [observers addObject:[NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                [displayLimits removeAllObjects];
                [NSNotificationCenter.defaultCenter postNotificationName:@"PJDVHostDisplayDidChange" object:nil];
            }]];
        }
    });
    BOOL hasFrame = !CGRectIsEmpty(frame) && !CGRectIsInfinite(frame) &&
        isfinite(frame.origin.x) && isfinite(frame.origin.y) && isfinite(frame.size.width) && isfinite(frame.size.height);
    NSMutableOrderedSet<NSScreen *> *screens = [NSMutableOrderedSet orderedSet];
    if (hasFrame) [screens addObjectsFromArray:PJDVScreensForFrame(frame)];
    NSWindow *onlyWindow = nil;
    NSUInteger matches = 0;
    for (NSWindow *window in NSApp.windows) {
        if (!PJDVIsDocumentWindow(window)) continue;
        if (hasFrame) {
            if (!PJDVWindowMatchesSystemFrame(window, frame)) continue;
        } else {
            [screens addObject:window.screen];
        }
        onlyWindow = window;
        matches++;
    }
    // Older Catalyst versions cannot identify the game's scene in AppKit.
    // Bound the drawable by every possible screen regardless of keyboard focus.
    if (!hasFrame && !screens.count) [screens addObjectsFromArray:NSScreen.screens];
    if (!screens.count) return @{};
    NSSize desktop = NSZeroSize, panel = NSZeroSize;
    for (NSScreen *screen in screens) {
        NSNumber *displayID = screen.deviceDescription[@"NSScreenNumber"] ?: @0;
        NSValue *limit = displayLimits[displayID];
        if (!limit) {
            limit = [NSValue valueWithSize:PJDVDisplayPixelLimit(displayID.unsignedIntValue, screen.frame.size)];
            displayLimits[displayID] = limit;
        }
        NSSize backing = [screen convertRectToBacking:screen.frame].size;
        desktop = desktop.width > 0 ? PJDVCommonLimit(desktop, backing) : backing;
        panel = panel.width > 0 ? PJDVCommonLimit(panel, limit.sizeValue) : limit.sizeValue;
    }
    NSSize content = NSZeroSize;
    if (matches == 1 && [screens containsObject:onlyWindow.screen]) {
        content = [onlyWindow convertRectToBacking:onlyWindow.contentLayoutRect].size;
    } else if (hasFrame && screens.count == 1) {
        content.width = NSWidth([screens.firstObject convertRectToBacking:frame]);
    }
    return @{@"desktopWidth":@(desktop.width), @"desktopHeight":@(desktop.height),
             @"physicalWidth":@(panel.width), @"physicalHeight":@(panel.height),
             @"contentWidth":@(content.width), @"contentHeight":@(content.height)};
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
