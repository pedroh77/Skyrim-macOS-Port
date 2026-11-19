#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <GameController/GameController.h>
#import <CommonCrypto/CommonDigest.h>
#import "FNVSurface.h"
#import "FNVPad.h"
#include "FNVDisplay.h"
#include <IOKit/graphics/IOGraphicsTypes.h>
#ifndef FNV_PROBE
#include "FNVNativeMedia.h"
#endif
#include "input.h"
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <unistd.h>

extern void fnv_display_configure_scaled(unsigned native_w, unsigned native_h, unsigned scale_pct);
extern unsigned fnv_output_width(void);
extern unsigned fnv_output_height(void);
extern void fnv_display_set_refresh(int hz);
extern void fnv_graphics_configure(int upscaler, int aa);

static CAMetalLayer *screenLayer;
static CGSize lockedDrawableSize;

@interface FNVMetalView : NSView
@end
@implementation FNVMetalView
- (CALayer *)makeBackingLayer { return [CAMetalLayer layer]; }
- (BOOL)wantsUpdateLayer { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (void)applyLockedDrawableSize {
    if (lockedDrawableSize.width > 0 && lockedDrawableSize.height > 0 &&
        [self.layer isKindOfClass:[CAMetalLayer class]]) {
        CAMetalLayer *ml = (CAMetalLayer *)self.layer;
        if (!CGSizeEqualToSize(ml.drawableSize, lockedDrawableSize)) {
            ml.drawableSize = lockedDrawableSize;
        }
    }
}
- (void)layout {
    [super layout];
    [self applyLockedDrawableSize];
}
- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self applyLockedDrawableSize];
}
- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    [self applyLockedDrawableSize];
}
@end
static NSWindow *mainWindow;
static pthread_mutex_t activeLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t activeChanged = PTHREAD_COND_INITIALIZER;
static BOOL active = YES;

static void setActive(BOOL value) {
    pthread_mutex_lock(&activeLock);
    active = value;
    pthread_cond_broadcast(&activeChanged);
    pthread_mutex_unlock(&activeLock);
}

void fnv_wait_active(void) {
    pthread_mutex_lock(&activeLock);
    while (!active) pthread_cond_wait(&activeChanged, &activeLock);
    pthread_mutex_unlock(&activeLock);
}

static void onMain(dispatch_block_t work) {
    if (NSThread.isMainThread) work();
    else dispatch_sync(dispatch_get_main_queue(), work);
}

CAMetalLayer *fnv_surface(id<MTLDevice> device, CGSize size) {
    onMain(^{
        lockedDrawableSize = size;
        screenLayer.device = device;
        screenLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        screenLayer.framebufferOnly = NO;
        screenLayer.drawableSize = size;
        screenLayer.contentsGravity = kCAGravityResizeAspect;
        screenLayer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
        screenLayer.displaySyncEnabled = getenv("FNV_NOVSYNC") ? NO : YES;
        screenLayer.maximumDrawableCount = 3;
    });
    return screenLayer;
}

void fnv_resize_surface(CGSize size) {
    onMain(^{
        lockedDrawableSize = size;
        screenLayer.drawableSize = size;
    });
}

// Query the physical panel pixel dimensions for the target NSScreen even when
// macOS uses a scaled HiDPI backing buffer (e.g. 1440x900@2x = 2880x1800 on
// a 2560x1600 physical Retina panel). Supports SKYRIM_OUTPUT_WIDTH/HEIGHT.
static void detectPhysicalDisplayPixels(NSScreen *screen,
                                        unsigned *outPanelW, unsigned *outPanelH,
                                        unsigned *outBackingW, unsigned *outBackingH) {
    CGFloat scale = screen ? screen.backingScaleFactor : 2.0;
    NSRect screenFrame = screen ? screen.frame : NSMakeRect(0, 0, 1280, 720);
    unsigned backW = (unsigned)llround(screenFrame.size.width * scale);
    unsigned backH = (unsigned)llround(screenFrame.size.height * scale);
    if (backW < 640) backW = 1280;
    if (backH < 480) backH = 720;

    unsigned panelW = backW;
    unsigned panelH = backH;

    if (screen) {
        NSNumber *num = screen.deviceDescription[@"NSScreenNumber"];
        CGDirectDisplayID did = num ? (CGDirectDisplayID)num.unsignedIntValue : CGMainDisplayID();
        double curAspect = 0.0;
        CGDisplayModeRef curMode = CGDisplayCopyDisplayMode(did);
        if (curMode) {
            size_t cw = CGDisplayModeGetPixelWidth(curMode);
            size_t ch = CGDisplayModeGetPixelHeight(curMode);
            if (cw >= 640 && ch >= 480) curAspect = (double)cw / (double)ch;
            CGDisplayModeRelease(curMode);
        }

        NSDictionary *opts = @{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES};
        CFArrayRef modes = CGDisplayCopyAllDisplayModes(did, (__bridge CFDictionaryRef)opts);
        if (modes) {
            uint64_t bestAspectPixels = 0;
            unsigned bestAspectW = 0, bestAspectH = 0;
            uint64_t bestAnyPixels = 0;
            unsigned bestAnyW = 0, bestAnyH = 0;

            CFIndex count = CFArrayGetCount(modes);
            for (CFIndex i = 0; i < count; i++) {
                CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
                if (!m || !(CGDisplayModeGetIOFlags(m) & kDisplayModeNativeFlag)) continue;
                size_t pw = CGDisplayModeGetPixelWidth(m);
                size_t ph = CGDisplayModeGetPixelHeight(m);
                if (pw < 640 || ph < 480 || pw > 16384 || ph > 16384) continue;
                uint64_t pixels = (uint64_t)pw * (uint64_t)ph;
                if (pixels > bestAnyPixels) {
                    bestAnyPixels = pixels;
                    bestAnyW = (unsigned)pw;
                    bestAnyH = (unsigned)ph;
                }
                if (curAspect > 0.0) {
                    double ma = (double)pw / (double)ph;
                    if (fabs(ma - curAspect) <= 0.05 && pixels > bestAspectPixels) {
                        bestAspectPixels = pixels;
                        bestAspectW = (unsigned)pw;
                        bestAspectH = (unsigned)ph;
                    }
                }
            }
            CFRelease(modes);

            if (bestAspectW > 0 && bestAspectH > 0) {
                panelW = bestAspectW;
                panelH = bestAspectH;
            } else if (bestAnyW > 0 && bestAnyH > 0) {
                panelW = bestAnyW;
                panelH = bestAnyH;
            }
        }
    }

    const char *envW = getenv("SKYRIM_OUTPUT_WIDTH");
    const char *envH = getenv("SKYRIM_OUTPUT_HEIGHT");
    if (envW && envH) {
        unsigned ow = (unsigned)strtoul(envW, NULL, 10);
        unsigned oh = (unsigned)strtoul(envH, NULL, 10);
        if (ow >= 640 && ow <= 16384 && oh >= 480 && oh <= 16384) {
            panelW = ow;
            panelH = oh;
        }
    }

    if (outPanelW) *outPanelW = panelW;
    if (outPanelH) *outPanelH = panelH;
    if (outBackingW) *outBackingW = backW;
    if (outBackingH) *outBackingH = backH;
}

