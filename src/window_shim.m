/* macOS window shim: a native window hosting a WKWebView on the app's
 * local page, plus the microphone-permission queries (AVFoundation). One
 * C file, a narrow extern ABI, no Objective-C types leaking into Zig.
 * nam_window_open runs the AppKit event loop on the calling (main)
 * thread and returns when the window closes or the user quits. */

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <AVFoundation/AVFoundation.h>

@interface NamWindowDelegate : NSObject <NSWindowDelegate>
@end

static void nam_stop_app(void) {
    [NSApp stop:nil];
    /* stop: takes effect after the current event; post one so the loop wakes. */
    NSEvent* wake = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                       location:NSZeroPoint
                                  modifierFlags:0
                                      timestamp:0
                                   windowNumber:0
                                        context:nil
                                        subtype:0
                                          data1:0
                                          data2:0];
    [NSApp postEvent:wake atStart:YES];
}

@implementation NamWindowDelegate
- (void)windowWillClose:(NSNotification*)notification {
    (void)notification;
    nam_stop_app();
}
- (void)quit:(id)sender {
    (void)sender;
    nam_stop_app();
}
@end

int nam_window_supported(void) {
    return 1;
}

/* Closes the window from any thread (the Quit button's request). */
void nam_window_close(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        nam_stop_app();
    });
}

int nam_window_open(const char* url, const char* title, int width, int height) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        NamWindowDelegate* delegate = [NamWindowDelegate new];

        NSMenu* bar = [NSMenu new];
        NSMenuItem* app_item = [NSMenuItem new];
        [bar addItem:app_item];
        NSMenu* app_menu = [NSMenu new];
        NSString* quit_title = [NSString stringWithFormat:@"Quit %@", [NSString stringWithUTF8String:title]];
        NSMenuItem* quit_item = [[NSMenuItem alloc] initWithTitle:quit_title action:@selector(quit:) keyEquivalent:@"q"];
        [quit_item setTarget:delegate];
        [app_menu addItem:quit_item];
        [app_item setSubmenu:app_menu];
        [NSApp setMainMenu:bar];

        NSRect frame = NSMakeRect(0, 0, width, height);
        NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                  NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
        NSWindow* window = [[NSWindow alloc] initWithContentRect:frame
                                                       styleMask:style
                                                         backing:NSBackingStoreBuffered
                                                           defer:NO];
        [window setTitle:[NSString stringWithUTF8String:title]];
        [window setDelegate:delegate];
        [window setMinSize:NSMakeSize(640, 480)];
        [window center];

        WKWebViewConfiguration* config = [WKWebViewConfiguration new];
        WKWebView* web = [[WKWebView alloc] initWithFrame:frame configuration:config];
        [web setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
        [window setContentView:web];
        NSURL* target = [NSURL URLWithString:[NSString stringWithUTF8String:url]];
        [web loadRequest:[NSURLRequest requestWithURL:target]];

        [window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        [NSApp run];
        [window setDelegate:nil];
        return 0;
    }
}

/* 0 = not determined (the prompt has not been shown yet), 1 = authorized,
 * 2 = denied or restricted. */
int nam_mic_status(void) {
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    switch (status) {
    case AVAuthorizationStatusAuthorized: return 1;
    case AVAuthorizationStatusNotDetermined: return 0;
    default: return 2;
    }
}

/* Shows the system prompt when the status is not determined and waits up to
 * timeout_ms for the answer; returns the resulting status (0 on timeout). */
int nam_mic_request(unsigned int timeout_ms) {
    if (nam_mic_status() != 0) return nam_mic_status();
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block int result = 0;
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
        result = granted ? 1 : 2;
        dispatch_semaphore_signal(done);
    }];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)timeout_ms * NSEC_PER_MSEC));
    return result;
}
