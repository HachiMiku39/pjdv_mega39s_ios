#import <AppKit/AppKit.h>
@protocol PJDVMacTermination
+ (void)terminateApplication;
@end
@protocol PJDVMacFileSelection
+ (void)chooseLocalItemWithTitle:(NSString *)title directory:(BOOL)directory
                     completion:(void (^)(NSURL * _Nullable))completion;
@end
@interface PJDVMacLifecycle : NSObject <PJDVMacTermination, PJDVMacFileSelection>
+ (void)terminateApplication;
@end
@implementation PJDVMacLifecycle
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