// macOS virtual key code -> DirectInput scancode (DIK_*)
static const uint8_t mac2dik[128] = {
    [0x00] = 0x1E, [0x01] = 0x1F, [0x02] = 0x20, [0x03] = 0x21, [0x04] = 0x23, [0x05] = 0x22, [0x06] = 0x2C, [0x07] = 0x2D,
    [0x08] = 0x2E, [0x09] = 0x2F, [0x0B] = 0x30, [0x0C] = 0x10, [0x0D] = 0x11, [0x0E] = 0x12, [0x0F] = 0x13, [0x10] = 0x15,
    [0x11] = 0x14, [0x12] = 0x02, [0x13] = 0x03, [0x14] = 0x04, [0x15] = 0x05, [0x16] = 0x07, [0x17] = 0x06, [0x18] = 0x0D,
    [0x19] = 0x0A, [0x1A] = 0x08, [0x1B] = 0x0C, [0x1C] = 0x09, [0x1D] = 0x0B, [0x1E] = 0x1B, [0x1F] = 0x18, [0x20] = 0x16,
    [0x21] = 0x1A, [0x22] = 0x17, [0x23] = 0x19, [0x24] = 0x1C, [0x25] = 0x26, [0x26] = 0x24, [0x27] = 0x28, [0x28] = 0x25,
    [0x29] = 0x27, [0x2A] = 0x2B, [0x2B] = 0x33, [0x2C] = 0x35, [0x2D] = 0x31, [0x2E] = 0x32, [0x2F] = 0x34, [0x30] = 0x0F,
    [0x31] = 0x39, [0x32] = 0x29, [0x33] = 0x0E, [0x35] = 0x01, [0x37] = 0xDB, [0x38] = 0x2A, [0x39] = 0x3A, [0x3A] = 0x38,
    [0x3B] = 0x1D, [0x3C] = 0x36, [0x3D] = 0xB8, [0x3E] = 0x9D, [0x41] = 0x53, [0x43] = 0x37, [0x45] = 0x4E, [0x4B] = 0xB5,
    [0x4C] = 0x9C, [0x4E] = 0x4A, [0x52] = 0x52, [0x53] = 0x4F, [0x54] = 0x50, [0x55] = 0x51, [0x56] = 0x4B, [0x57] = 0x4C,
    [0x58] = 0x4D, [0x59] = 0x47, [0x5B] = 0x48, [0x5C] = 0x49, [0x60] = 0x3F, [0x61] = 0x40, [0x62] = 0x41, [0x63] = 0x3D,
    [0x64] = 0x42, [0x65] = 0x43, [0x67] = 0x57, [0x6D] = 0x44, [0x6F] = 0x58, [0x72] = 0xD2, [0x73] = 0xC7, [0x74] = 0xC9,
    [0x75] = 0xD3, [0x76] = 0x3E, [0x77] = 0xCF, [0x78] = 0x3C, [0x79] = 0xD1, [0x7A] = 0x3B, [0x7B] = 0xCB, [0x7C] = 0xCD,
    [0x7D] = 0xD0, [0x7E] = 0xC8,
};

#ifndef FNV_PROBE
static NSString *const kPrefRenderScale = @"SkyrimRenderScale";
static NSString *const kPrefUpscaler = @"SkyrimUpscaler";
static NSString *const kPrefAntiAliasing = @"SkyrimAntiAliasing";
static NSString *const kPrefShadowQuality = @"SkyrimShadowQuality";
static NSString *const kPrefFullscreen = @"SkyrimFullscreen";
static NSString *const kPrefMouseAccel = @"SkyrimMouseAcceleration";
static NSString *const kPrefSkipLauncher = @"SkyrimSkipLauncher";

typedef struct {
    unsigned renderScale;
    int upscaler;
    int antiAliasing;
    int shadowQuality;
    BOOL fullscreen;
    BOOL mouseAcceleration;
    BOOL skipLauncher;
} SkyrimOptions;

static unsigned clampScale(long v) {
    if (v < 50) return 50;
    if (v > 100) return 100;
    return (unsigned)v;
}

static SkyrimOptions loadOptions(unsigned nativeW) {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    SkyrimOptions opts;
    unsigned defScale = (nativeW >= 2000u) ? 75u : 100u;
    id sObj = [ud objectForKey:kPrefRenderScale];
    opts.renderScale = sObj ? clampScale([sObj integerValue]) : defScale;
    id uObj = [ud objectForKey:kPrefUpscaler];
    opts.upscaler = uObj ? ([uObj integerValue] ? 1 : 0) : 1;
    id aObj = [ud objectForKey:kPrefAntiAliasing];
    opts.antiAliasing = aObj ? (int)[aObj integerValue] : 0;
    if (opts.antiAliasing < 0 || opts.antiAliasing > 2) opts.antiAliasing = 0;
    id shObj = [ud objectForKey:kPrefShadowQuality];
    opts.shadowQuality = shObj ? (int)[shObj integerValue] : 0;
    if (opts.shadowQuality < 0 || opts.shadowQuality > 3) opts.shadowQuality = 0;
    id fsObj = [ud objectForKey:kPrefFullscreen];
    opts.fullscreen = fsObj ? [fsObj boolValue] : YES;
    id maObj = [ud objectForKey:kPrefMouseAccel];
    opts.mouseAcceleration = maObj ? [maObj boolValue] : NO;
    id skObj = [ud objectForKey:kPrefSkipLauncher];
    opts.skipLauncher = skObj ? [skObj boolValue] : NO;

    const char *envScale = getenv("SKYRIM_RENDER_SCALE");
    if (envScale && envScale[0]) opts.renderScale = clampScale(strtol(envScale, NULL, 10));
    const char *envUp = getenv("SKYRIM_UPSCALER");
    if (envUp && envUp[0]) {
        if (!strcasecmp(envUp, "bilinear") || !strcmp(envUp, "0")) opts.upscaler = 0;
        else if (!strcasecmp(envUp, "metalfx") || !strcasecmp(envUp, "metalfx-spatial") || !strcmp(envUp, "1")) opts.upscaler = 1;
    }
    const char *envAA = getenv("SKYRIM_AA");
    if (envAA && envAA[0]) {
        if (!strcasecmp(envAA, "smaa") || !strcmp(envAA, "1")) opts.antiAliasing = 1;
        else if (!strcasecmp(envAA, "fxaa") || !strcmp(envAA, "2")) opts.antiAliasing = 2;
        else if (!strcasecmp(envAA, "off") || !strcasecmp(envAA, "none") || !strcmp(envAA, "0")) opts.antiAliasing = 0;
    }
    const char *envSh = getenv("SKYRIM_SHADOWS");
    if (envSh && envSh[0]) {
        if (!strcasecmp(envSh, "low") || !strcmp(envSh, "1")) opts.shadowQuality = 1;
        else if (!strcasecmp(envSh, "medium") || !strcmp(envSh, "2")) opts.shadowQuality = 2;
        else if (!strcasecmp(envSh, "high") || !strcmp(envSh, "3")) opts.shadowQuality = 3;
        else if (!strcasecmp(envSh, "keep") || !strcmp(envSh, "0")) opts.shadowQuality = 0;
    }
    const char *envMA = getenv("SKYRIM_MOUSE_ACCEL");
    if (envMA && envMA[0]) opts.mouseAcceleration = (atoi(envMA) != 0);
    if (getenv("FNV_WINDOWED")) opts.fullscreen = NO;
    return opts;
}

static void saveOptions(SkyrimOptions opts) {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    [ud setInteger:(NSInteger)opts.renderScale forKey:kPrefRenderScale];
    [ud setInteger:opts.upscaler forKey:kPrefUpscaler];
    [ud setInteger:opts.antiAliasing forKey:kPrefAntiAliasing];
    [ud setInteger:opts.shadowQuality forKey:kPrefShadowQuality];
    [ud setBool:opts.fullscreen forKey:kPrefFullscreen];
    [ud setBool:opts.mouseAcceleration forKey:kPrefMouseAccel];
    [ud setBool:opts.skipLauncher forKey:kPrefSkipLauncher];
    [ud synchronize];
}

static NSString *exeHash(NSURL *url) {
    NSInputStream *stream = [NSInputStream inputStreamWithURL:url];
    CC_SHA256_CTX hash;
    CC_SHA256_Init(&hash);
    [stream open];
    uint8_t buffer[16384];
    NSInteger n;
    while ((n = [stream read:buffer maxLength:sizeof buffer]) > 0)
        CC_SHA256_Update(&hash, buffer, (CC_LONG)n);
    [stream close];
    if (n < 0) return nil;
    uint8_t bytes[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(bytes, &hash);
    NSMutableString *result = [NSMutableString string];
    for (size_t i = 0; i < sizeof bytes; ++i) [result appendFormat:@"%02x", bytes[i]];
    return result;
}
#endif

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) FNVMetalView *metalView;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSTimer *padTimer;
@property (nonatomic) BOOL cursorCaptured;
@property (nonatomic) double mouseAccumX;
@property (nonatomic) double mouseAccumY;
@property (nonatomic) id eventMonitor;
#ifndef FNV_PROBE
@property (nonatomic, strong) NSWindow *optionsWindow;
@property (nonatomic, strong) NSPopUpButton *scalePopup;
@property (nonatomic, strong) NSPopUpButton *upscalerPopup;
@property (nonatomic, strong) NSPopUpButton *aaPopup;
@property (nonatomic, strong) NSPopUpButton *shadowPopup;
@property (nonatomic, strong) NSPopUpButton *displayPopup;
@property (nonatomic, strong) NSButton *mouseAccelCheck;
@property (nonatomic, strong) NSButton *skipLauncherCheck;
@property (nonatomic, strong) NSTextField *resPreviewLabel;
@property (nonatomic) unsigned nativeW;
@property (nonatomic) unsigned nativeH;
@property (nonatomic) unsigned backingW;
@property (nonatomic) unsigned backingH;
@property (nonatomic) CGFloat screenScale;
@property (nonatomic) int refreshHz;
@property (nonatomic, strong) NSURL *logDir;
@property (nonatomic, strong) NSURL *logURL;
@property (nonatomic) BOOL gameLaunched;
#endif
@end

@implementation AppDelegate

- (void)setupMenus {
    NSMenu *bar = [NSMenu new];
    NSMenuItem *appMenuItem = [NSMenuItem new];
    [bar addItem:appMenuItem];

    NSMenu *appMenu = [NSMenu new];
    NSString *title = @"The Elder Scrolls V: Skyrim";
    [appMenu addItemWithTitle:[@"About " stringByAppendingString:title]
                       action:@selector(orderFrontStandardAboutPanel:)
                keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:[@"Hide " stringByAppendingString:title]
                       action:@selector(hide:)
                keyEquivalent:@"h"];
#ifndef FNV_PROBE
    [appMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *optItem = [appMenu addItemWithTitle:@"Show Options on Next Launch"
                                             action:@selector(enableOptionsOnNextLaunch:)
                                      keyEquivalent:@""];
    optItem.target = self;
#endif
    NSMenuItem *quitItem = [appMenu addItemWithTitle:[@"Quit " stringByAppendingString:title]
                                              action:@selector(terminate:)
                                       keyEquivalent:@"q"];
    quitItem.target = NSApp;
    appMenuItem.submenu = appMenu;

    NSMenuItem *viewMenuItem = [NSMenuItem new];
    [bar addItem:viewMenuItem];
    NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
    NSMenuItem *fsItem = [viewMenu addItemWithTitle:@"Toggle Full Screen"
                                             action:@selector(toggleFullScreen:)
                                      keyEquivalent:@"f"];
    fsItem.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagCommand;
    viewMenuItem.submenu = viewMenu;

    NSApp.mainMenu = bar;
}

- (void)setCursorCapture:(BOOL)capture {
    if (_cursorCaptured == capture) return;
    _cursorCaptured = capture;
    _mouseAccumX = 0.0;
    _mouseAccumY = 0.0;
    CGAssociateMouseAndMouseCursorPosition(!capture);
    if (capture) {
        [NSCursor hide];
    } else {
        [NSCursor unhide];
    }
}

- (void)releaseAllInputs {
    _mouseAccumX = 0.0;
    _mouseAccumY = 0.0;
    for (int i = 0; i < 8; ++i) input_mouse_button(i, 0);
    for (int dik = 1; dik < 256; ++dik) input_key(dik, 0);
    fnv_pad_reset();
}

- (void)handleEvent:(NSEvent *)e {
    switch (e.type) {
    case NSEventTypeKeyDown:
    case NSEventTypeKeyUp: {
        if (e.modifierFlags & NSEventModifierFlagCommand) return;
        if (e.keyCode < 128 && mac2dik[e.keyCode]) {
            input_key(mac2dik[e.keyCode], e.type == NSEventTypeKeyDown);
        }
        return;
    }
    case NSEventTypeFlagsChanged: {
        NSEventModifierFlags f = e.modifierFlags;
        input_key(0x2A, (f & NSEventModifierFlagShift) != 0);
        input_key(0x1D, (f & NSEventModifierFlagControl) != 0);
        input_key(0x38, (f & NSEventModifierFlagOption) != 0);
        input_key(0x3A, (f & NSEventModifierFlagCapsLock) != 0);
        return;
    }
    case NSEventTypeMouseMoved:
    case NSEventTypeLeftMouseDragged:
    case NSEventTypeRightMouseDragged:
    case NSEventTypeOtherMouseDragged:
        if (_cursorCaptured) {
            _mouseAccumX += (double)e.deltaX;
            _mouseAccumY += (double)e.deltaY;
            int dx = (int)trunc(_mouseAccumX);
            int dy = (int)trunc(_mouseAccumY);
            if (dx != 0 || dy != 0) {
                _mouseAccumX -= (double)dx;
                _mouseAccumY -= (double)dy;
                input_mouse_move(dx, dy);
            }
        }
        return;
    case NSEventTypeLeftMouseDown:
        if (!_cursorCaptured && self.window.isKeyWindow) [self setCursorCapture:YES];
        input_mouse_button(0, 1);
        return;
    case NSEventTypeLeftMouseUp:
        input_mouse_button(0, 0);
        return;
    case NSEventTypeRightMouseDown:
        input_mouse_button(1, 1);
        return;
    case NSEventTypeRightMouseUp:
        input_mouse_button(1, 0);
        return;
    case NSEventTypeOtherMouseDown:
        input_mouse_button((int)e.buttonNumber, 1);
        return;
    case NSEventTypeOtherMouseUp:
        input_mouse_button((int)e.buttonNumber, 0);
        return;
    case NSEventTypeScrollWheel: {
        CGFloat dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY * 10.0 : e.scrollingDeltaY * 120.0;
        input_mouse_wheel((int)lround(dy));
        return;
    }
    default:
        return;
    }
}

- (void)pollControllers {
    GCExtendedGamepad *pad = nil;
    for (GCController *controller in GCController.controllers) {
        if (controller.extendedGamepad) {
            pad = controller.extendedGamepad;
            break;
        }
    }
    FNVPadState state = {0};
    if (pad) {
        state.lx = (int16_t)lround(pad.leftThumbstick.xAxis.value * 32767.0);
        state.ly = (int16_t)lround(pad.leftThumbstick.yAxis.value * 32767.0);
        state.rx = (int16_t)lround(pad.rightThumbstick.xAxis.value * 32767.0);
        state.ry = (int16_t)lround(pad.rightThumbstick.yAxis.value * 32767.0);
        state.left_trigger = (uint8_t)lround(pad.leftTrigger.value * 255.0);
        state.right_trigger = (uint8_t)lround(pad.rightTrigger.value * 255.0);
        if (pad.dpad.up.isPressed) state.buttons |= 0x0001;
        if (pad.dpad.down.isPressed) state.buttons |= 0x0002;
        if (pad.dpad.left.isPressed) state.buttons |= 0x0004;
        if (pad.dpad.right.isPressed) state.buttons |= 0x0008;
        if (pad.buttonMenu.isPressed) state.buttons |= 0x0010;
        if (pad.buttonOptions.isPressed) state.buttons |= 0x0020;
        if (pad.leftThumbstickButton.isPressed) state.buttons |= 0x0040;
        if (pad.rightThumbstickButton.isPressed) state.buttons |= 0x0080;
        if (pad.leftShoulder.isPressed) state.buttons |= 0x0100;
        if (pad.rightShoulder.isPressed) state.buttons |= 0x0200;
        if (pad.buttonA.isPressed) state.buttons |= 0x1000;
        if (pad.buttonB.isPressed) state.buttons |= 0x2000;
        if (pad.buttonX.isPressed) state.buttons |= 0x4000;
        if (pad.buttonY.isPressed) state.buttons |= 0x8000;
    }
    fnv_pad_physical_state(&state, pad != nil);
}

- (void)showStatus:(NSString *)message {
    self.statusLabel.stringValue = message ?: @"";
    self.statusLabel.hidden = (message == nil || message.length == 0);
}

#ifndef FNV_PROBE
- (void)enableOptionsOnNextLaunch:(id)sender {
    (void)sender;
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:kPrefSkipLauncher];
    [NSUserDefaults.standardUserDefaults synchronize];
}

- (unsigned)selectedRenderScale {
    NSInteger tag = self.scalePopup.selectedItem.tag;
    return tag > 0 ? clampScale(tag) : 100u;
}

- (void)updateOptionsPreview {
    unsigned pct = [self selectedRenderScale];
    unsigned ow = ((self.nativeW / 2u) * 2u); if (ow < 640u) ow = 640u;
    unsigned oh = ((self.nativeH / 2u) * 2u); if (oh < 480u) oh = 480u;
    unsigned rw = ((ow * pct / 100u) / 2u) * 2u; if (rw < 640u) rw = 640u; if (rw > ow) rw = ow;
    unsigned rh = ((oh * pct / 100u) / 2u) * 2u; if (rh < 480u) rh = 480u; if (rh > oh) rh = oh;
    if (pct == 100u) {
        self.resPreviewLabel.stringValue = [NSString stringWithFormat:@"Internal: %ux%u (native, upscaler bypassed)", rw, rh];
        self.upscalerPopup.enabled = NO;
    } else {
        self.resPreviewLabel.stringValue = [NSString stringWithFormat:@"Internal: %ux%u -> Output: %ux%u", rw, rh, ow, oh];
        self.upscalerPopup.enabled = YES;
    }
}

- (void)scaleChanged:(id)sender {
    (void)sender;
    [self updateOptionsPreview];
}

- (void)quitClicked:(id)sender {
    (void)sender;
    [NSApp terminate:nil];
}

- (void)playClicked:(id)sender {
    (void)sender;
    SkyrimOptions opts;
    opts.renderScale = [self selectedRenderScale];
    opts.upscaler = (int)self.upscalerPopup.selectedItem.tag;
    opts.antiAliasing = (int)self.aaPopup.selectedItem.tag;
    opts.shadowQuality = (int)self.shadowPopup.selectedItem.tag;
    opts.fullscreen = (self.displayPopup.selectedItem.tag != 0);
    opts.mouseAcceleration = (self.mouseAccelCheck.state != NSControlStateValueOn);
    opts.skipLauncher = (self.skipLauncherCheck.state == NSControlStateValueOn);
    saveOptions(opts);
    // Re-apply env overrides if caller explicitly passed them
    SkyrimOptions launchOpts = loadOptions(self.nativeW);
    launchOpts.renderScale = getenv("SKYRIM_RENDER_SCALE") ? launchOpts.renderScale : opts.renderScale;
    launchOpts.upscaler = getenv("SKYRIM_UPSCALER") ? launchOpts.upscaler : opts.upscaler;
    launchOpts.antiAliasing = getenv("SKYRIM_AA") ? launchOpts.antiAliasing : opts.antiAliasing;
    launchOpts.shadowQuality = getenv("SKYRIM_SHADOWS") ? launchOpts.shadowQuality : opts.shadowQuality;
    launchOpts.fullscreen = getenv("FNV_WINDOWED") ? NO : opts.fullscreen;
    launchOpts.mouseAcceleration = getenv("SKYRIM_MOUSE_ACCEL") ? launchOpts.mouseAcceleration : opts.mouseAcceleration;
    [self launchWithOptions:launchOpts];
}

- (void)showOptionsWindow:(SkyrimOptions)opts {
    NSRect rect = NSMakeRect(0, 0, 480, 390);
    self.optionsWindow = [[NSWindow alloc] initWithContentRect:rect
                                                     styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                                       backing:NSBackingStoreBuffered
                                                         defer:NO];
    self.optionsWindow.title = @"The Elder Scrolls V: Skyrim — Options";
    self.optionsWindow.delegate = self;
    // ARC owns this window through the strong property. Leaving the AppKit default
    // (releasedWhenClosed = YES) makes -close release a window ARC still owns, which
    // leaves a dangling window in the autorelease pool and crashes on the next drain.
    self.optionsWindow.releasedWhenClosed = NO;
    NSView *cv = self.optionsWindow.contentView;

    NSTextField *title = [NSTextField labelWithString:@"Graphics & Input Options"];
    title.font = [NSFont boldSystemFontOfSize:15];
    title.frame = NSMakeRect(24, 354, 432, 22);
    [cv addSubview:title];

    NSString *dispStr = (self.backingW != self.nativeW || self.backingH != self.nativeH)
        ? [NSString stringWithFormat:@"Display: %ux%u panel (desktop %ux%u) @ %d Hz",
           self.nativeW, self.nativeH, self.backingW, self.backingH, self.refreshHz]
        : [NSString stringWithFormat:@"Display: %ux%u @ %d Hz",
           self.nativeW, self.nativeH, self.refreshHz];
    NSTextField *sub = [NSTextField labelWithString:dispStr];
    sub.font = [NSFont systemFontOfSize:12];
    sub.textColor = NSColor.secondaryLabelColor;
    sub.frame = NSMakeRect(24, 334, 432, 16);
    [cv addSubview:sub];

    NSBox *sep1 = [[NSBox alloc] initWithFrame:NSMakeRect(24, 322, 432, 1)];
    sep1.boxType = NSBoxSeparator;
    [cv addSubview:sep1];

    NSTextField *(^mkLabel)(NSString *, CGFloat) = ^NSTextField *(NSString *txt, CGFloat y) {
        NSTextField *l = [NSTextField labelWithString:txt];
        l.alignment = NSTextAlignmentRight;
        l.frame = NSMakeRect(24, y, 160, 20);
        [cv addSubview:l];
        return l;
    };
    NSPopUpButton *(^mkPopup)(CGFloat) = ^NSPopUpButton *(CGFloat y) {
        NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(196, y, 260, 26) pullsDown:NO];
        [cv addSubview:p];
        return p;
    };

    mkLabel(@"Render Scale:", 286);
    self.scalePopup = mkPopup(284);
    struct { NSString *label; NSInteger tag; } scaleItems[] = {
        {@"100% (Native)", 100}, {@"85% (Quality)", 85}, {@"75% (Recommended)", 75},
        {@"67% (Balanced)", 67}, {@"50% (Performance)", 50},
    };
    for (size_t i = 0; i < sizeof scaleItems / sizeof scaleItems[0]; i++) {
        [self.scalePopup addItemWithTitle:scaleItems[i].label];
        self.scalePopup.lastItem.tag = scaleItems[i].tag;
    }
    if (![self.scalePopup selectItemWithTag:(NSInteger)opts.renderScale]) {
        NSString *custom = [NSString stringWithFormat:@"%u%% (Custom)", opts.renderScale];
        [self.scalePopup addItemWithTitle:custom];
        self.scalePopup.lastItem.tag = (NSInteger)opts.renderScale;
        [self.scalePopup selectItemWithTag:(NSInteger)opts.renderScale];
    }
    self.scalePopup.target = self;
    self.scalePopup.action = @selector(scaleChanged:);

    self.resPreviewLabel = [NSTextField labelWithString:@""];
    self.resPreviewLabel.font = [NSFont systemFontOfSize:11];
    self.resPreviewLabel.textColor = NSColor.secondaryLabelColor;
    self.resPreviewLabel.frame = NSMakeRect(198, 264, 258, 16);
    [cv addSubview:self.resPreviewLabel];

    mkLabel(@"Upscaler:", 232);
    self.upscalerPopup = mkPopup(230);
    [self.upscalerPopup addItemWithTitle:@"MetalFX Spatial"]; self.upscalerPopup.lastItem.tag = 1;
    [self.upscalerPopup addItemWithTitle:@"Bilinear"]; self.upscalerPopup.lastItem.tag = 0;
    [self.upscalerPopup selectItemWithTag:opts.upscaler];

    mkLabel(@"Anti-Aliasing:", 198);
    self.aaPopup = mkPopup(196);
    [self.aaPopup addItemWithTitle:@"Off"]; self.aaPopup.lastItem.tag = 0;
    [self.aaPopup addItemWithTitle:@"SMAA (Post-Process)"]; self.aaPopup.lastItem.tag = 1;
    [self.aaPopup addItemWithTitle:@"FXAA (Fast, Post-Process)"]; self.aaPopup.lastItem.tag = 2;
    [self.aaPopup selectItemWithTag:opts.antiAliasing];

    mkLabel(@"Shadow Quality:", 164);
    self.shadowPopup = mkPopup(162);
    [self.shadowPopup addItemWithTitle:@"Keep SkyrimPrefs.ini"]; self.shadowPopup.lastItem.tag = 0;
    [self.shadowPopup addItemWithTitle:@"Low (512)"]; self.shadowPopup.lastItem.tag = 1;
    [self.shadowPopup addItemWithTitle:@"Medium (1024)"]; self.shadowPopup.lastItem.tag = 2;
    [self.shadowPopup addItemWithTitle:@"High (2048)"]; self.shadowPopup.lastItem.tag = 3;
    [self.shadowPopup selectItemWithTag:opts.shadowQuality];

    mkLabel(@"Display Mode:", 130);
    self.displayPopup = mkPopup(128);
    [self.displayPopup addItemWithTitle:@"Fullscreen"]; self.displayPopup.lastItem.tag = 1;
    [self.displayPopup addItemWithTitle:@"Windowed"]; self.displayPopup.lastItem.tag = 0;
    [self.displayPopup selectItemWithTag:opts.fullscreen ? 1 : 0];

    self.mouseAccelCheck = [NSButton checkboxWithTitle:@"Disable in-game mouse acceleration (smoother trackpad/mouse)"
                                                target:nil action:nil];
    self.mouseAccelCheck.frame = NSMakeRect(24, 96, 432, 18);
    self.mouseAccelCheck.state = opts.mouseAcceleration ? NSControlStateValueOff : NSControlStateValueOn;
    [cv addSubview:self.mouseAccelCheck];

    self.skipLauncherCheck = [NSButton checkboxWithTitle:@"Skip this window on next launch (hold Option ⌥ to reopen)"
                                                  target:nil action:nil];
    self.skipLauncherCheck.frame = NSMakeRect(24, 72, 432, 18);
    self.skipLauncherCheck.state = opts.skipLauncher ? NSControlStateValueOn : NSControlStateValueOff;
    [cv addSubview:self.skipLauncherCheck];

    NSBox *sep2 = [[NSBox alloc] initWithFrame:NSMakeRect(24, 56, 432, 1)];
    sep2.boxType = NSBoxSeparator;
    [cv addSubview:sep2];

    NSButton *quitBtn = [NSButton buttonWithTitle:@"Quit" target:self action:@selector(quitClicked:)];
    quitBtn.frame = NSMakeRect(276, 16, 88, 30);
    [cv addSubview:quitBtn];

    NSButton *playBtn = [NSButton buttonWithTitle:@"Play" target:self action:@selector(playClicked:)];
    playBtn.frame = NSMakeRect(372, 16, 84, 30);
    playBtn.keyEquivalent = @"\r";
    [cv addSubview:playBtn];

    [self updateOptionsPreview];
    [self.optionsWindow center];
    [self.optionsWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}
#endif

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    (void)note;
    struct rlimit rl;
    if (getrlimit(RLIMIT_NOFILE, &rl) == 0 && rl.rlim_cur < 4096) {
        rl.rlim_cur = (rl.rlim_max == RLIM_INFINITY || rl.rlim_max >= 4096) ? 4096 : rl.rlim_max;
        setrlimit(RLIMIT_NOFILE, &rl);
    }
    [self setupMenus];

    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *libURL = [fm URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *logDir = [libURL URLByAppendingPathComponent:@"Logs/Skyrim" isDirectory:YES];
    [fm createDirectoryAtURL:logDir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSURL *logURL = [logDir URLByAppendingPathComponent:@"skyrim.log"];
    if (!getenv("FNV_STDERR") && !isatty(STDERR_FILENO)) {
        freopen(logURL.fileSystemRepresentation, "w", stderr);
        setvbuf(stderr, NULL, _IONBF, 0);
    }

    NSString *revision = [NSBundle.mainBundle objectForInfoDictionaryKey:@"FNVBuildSourceCommit"] ?: @"unknown";
    NSString *buildVersion = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown";
    fprintf(stderr, "[build] source=%s version=%s\n", revision.UTF8String, buildVersion.UTF8String);

    NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    CGFloat scale = screen ? screen.backingScaleFactor : 2.0;
    NSRect screenFrame = screen ? screen.frame : NSMakeRect(0, 0, 1280, 720);
    (void)screenFrame;
    unsigned nativeW = 0, nativeH = 0, backingW = 0, backingH = 0;
    detectPhysicalDisplayPixels(screen, &nativeW, &nativeH, &backingW, &backingH);
    (void)backingW;
    (void)backingH;
    int hz = (screen && [screen respondsToSelector:@selector(maximumFramesPerSecond)]) ? (int)screen.maximumFramesPerSecond : 60;
    if (hz <= 0) hz = 60;
    fnv_display_set_refresh(hz);

#ifdef FNV_PROBE
    fnv_display_configure(nativeW, nativeH);
    fnv_graphics_configure(0, 0);
    [self createAndRunWindowWithFullscreen:(getenv("FNV_WINDOWED") == NULL) scale:scale screen:screen
                                  onFinish:^(BOOL ok) { (void)ok; }];
    [self showStatus:@"Input / Metal Probe — Move mouse for R/G, W/S or controller for Blue. Cmd+Q to quit."];
#else
    if (backingW != nativeW || backingH != nativeH) {
        fprintf(stderr, "[display] physical panel %ux%u (desktop backing %ux%u)\n",
                nativeW, nativeH, backingW, backingH);
    }
    self.nativeW = nativeW;
    self.nativeH = nativeH;
    self.backingW = backingW;
    self.backingH = backingH;
    self.screenScale = scale;
    self.refreshHz = hz;
    self.logDir = logDir;
    self.logURL = logURL;

    SkyrimOptions opts = loadOptions(nativeW);
    const char *headlessEnv = getenv("FNV_HEADLESS");
    BOOL isHeadless = (headlessEnv && headlessEnv[0] && headlessEnv[0] != '0');
    BOOL optionHeld = (NSEvent.modifierFlags & NSEventModifierFlagOption) != 0;
    if (!isHeadless && !getenv("SKYRIM_SKIP_LAUNCHER") && (!opts.skipLauncher || optionHeld)) {
        [self showOptionsWindow:opts];
        return;
    }
    [self launchWithOptions:opts];
#endif
}

#ifdef FNV_PROBE
- (void)createAndRunWindowWithFullscreen:(BOOL)fullscreen scale:(CGFloat)scale screen:(NSScreen *)screen onFinish:(void(^)(BOOL))done {
    (void)done;
    NSRect vis = screen ? screen.visibleFrame : NSMakeRect(0, 0, 1280, 720);
    unsigned outW = fnv_output_width() ?: fnv_display_width();
    unsigned outH = fnv_output_height() ?: fnv_display_height();
    CGFloat w = outW / scale;
    CGFloat h = outH / scale;
    CGFloat fit = MIN(0.88, MIN(vis.size.width / w, (vis.size.height - 28.0) / h));
    NSRect winRect = NSMakeRect(0, 0, floor(w * fit), floor(h * fit));

    NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                              NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    self.window = [[NSWindow alloc] initWithContentRect:winRect
                                              styleMask:style
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    self.window.title = @"The Elder Scrolls V: Skyrim";
    self.window.delegate = self;
    self.window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    self.window.backgroundColor = NSColor.blackColor;

    self.metalView = [[FNVMetalView alloc] initWithFrame:winRect];
    self.metalView.wantsLayer = YES;
    self.metalView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.window.contentView = self.metalView;
    screenLayer = (CAMetalLayer *)self.metalView.layer;
    screenLayer.contentsScale = scale;

    self.statusLabel = [NSTextField labelWithString:@""];
    self.statusLabel.textColor = NSColor.whiteColor;
    self.statusLabel.backgroundColor = [NSColor.blackColor colorWithAlphaComponent:0.7];
    self.statusLabel.drawsBackground = YES;
    self.statusLabel.font = [NSFont systemFontOfSize:14];
    self.statusLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.hidden = YES;
    [self.metalView addSubview:self.statusLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.metalView.leadingAnchor constant:16],
        [self.statusLabel.topAnchor constraintEqualToAnchor:self.metalView.topAnchor constant:16],
        [self.statusLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.metalView.trailingAnchor constant:-16],
    ]];

    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:self.metalView];
    [NSApp activateIgnoringOtherApps:YES];
    const char *headlessEnv = getenv("FNV_HEADLESS");
    BOOL isHeadless = (headlessEnv && headlessEnv[0] && headlessEnv[0] != '0');
    if (fullscreen && !isHeadless) {
        [self.window toggleFullScreen:nil];
    }

    __weak typeof(self) weakSelf = self;
    self.eventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:
        (NSEventMaskKeyDown | NSEventMaskKeyUp | NSEventMaskFlagsChanged |
         NSEventMaskMouseMoved | NSEventMaskLeftMouseDragged | NSEventMaskRightMouseDragged | NSEventMaskOtherMouseDragged |
         NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp | NSEventMaskRightMouseDown | NSEventMaskRightMouseUp |
         NSEventMaskOtherMouseDown | NSEventMaskOtherMouseUp | NSEventMaskScrollWheel)
        handler:^NSEvent *(NSEvent *event) {
            AppDelegate *strongSelf = weakSelf;
            if (!strongSelf) return event;
            if (event.window == strongSelf.window || event.type == NSEventTypeFlagsChanged) {
                if (strongSelf.window.isKeyWindow) {
                    [strongSelf handleEvent:event];
                    if ((event.type == NSEventTypeKeyDown || event.type == NSEventTypeKeyUp) &&
                        !(event.modifierFlags & NSEventModifierFlagCommand)) {
                        return nil; // suppress system beep for game keys
                    }
                }
            }
            return event;
        }];

    [GCController startWirelessControllerDiscoveryWithCompletionHandler:nil];
    [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidConnectNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) { (void)n; [weakSelf pollControllers]; }];
    [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidDisconnectNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) { (void)n; [weakSelf pollControllers]; }];
    self.padTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 120.0
                                                     repeats:YES
                                                       block:^(NSTimer *t) { (void)t; [weakSelf pollControllers]; }];
    [self pollControllers];

    [self setCursorCapture:YES];
    NSThread *thread = [[NSThread alloc] initWithBlock:^{
        @autoreleasepool {
            fnv_wait_active();
            extern int fnv_probe(unsigned);
            (void)fnv_probe(0);
        }
    }];
    thread.stackSize = 16 * 1024 * 1024;
    [thread start];
}
#else
- (void)launchWithOptions:(SkyrimOptions)opts {
    fnv_display_configure_scaled(self.nativeW, self.nativeH, opts.renderScale);
    fnv_graphics_configure(opts.upscaler, opts.antiAliasing);

    NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    CGFloat scale = self.screenScale ?: 2.0;
    NSRect vis = screen ? screen.visibleFrame : NSMakeRect(0, 0, 1280, 720);
    unsigned outW = fnv_output_width() ?: fnv_display_width();
    unsigned outH = fnv_output_height() ?: fnv_display_height();
    CGFloat w = outW / scale;
    CGFloat h = outH / scale;
    CGFloat fit = MIN(0.88, MIN(vis.size.width / w, (vis.size.height - 28.0) / h));
    NSRect winRect = NSMakeRect(0, 0, floor(w * fit), floor(h * fit));

    NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                              NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    self.window = [[NSWindow alloc] initWithContentRect:winRect
                                              styleMask:style
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    self.window.title = @"The Elder Scrolls V: Skyrim";
    self.window.delegate = self;
    self.window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    self.window.backgroundColor = NSColor.blackColor;

    self.metalView = [[FNVMetalView alloc] initWithFrame:winRect];
    self.metalView.wantsLayer = YES;
    self.metalView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.window.contentView = self.metalView;
    screenLayer = (CAMetalLayer *)self.metalView.layer;
    screenLayer.contentsScale = scale;

    self.statusLabel = [NSTextField labelWithString:@""];
    self.statusLabel.textColor = NSColor.whiteColor;
    self.statusLabel.backgroundColor = [NSColor.blackColor colorWithAlphaComponent:0.7];
    self.statusLabel.drawsBackground = YES;
    self.statusLabel.font = [NSFont systemFontOfSize:14];
    self.statusLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.hidden = YES;
    [self.metalView addSubview:self.statusLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.metalView.leadingAnchor constant:16],
        [self.statusLabel.topAnchor constraintEqualToAnchor:self.metalView.topAnchor constant:16],
        [self.statusLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.metalView.trailingAnchor constant:-16],
    ]];

    self.gameLaunched = YES;

    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:self.metalView];
    [NSApp activateIgnoringOtherApps:YES];

    // Show the game window before dismissing the options window (so AppKit never sees
    // the last visible window close and terminates the app), and keep the options
    // window alive until this button action has returned before releasing it.
    if (self.optionsWindow) {
        NSWindow *optionsWindow = self.optionsWindow;
        self.optionsWindow = nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            [optionsWindow close];
        });
    }
    const char *headlessEnv = getenv("FNV_HEADLESS");
    BOOL isHeadless = (headlessEnv && headlessEnv[0] && headlessEnv[0] != '0');
    if (opts.fullscreen && !isHeadless) {
        [self.window toggleFullScreen:nil];
    }

    __weak typeof(self) weakSelf = self;
    self.eventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:
        (NSEventMaskKeyDown | NSEventMaskKeyUp | NSEventMaskFlagsChanged |
         NSEventMaskMouseMoved | NSEventMaskLeftMouseDragged | NSEventMaskRightMouseDragged | NSEventMaskOtherMouseDragged |
         NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp | NSEventMaskRightMouseDown | NSEventMaskRightMouseUp |
         NSEventMaskOtherMouseDown | NSEventMaskOtherMouseUp | NSEventMaskScrollWheel)
        handler:^NSEvent *(NSEvent *event) {
            AppDelegate *strongSelf = weakSelf;
            if (!strongSelf) return event;
            if (event.window == strongSelf.window || event.type == NSEventTypeFlagsChanged) {
                if (strongSelf.window.isKeyWindow) {
                    [strongSelf handleEvent:event];
                    if ((event.type == NSEventTypeKeyDown || event.type == NSEventTypeKeyUp) &&
                        !(event.modifierFlags & NSEventModifierFlagCommand)) {
                        return nil; // suppress system beep for game keys
                    }
                }
            }
            return event;
        }];

    [GCController startWirelessControllerDiscoveryWithCompletionHandler:nil];
    [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidConnectNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) { (void)n; [weakSelf pollControllers]; }];
    [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidDisconnectNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) { (void)n; [weakSelf pollControllers]; }];
    self.padTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 120.0
                                                     repeats:YES
                                                       block:^(NSTimer *t) { (void)t; [weakSelf pollControllers]; }];
    [self pollControllers];

    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *appSupport = [fm URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    const char *envUserDir = getenv("SKYRIM_USER_DIR");
    if (!envUserDir || !envUserDir[0]) envUserDir = getenv("FNV_USER_DIR");
    NSURL *userDir = (envUserDir && envUserDir[0])
        ? [NSURL fileURLWithPath:@(envUserDir) isDirectory:YES]
        : [appSupport URLByAppendingPathComponent:@"Skyrim/UserDocuments" isDirectory:YES];
    [fm createDirectoryAtURL:userDir withIntermediateDirectories:YES attributes:nil error:NULL];
    setenv("SKYRIM_USER_DIR", userDir.fileSystemRepresentation, 1);
    setenv("FNV_USER_DIR", userDir.fileSystemRepresentation, 1);

    NSURL *root = nil;
    const char *envRoot = getenv("SKYRIM_ROOT");
    if (!envRoot || !envRoot[0]) envRoot = getenv("FNV_ROOT");
    if (envRoot && envRoot[0]) {
        root = [NSURL fileURLWithPath:@(envRoot) isDirectory:YES];
    } else {
        NSURL *bundleGameData = [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"GameData" isDirectory:YES];
        if ([fm fileExistsAtPath:[bundleGameData URLByAppendingPathComponent:@"Data/Skyrim.esm"].path] &&
            [fm fileExistsAtPath:[bundleGameData URLByAppendingPathComponent:@"TESV.exe"].path]) {
            root = bundleGameData;
        } else {
            root = [NSURL fileURLWithPath:fm.currentDirectoryPath isDirectory:YES];
        }
    }

    NSURL *exe = [root URLByAppendingPathComponent:@"TESV.exe"];
    if (![fm fileExistsAtPath:[root URLByAppendingPathComponent:@"Data/Skyrim.esm"].path] ||
        ![fm fileExistsAtPath:exe.path]) {
        [self showStatus:[NSString stringWithFormat:@"Missing game files. Expected TESV.exe and Data/Skyrim.esm in:\n%@", root.path]];
        return;
    }
    if (chdir(root.fileSystemRepresentation)) {
        [self showStatus:@"Could not open the game directory."];
        return;
    }

    NSString *expected = [NSBundle.mainBundle objectForInfoDictionaryKey:@"FNVExecutableSHA256"];
    if (expected.length > 0 && ![expected isEqualToString:exeHash(exe)]) {
        [self showStatus:@"TESV.exe does not match this build."];
        return;
    }

    setenv("SKYRIM_ROOT", root.fileSystemRepresentation, 1);
    setenv("FNV_ROOT", root.fileSystemRepresentation, 1);
    setenv("FNV_FALLBACK_LOG", [self.logDir URLByAppendingPathComponent:@"fallback_entries.txt"].fileSystemRepresentation, 1);

    // Ensure LocalAppData/Skyrim/plugins.txt exists so official masters/DLCs load without SkyrimLauncher.
    NSString *localSkyrimDir = [userDir.path stringByAppendingPathComponent:@"LocalAppData/Skyrim"];
    [fm createDirectoryAtPath:localSkyrimDir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *pluginsTxt = [localSkyrimDir stringByAppendingPathComponent:@"plugins.txt"];
    if (![fm fileExistsAtPath:pluginsTxt]) {
        NSMutableArray<NSString *> *plugins = [NSMutableArray array];
        NSArray<NSString *> *knownOrder = @[
            @"Skyrim.esm", @"Update.esm", @"Dawnguard.esm", @"HearthFires.esm", @"Dragonborn.esm",
            @"HighResTexturePack01.esp", @"HighResTexturePack02.esp", @"HighResTexturePack03.esp",
        ];
        NSString *dataDir = [root URLByAppendingPathComponent:@"Data"].path;
        for (NSString *p in knownOrder) {
            if ([fm fileExistsAtPath:[dataDir stringByAppendingPathComponent:p]]) [plugins addObject:p];
        }
        if (plugins.count > 0) {
            [[[plugins componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"]
                writeToFile:pluginsTxt atomically:YES encoding:NSISOLatin1StringEncoding error:NULL];
        }
    }

    // Update display/controller keys in SkyrimPrefs.ini while preserving all other user settings.
    NSString *myGamesDir = [userDir.path stringByAppendingPathComponent:@"My Games/Skyrim"];
    [fm createDirectoryAtPath:myGamesDir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *prefs = [myGamesDir stringByAppendingPathComponent:@"SkyrimPrefs.ini"];
    for (NSString *leaf in [fm contentsOfDirectoryAtPath:myGamesDir error:NULL]) {
        if ([leaf caseInsensitiveCompare:@"SkyrimPrefs.ini"] == NSOrderedSame) {
            prefs = [myGamesDir stringByAppendingPathComponent:leaf];
            break;
        }
    }
    if (![fm fileExistsAtPath:prefs]) {
        NSString *defaultPrefs = [root URLByAppendingPathComponent:@"Skyrim/SkyrimPrefs.ini"].path;
        if ([fm fileExistsAtPath:defaultPrefs]) [fm copyItemAtPath:defaultPrefs toPath:prefs error:NULL];
    }
    NSString *skyrimIni = [myGamesDir stringByAppendingPathComponent:@"Skyrim.ini"];
    if (![fm fileExistsAtPath:skyrimIni]) {
        NSString *defaultIni = [root URLByAppendingPathComponent:@"Skyrim_default.ini"].path;
        if ([fm fileExistsAtPath:defaultIni]) [fm copyItemAtPath:defaultIni toPath:skyrimIni error:NULL];
    }
    NSString *text = [NSString stringWithContentsOfFile:prefs encoding:NSISOLatin1StringEncoding error:NULL] ?: @"";
    if ([fm fileExistsAtPath:prefs] && ![fm fileExistsAtPath:[prefs stringByAppendingString:@".before-native-display"]]) {
        [fm copyItemAtPath:prefs toPath:[prefs stringByAppendingString:@".before-native-display"] error:NULL];
    }
    NSMutableArray<NSString *> *lines = [[text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] mutableCopy];
    NSMutableDictionary *displaySettings = [@{
        @"isize w": @[@"iSize W", @(fnv_display_width())],
        @"isize h": @[@"iSize H", @(fnv_display_height())],
        @"bfull screen": @[@"bFull Screen", @1],
        @"sd3ddevice": @[@"sD3DDevice", @(fnv_display_adapter_description())],
    } mutableCopy];
    if (opts.shadowQuality == 1) {
        displaySettings[@"ishadowmapresolution"] = @[@"iShadowMapResolution", @512];
        displaySettings[@"ishadowmapresolutionprimary"] = @[@"iShadowMapResolutionPrimary", @512];
        displaySettings[@"ishadowmapresolutionsecondary"] = @[@"iShadowMapResolutionSecondary", @512];
        displaySettings[@"iblurdeferredshadowmask"] = @[@"iBlurDeferredShadowMask", @2];
        displaySettings[@"fshadowdistance"] = @[@"fShadowDistance", @"1500.0000"];
    } else if (opts.shadowQuality == 2) {
        displaySettings[@"ishadowmapresolution"] = @[@"iShadowMapResolution", @1024];
        displaySettings[@"ishadowmapresolutionprimary"] = @[@"iShadowMapResolutionPrimary", @1024];
        displaySettings[@"ishadowmapresolutionsecondary"] = @[@"iShadowMapResolutionSecondary", @512];
        displaySettings[@"iblurdeferredshadowmask"] = @[@"iBlurDeferredShadowMask", @3];
        displaySettings[@"fshadowdistance"] = @[@"fShadowDistance", @"2500.0000"];
    } else if (opts.shadowQuality == 3) {
        displaySettings[@"ishadowmapresolution"] = @[@"iShadowMapResolution", @2048];
        displaySettings[@"ishadowmapresolutionprimary"] = @[@"iShadowMapResolutionPrimary", @2048];
        displaySettings[@"ishadowmapresolutionsecondary"] = @[@"iShadowMapResolutionSecondary", @1024];
        displaySettings[@"iblurdeferredshadowmask"] = @[@"iBlurDeferredShadowMask", @5];
        displaySettings[@"fshadowdistance"] = @[@"fShadowDistance", @"4000.0000"];
    }
    NSDictionary *settings = @{
        @"display": displaySettings,
        @"main": @{
            @"bgamepadenable": @[@"bGamepadEnable", @1],
        },
        @"controls": @{
            @"bmouseacceleration": @[@"bMouseAcceleration", opts.mouseAcceleration ? @1 : @0],
        },
    };
    for (NSString *section in settings) {
        NSDictionary *keys = settings[section];
        NSMutableSet *pending = [NSMutableSet setWithArray:keys.allKeys];
        BOOL inside = NO;
        NSInteger insert = -1;
        for (NSUInteger i = 0; i < lines.count; i++) {
            NSString *line = [lines[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if ([line hasPrefix:@"["] && [line hasSuffix:@"]"]) {
                if (inside && insert < 0) insert = (NSInteger)i;
                inside = [[[line substringWithRange:NSMakeRange(1, line.length - 2)] lowercaseString] isEqualToString:section];
            } else if (inside) {
                NSRange equal = [line rangeOfString:@"="];
                if (equal.location != NSNotFound) {
                    NSString *key = [[[line substringToIndex:equal.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] lowercaseString];
                    NSArray *value = keys[key];
                    if (value) {
                        lines[i] = [NSString stringWithFormat:@"%@=%@", value[0], value[1]];
                        [pending removeObject:key];
                    }
                }
            }
        }
        if (insert < 0) {
            insert = (NSInteger)lines.count;
            if (!inside) {
                [lines addObject:[NSString stringWithFormat:@"[%@]", section]];
                insert++;
            }
        }
        for (NSString *key in pending) {
            NSArray *value = keys[key];
            [lines insertObject:[NSString stringWithFormat:@"%@=%@", value[0], value[1]] atIndex:(NSUInteger)insert++];
        }
    }
    [fm createDirectoryAtPath:prefs.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
    NSError *prefsError = nil;
    BOOL prefsOK = [[lines componentsJoinedByString:@"\n"] writeToFile:prefs atomically:YES encoding:NSISOLatin1StringEncoding error:&prefsError];
    fprintf(stderr, "[display] render %ux%u -> output %ux%u (%u%%) @ %dHz; upscaler=%s; aa=%s; mouse_accel=%d; user=%s; preferences=%s\n",
            fnv_display_width(), fnv_display_height(), outW, outH, opts.renderScale, self.refreshHz,
            opts.upscaler == 1 ? "metalfx" : "bilinear",
            opts.antiAliasing == 1 ? "smaa" : (opts.antiAliasing == 2 ? "fxaa" : "off"),
            opts.mouseAcceleration ? 1 : 0,
            userDir.fileSystemRepresentation,
            prefsOK ? "written" : prefsError.localizedDescription.UTF8String);

    fnv_audio_start();

    [self setCursorCapture:YES];

    NSURL *errLogURL = self.logURL;
    NSThread *thread = [[NSThread alloc] initWithBlock:^{
        @autoreleasepool {
            fnv_wait_active();
            extern int fnv_run_game(int, char **);
            char *argv[] = {"skyrim-macos", "TESV.exe", NULL};
            int rc = fnv_run_game(2, argv);
            __block NSString *failureDetail = nil;
            if (rc) {
                NSString *diagnostic = [NSString stringWithContentsOfURL:errLogURL encoding:NSUTF8StringEncoding error:NULL];
                [diagnostic enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
                    if ([line hasPrefix:@"[host] TRAP"]) { failureDetail = line; *stop = YES; }
                }];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                [self setCursorCapture:NO];
                if (rc == 0) {
                    [NSApp terminate:nil];
                } else {
                    [self showStatus:failureDetail ?: [NSString stringWithFormat:@"Host returned %d. See %@.", rc, errLogURL.path]];
                }
            });
        }
    }];
    thread.stackSize = 16 * 1024 * 1024;
    [thread start];
}
#endif

- (void)windowWillClose:(NSNotification *)notification {
#ifndef FNV_PROBE
    if (notification.object == self.optionsWindow && !self.gameLaunched) {
        [NSApp terminate:nil];
    }
#else
    (void)notification;
#endif
}

- (void)windowDidBecomeKey:(NSNotification *)notification {
    if (notification.object != self.window) return;
    [self setCursorCapture:YES];
#ifndef FNV_PROBE
    fnv_media_active(1);
#endif
    setActive(YES);
}

- (void)windowDidResignKey:(NSNotification *)notification {
    if (notification.object != self.window) return;
    [self setCursorCapture:NO];
    [self releaseAllInputs];
}

- (void)applicationWillResignActive:(NSNotification *)notification {
    (void)notification;
    [self setCursorCapture:NO];
    [self releaseAllInputs];
#ifndef FNV_PROBE
    fnv_media_active(0);
#endif
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    (void)notification;
    if (self.window.isKeyWindow) [self setCursorCapture:YES];
#ifndef FNV_PROBE
    fnv_media_active(1);
#endif
    setActive(YES);
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self setCursorCapture:NO];
    if (self.eventMonitor) {
        [NSEvent removeMonitor:self.eventMonitor];
        self.eventMonitor = nil;
    }
}

@end

int main(int argc, char **argv) {
    (void)argc; (void)argv;
    @autoreleasepool {
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"ApplePersistenceIgnoreState"];
        [NSApplication sharedApplication];
        const char *headless = getenv("FNV_HEADLESS");
        [NSApp setActivationPolicy:(headless && headless[0] && headless[0] != '0')
            ? NSApplicationActivationPolicyProhibited
            : NSApplicationActivationPolicyRegular];
        AppDelegate *delegate = [AppDelegate new];
        NSApp.delegate = delegate;
        [NSApp run];
    }
    return 0;
}
