// Metal backend for the D3D9 layer (overrides the weak null backend).
//
// Model: every draw reads the guest-side D3D state (D3DState) and guest resources directly.
//  - textures/surfaces: one MTLTexture per guest surface/texture object, created on first use;
//    CPU-written levels are re-uploaded when marked dirty (Unlock / DDS load / UpdateSurface).
//  - vertex/index data: static buffers get their own MTLBuffer, re-created (not overwritten, so
//    in-flight frames keep the old contents) when the game unlocks them. D3DUSAGE_DYNAMIC buffers,
//    and static ones the game keeps rewriting, are copied per draw into a per-frame ring buffer.
//  - shaders: translated on first use by sm2msl; pipelines keyed by (vs, ps, vertex layout, render
//    target formats, blend state, sample count).
#import "FNVSurface.h"
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <QuartzCore/CAMetalLayer.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#include <pthread.h>
#include <time.h>
#include <math.h>
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include "d3d9_backend.h"
#include "host.h"
#include "sm2msl.h"
#include "input.h"

extern unsigned fnv_output_width(void);
extern unsigned fnv_output_height(void);
extern int fnv_display_refresh(void);
extern int fnv_graphics_upscaler(void);
extern int fnv_graphics_aa(void);

// ---- guest object layout (mirrors d3d9.c) ---------------------------------------------------------
#define OBJ_KIND(o) G32((o) + 8)
#define OBJ_F(o, i) ((o) + 16 + 4 * (i))
enum { K_TEX = 1, K_CUBE, K_VOL, K_SURF, K_VB, K_IB, K_DECL, K_VS, K_PS };
enum { S_W, S_H, S_FMT, S_USAGE, S_POOL, S_DATA, S_PITCH, S_CONT, S_MS, S_LEVEL, S_DIRTY, S_HOST };
enum { T_W, T_H, T_LEVELS, T_FMT, T_USAGE, T_POOL, T_SURFS, T_FACES, T_LOD, T_DIRTY, T_HOST };
enum { B_LEN, B_USAGE, B_FMT, B_POOL, B_DATA, B_HOST, B_DIRTY, B_UPS };
#define FCC(a, b, c_, d) ((uint32_t)(a) | ((uint32_t)(b) << 8) | ((uint32_t)(c_) << 16) | ((uint32_t)(d) << 24))

// ---- host-side state ------------------------------------------------------------------------------
static id<MTLDevice> dev;
static id<MTLCommandQueue> queue;
static CAMetalLayer *layer;

static id<MTLCommandBuffer> cmd;
static id<MTLRenderCommandEncoder> enc;
static uint32_t enc_rt[4], enc_ds;
static dispatch_semaphore_t inflight;
#ifdef FNV_PROBE
#define RING_SIZE (4u << 20)
#else
#define RING_SIZE (192u << 20)
#endif
static id<MTLBuffer> ring[3];
static uint32_t ring_idx, ring_off;
// ---- encoder state cache: skip Metal calls that would set what is already set in this encoder ----
static struct {
    __unsafe_unretained id pso, dss;
    int fixed_valid; uint32_t sref, cull, fill; float bias, slope; MTLViewport vp; MTLScissorRect sc; uint32_t bc;
    __unsafe_unretained id vbuf[32], fbuf[4]; NSUInteger voff[32], foff[4];
    int vb_valid[32], fb_valid[32];                 // set*Bytes slots: content below is current
    uint8_t vbytes[32][256], fbytes[4][256];
    __unsafe_unretained id ftex[16], fsamp[32], vtex[4], vsamp[4];
} ec;
static void ec_reset(void) { memset(&ec, 0, sizeof ec); }
static void ec_vbuf(id<MTLBuffer> b, NSUInteger off, int i) {
    if (ec.vbuf[i] == b) { if (ec.voff[i] != off) { [enc setVertexBufferOffset:off atIndex:i]; ec.voff[i] = off; } return; }
    [enc setVertexBuffer:b offset:off atIndex:i]; ec.vbuf[i] = b; ec.voff[i] = off; ec.vb_valid[i] = 0;
}
static void ec_fbuf(id<MTLBuffer> b, NSUInteger off, int i) {
    if (ec.fbuf[i] == b) { if (ec.foff[i] != off) { [enc setFragmentBufferOffset:off atIndex:i]; ec.foff[i] = off; } return; }
    [enc setFragmentBuffer:b offset:off atIndex:i]; ec.fbuf[i] = b; ec.foff[i] = off; ec.fb_valid[i] = 0;
}
static void ec_vbytes(const void *p, NSUInteger n, int i) {        // n <= 256
    if (ec.vb_valid[i] && !memcmp(ec.vbytes[i], p, n)) return;
    [enc setVertexBytes:p length:n atIndex:i]; memcpy(ec.vbytes[i], p, n); ec.vb_valid[i] = 1; ec.vbuf[i] = nil;
}
static void ec_fbytes(const void *p, NSUInteger n, int i) {        // i < 4, n <= 256
    if (ec.fb_valid[i] && !memcmp(ec.fbytes[i], p, n)) return;
    [enc setFragmentBytes:p length:n atIndex:i]; memcpy(ec.fbytes[i], p, n); ec.fb_valid[i] = 1; ec.fbuf[i] = nil;
}
// host objects live in a plain array; the guest object stores index+1 in its *_HOST field
// host objects: a plain table of +1-retained pointers; the guest object stores index+1 in its *_HOST
// field. Lookups return unretained pointers (no ARC traffic on the per-draw path).
static void **hostp; static uint32_t hostn, hostcap, *host_free, host_nfree, host_freecap;
static uint32_t host_field(uint32_t o) {
    uint32_t k = OBJ_KIND(o);
    if (k == K_TEX || k == K_CUBE) return OBJ_F(o, T_HOST);
    if (k == K_SURF) return OBJ_F(o, S_HOST);
    if (k == K_VB || k == K_IB) return OBJ_F(o, B_HOST);
    return OBJ_F(o, 2);                                       // shaders: code, ntok, host
}
static inline void *host_get(uint32_t o) { uint32_t i = G32(host_field(o)); return i ? hostp[i - 1] : NULL; }
static void host_set(uint32_t o, id v) {
    uint32_t i = G32(host_field(o));
    if (i) { if (hostp[i - 1]) CFRelease(hostp[i - 1]); hostp[i - 1] = (void *)CFBridgingRetain(v); return; }   // replace
    if (host_nfree) i = host_free[--host_nfree];
    else {
        if (hostn == hostcap) { hostcap = hostcap ? hostcap * 2 : 4096; hostp = realloc(hostp, sizeof *hostp * hostcap); }
        i = hostn++;
    }
    hostp[i] = (void *)CFBridgingRetain(v);
    P32(host_field(o), i + 1);
}
static void host_drop(uint32_t o) {
    uint32_t i = G32(host_field(o));
    if (!i) return;
    if (hostp[i - 1]) CFRelease(hostp[i - 1]);
    hostp[i - 1] = NULL;
    if (host_nfree == host_freecap) { host_freecap = host_freecap ? host_freecap * 2 : 4096; host_free = realloc(host_free, sizeof *host_free * host_freecap); }
    host_free[host_nfree++] = i - 1;
    P32(host_field(o), 0);
}

static uint64_t ff_skipped, draws_done;
static int trace_metal;
static pthread_mutex_t blk;
static pthread_once_t blk_once = PTHREAD_ONCE_INIT;
static void blk_init(void) { pthread_mutexattr_t a; pthread_mutexattr_init(&a); pthread_mutexattr_settype(&a, PTHREAD_MUTEX_RECURSIVE); pthread_mutex_init(&blk, &a); }
#define LOCKED_BEGIN pthread_once(&blk_once, blk_init); pthread_mutex_lock(&blk);
#define LOCKED_END pthread_mutex_unlock(&blk);

// ---- formats ----------------------------------------------------------------------------------------
typedef struct { MTLPixelFormat pf; MTLTextureSwizzleChannels sw; int has_sw; } Fmt;
static Fmt fmt_map(uint32_t f) {
    Fmt r = {MTLPixelFormatInvalid, MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleBlue, MTLTextureSwizzleAlpha), 0};
#define SW(a, b, c_, d) do { r.sw = MTLTextureSwizzleChannelsMake(MTLTextureSwizzle##a, MTLTextureSwizzle##b, MTLTextureSwizzle##c_, MTLTextureSwizzle##d); r.has_sw = 1; } while (0)
    switch (f) {
    case 20: r.pf = MTLPixelFormatBGRA8Unorm; SW(Red, Green, Blue, One); break;
    case 21: r.pf = MTLPixelFormatBGRA8Unorm; break;
    case 22: r.pf = MTLPixelFormatBGRA8Unorm; SW(Red, Green, Blue, One); break;
    case 32: r.pf = MTLPixelFormatRGBA8Unorm; break;
    case 33: r.pf = MTLPixelFormatRGBA8Unorm; SW(Red, Green, Blue, One); break;
    case 23: r.pf = MTLPixelFormatB5G6R5Unorm; break;
    case 25: r.pf = MTLPixelFormatA1BGR5Unorm; break;
    case 24: r.pf = MTLPixelFormatA1BGR5Unorm; SW(Red, Green, Blue, One); break;
    case 26: r.pf = MTLPixelFormatABGR4Unorm; SW(Green, Blue, Alpha, Red); break;
    case 28: r.pf = MTLPixelFormatA8Unorm; break;
    case 50: r.pf = MTLPixelFormatR8Unorm; SW(Red, Red, Red, One); break;
    case 51: r.pf = MTLPixelFormatRG8Unorm; SW(Red, Red, Red, Green); break;
    case 60: r.pf = MTLPixelFormatRG8Snorm; SW(Red, Green, One, One); break;
    case 34: r.pf = MTLPixelFormatRG16Unorm; SW(Red, Green, One, One); break;
    case 35: r.pf = MTLPixelFormatBGR10A2Unorm; break;
    case 31: r.pf = MTLPixelFormatRGB10A2Unorm; break;
    case 36: r.pf = MTLPixelFormatRGBA16Unorm; break;
    case 111: r.pf = MTLPixelFormatR16Float; SW(Red, One, One, One); break;
    case 112: r.pf = MTLPixelFormatRG16Float; SW(Red, Green, One, One); break;
    case 113: r.pf = MTLPixelFormatRGBA16Float; break;
    case 114: r.pf = MTLPixelFormatR32Float; SW(Red, One, One, One); break;
    case 115: r.pf = MTLPixelFormatRG32Float; SW(Red, Green, One, One); break;
    case 116: r.pf = MTLPixelFormatRGBA32Float; break;
    case 80: case 70: r.pf = MTLPixelFormatDepth16Unorm; break;
    case 75: case 77: case 71: r.pf = MTLPixelFormatDepth32Float_Stencil8; break;
    default:
        if (f == FCC('D', 'X', 'T', '1')) r.pf = MTLPixelFormatBC1_RGBA;
        else if (f == FCC('D', 'X', 'T', '2') || f == FCC('D', 'X', 'T', '3')) r.pf = MTLPixelFormatBC2_RGBA;
        else if (f == FCC('D', 'X', 'T', '4') || f == FCC('D', 'X', 'T', '5')) r.pf = MTLPixelFormatBC3_RGBA;
        else if (f == FCC('A', 'T', 'I', '1')) { r.pf = MTLPixelFormatBC4_RUnorm; SW(Red, Red, Red, One); }
        else if (f == FCC('A', 'T', 'I', '2')) { r.pf = MTLPixelFormatBC5_RGUnorm; SW(Green, Red, One, One); }   // ATI2 stores Y in the first block
        else if (f == FCC('I', 'N', 'T', 'Z')) r.pf = MTLPixelFormatDepth32Float_Stencil8;
        else if (f == FCC('N', 'U', 'L', 'L')) r.pf = MTLPixelFormatBGRA8Unorm;
        else r.pf = MTLPixelFormatBGRA8Unorm;
    }
#undef SW
    return r;
}
static int is_depth_fmt(uint32_t f) { return f == 80 || f == 70 || f == 75 || f == 77 || f == 71 || f == FCC('I', 'N', 'T', 'Z'); }

// ---- textures ---------------------------------------------------------------------------------------
@interface HTex : NSObject
@property(nonatomic, strong) id<MTLTexture> tex, view;   // view: swizzled / for sampling
@property(nonatomic) uint32_t fmt, w, h, levels, faces, ms;
@end
@implementation HTex
@end

static HTex *make_tex(uint32_t fmt, uint32_t w, uint32_t h, uint32_t levels, uint32_t faces, uint32_t ms, int rt) {
    Fmt f = fmt_map(fmt);
    if (f.pf == MTLPixelFormatInvalid) return nil;
    MTLTextureDescriptor *d = [MTLTextureDescriptor new];
    d.pixelFormat = f.pf; d.width = w ? w : 1; d.height = h ? h : 1; d.mipmapLevelCount = levels ? levels : 1;
    d.textureType = faces == 6 ? MTLTextureTypeCube : MTLTextureType2D;
    if (ms > 1 && faces == 1) { d.textureType = MTLTextureType2DMultisample; d.sampleCount = ms; d.mipmapLevelCount = 1; }
    d.usage = MTLTextureUsageShaderRead | (rt || is_depth_fmt(fmt) ? MTLTextureUsageRenderTarget : 0) | MTLTextureUsagePixelFormatView;
    d.storageMode = (rt || is_depth_fmt(fmt) || ms > 1) ? MTLStorageModePrivate : MTLStorageModeShared;
    HTex *t = [HTex new];
    t.tex = [dev newTextureWithDescriptor:d];
    t.fmt = fmt; t.w = w; t.h = h; t.levels = (uint32_t)d.mipmapLevelCount; t.faces = faces; t.ms = ms;
    t.view = f.has_sw && ms <= 1 ? [t.tex newTextureViewWithPixelFormat:f.pf textureType:d.textureType levels:NSMakeRange(0, t.levels)
                                                                slices:NSMakeRange(0, faces) swizzle:f.sw] : t.tex;
    return t;
}

static void upload_level(HTex *t, uint32_t surf, uint32_t face, uint32_t level) {
    if (t.tex.storageMode == MTLStorageModePrivate) return;           // GPU-written targets are not uploaded
    uint32_t w = G32(OBJ_F(surf, S_W)), h = G32(OBJ_F(surf, S_H)), pitch = G32(OBJ_F(surf, S_PITCH));
    int blk = d3d_fmt_block(t.fmt);
    uint32_t rows = blk ? (h + 3) / 4 : h;
    const uint8_t *bytes = d3d_surf_begin(surf);
    if (bytes) {
        if (t.fmt == 20) {
            uint32_t dpitch = w * 4;
            uint8_t *tmp = malloc((size_t)dpitch * h);
            if (tmp) {
                for (uint32_t y = 0; y < h; y++) {
                    const uint8_t *sr = bytes + (size_t)y * pitch;
                    uint8_t *dr = tmp + (size_t)y * dpitch;
                    for (uint32_t x = 0; x < w; x++) {
                        dr[x * 4 + 0] = sr[x * 3 + 0];
                        dr[x * 4 + 1] = sr[x * 3 + 1];
                        dr[x * 4 + 2] = sr[x * 3 + 2];
                        dr[x * 4 + 3] = 255;
                    }
                }
                [t.tex replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:level slice:face withBytes:tmp
                         bytesPerRow:dpitch bytesPerImage:dpitch * h];
                free(tmp);
            }
        } else {
            [t.tex replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:level slice:face withBytes:bytes
                     bytesPerRow:pitch bytesPerImage:pitch * rows];
        }
    }
    d3d_surf_end();
}

// the host texture for a guest texture / surface object (created on first use, uploads pending dirt)
static HTex *host_tex(uint32_t o) __attribute__((ns_returns_not_retained));
static HTex *host_tex(uint32_t o) {
    if (!o) return nil;
    uint32_t kind = OBJ_KIND(o);
    if (kind == K_SURF && G32(OBJ_F(o, S_CONT))) return host_tex(G32(OBJ_F(o, S_CONT)));   // a level of a texture
    HTex *t = (__bridge HTex *)host_get(o);     // strong: the creation path below assigns new objects to it
    if (!t) {
        if (kind == K_TEX || kind == K_CUBE) {
            t = make_tex(G32(OBJ_F(o, T_FMT)), G32(OBJ_F(o, T_W)), G32(OBJ_F(o, T_H)), G32(OBJ_F(o, T_LEVELS)), G32(OBJ_F(o, T_FACES)), 1,
                         (G32(OBJ_F(o, T_USAGE)) & 3) != 0);
            if (!t) return nil;
            host_set(o, t);
            P32(OBJ_F(o, T_DIRTY), 1);
            for (uint32_t i = 0; i < t.levels * t.faces; i++) P32(OBJ_F(G32(G32(OBJ_F(o, T_SURFS)) + 4 * i), S_DIRTY), 1);
        } else if (kind == K_SURF) {
            t = make_tex(G32(OBJ_F(o, S_FMT)), G32(OBJ_F(o, S_W)), G32(OBJ_F(o, S_H)), 1, 1, G32(OBJ_F(o, S_MS)) > 1 ? G32(OBJ_F(o, S_MS)) : 1,
                         (G32(OBJ_F(o, S_USAGE)) & 3) != 0);
            if (!t) return nil;
            host_set(o, t);
            if (!(G32(OBJ_F(o, S_USAGE)) & 3)) upload_level(t, o, 0, 0);
            return t;
        } else return nil;
    }
    if ((kind == K_TEX || kind == K_CUBE) && G32(OBJ_F(o, T_DIRTY))) {
        P32(OBJ_F(o, T_DIRTY), 0);
        for (uint32_t f = 0; f < t.faces; f++)
            for (uint32_t l = 0; l < t.levels; l++) {
                uint32_t su = G32(G32(OBJ_F(o, T_SURFS)) + 4 * (f * t.levels + l));
                if (G32(OBJ_F(su, S_DIRTY))) { P32(OBJ_F(su, S_DIRTY), 0); upload_level(t, su, f, l); }
            }
    } else if (kind == K_SURF && G32(OBJ_F(o, S_DIRTY))) { P32(OBJ_F(o, S_DIRTY), 0); upload_level(t, o, 0, 0); }
    return t;
}
// the specific level/face slice a surface is (for render targets that are texture levels)
static id<MTLTexture> surf_target(uint32_t s, NSUInteger *level, NSUInteger *slice) {
    *level = 0; *slice = 0;
    if (!s) return nil;
    uint32_t cont = G32(OBJ_F(s, S_CONT));
    HTex *t = host_tex(s);
    if (cont) { uint32_t lv = G32(OBJ_F(s, S_LEVEL)); *level = lv & 0xFFFF; *slice = lv >> 16; }
    return t.tex;
}

// ---- shaders & pipelines ----------------------------------------------------------------------------
@interface HShader : NSObject {
@public
    SMInfo info;
    int nvar;
    uint32_t var_key[16];          // hash of (depth_mask, extras)
    __unsafe_unretained id<MTLFunction> var_fn[16];
}
@property(nonatomic, strong) NSMutableArray *keep;    // owns the functions
@end
@implementation HShader
@end

static MTLCompileOptions *copts;
static HShader *host_shader(uint32_t o) __attribute__((ns_returns_not_retained));
static HShader *host_shader(uint32_t o) {
    __unsafe_unretained HShader *h0 = (__bridge HShader *)host_get(o);
    if (h0) return h0;
    HShader *h;
    h = [HShader new];
    char err[256];
    if (!sm_reflect((const uint32_t *)(void *)(MEM + G32(OBJ_F(o, 0))), G32(OBJ_F(o, 1)), &h->info, err, sizeof err)) {
        fprintf(stderr, "[metal] shader %#x reflect failed: %s\n", o, err);
        return nil;
    }
    h.keep = [NSMutableArray array];
    host_set(o, h);
    return h;
}
static uint64_t stall_ns;                                   // time spent compiling shaders / pipelines
// Low-rate diagnostics. Main-thread CPU time distinguishes running from sleeping;
// completed command-buffer timestamps distinguish GPU work from drawable/queue waits.
// These counters never change submission order, frames in flight, or game settings.
typedef struct {
    uint64_t last_wall, last_cpu, last_thread, intervals, cpu_intervals, cpu_rejected, wall_ns, cpu_ns, max_interval_ns;
    uint64_t presents, present_ns, drawable_ns, inflight_ns, upload_peak;
} FramePerf;
static FramePerf frame_perf;
static uint64_t perf_gpu_ns, perf_gpu_count, perf_gpu_unavailable, perf_last_stall;
static pthread_mutex_t perf_gpu_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t perf_thread_cpu_ns(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t)) return 0;
    return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
}
static void perf_add_interval(FramePerf *p, uint64_t wall, uint64_t cpu, uint64_t thread) {
    if (p->last_wall && wall >= p->last_wall) {
        uint64_t interval = wall - p->last_wall;
        p->wall_ns += interval; p->intervals++;
        if (interval > p->max_interval_ns) p->max_interval_ns = interval;
        if (p->last_cpu && cpu && thread && thread == p->last_thread && cpu >= p->last_cpu && cpu - p->last_cpu <= interval + 100000) {
            p->cpu_ns += cpu - p->last_cpu; p->cpu_intervals++;
        } else p->cpu_rejected++;
    }
    p->last_wall = wall; p->last_cpu = cpu; p->last_thread = thread;
}
static void perf_reset_window(FramePerf *p) {
    uint64_t wall = p->last_wall, cpu = p->last_cpu, thread = p->last_thread;
    memset(p, 0, sizeof *p); p->last_wall = wall; p->last_cpu = cpu; p->last_thread = thread;
}
static int perf_gpu_duration(double start, double end, uint64_t *ns) {
    double duration = (end - start) * 1e9;
    if (!(start > 0) || !isfinite(duration) || duration < 0 || duration >= (double)UINT64_MAX) return 0;
    *ns = (uint64_t)duration; return 1;
}
static void perf_gpu_completed(id<MTLCommandBuffer> b) {
    uint64_t ns;
    int valid = b.status == MTLCommandBufferStatusCompleted && perf_gpu_duration(b.GPUStartTime, b.GPUEndTime, &ns);
    pthread_mutex_lock(&perf_gpu_lock);
    if (valid) {
        __atomic_fetch_add(&perf_gpu_ns, ns, __ATOMIC_RELAXED);
        __atomic_fetch_add(&perf_gpu_count, 1, __ATOMIC_RELEASE);
    } else __atomic_fetch_add(&perf_gpu_unavailable, 1, __ATOMIC_RELAXED);
    pthread_mutex_unlock(&perf_gpu_lock);
}
static void perf_report(void) {
    // Keep duration and count in the same window when a completion races reporting.
    pthread_mutex_lock(&perf_gpu_lock);
    uint64_t gpu_count = __atomic_exchange_n(&perf_gpu_count, 0, __ATOMIC_ACQUIRE);
    uint64_t gpu_ns = __atomic_exchange_n(&perf_gpu_ns, 0, __ATOMIC_RELAXED);
    uint64_t unavailable = __atomic_exchange_n(&perf_gpu_unavailable, 0, __ATOMIC_RELAXED);
    pthread_mutex_unlock(&perf_gpu_lock);
    task_vm_info_data_t memory = {0}; mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
    int memory_ok = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&memory, &n) == KERN_SUCCESS;
    double frames = frame_perf.presents ? (double)frame_perf.presents : 1;
    NSProcessInfo *process = NSProcessInfo.processInfo;
    fprintf(stderr, "[perf] intervals=%llu interval_ms=%.2f max_interval_ms=%.2f main_cpu_ms=%.2f cpu_intervals=%llu cpu_rejected=%llu present_ms=%.2f drawable_wait_ms=%.2f inflight_wait_ms=%.2f gpu_ms=%.2f gpu_completed=%llu gpu_unknown=%llu compile_ms_total=%.2f upload_peak_kib=%llu footprint_mib=%.1f thermal=%ld low_power=%d\n",
        (unsigned long long)frame_perf.intervals,
        frame_perf.intervals ? frame_perf.wall_ns / (1e6 * frame_perf.intervals) : -1,
        frame_perf.max_interval_ns / 1e6,
        frame_perf.cpu_intervals ? frame_perf.cpu_ns / (1e6 * frame_perf.cpu_intervals) : -1,
        (unsigned long long)frame_perf.cpu_intervals, (unsigned long long)frame_perf.cpu_rejected,
        frame_perf.present_ns / (1e6 * frames), frame_perf.drawable_ns / (1e6 * frames), frame_perf.inflight_ns / (1e6 * frames),
        gpu_count ? gpu_ns / (1e6 * gpu_count) : -1,
        (unsigned long long)gpu_count, (unsigned long long)unavailable, (stall_ns - perf_last_stall) / 1e6,
        (unsigned long long)(frame_perf.upload_peak / 1024), memory_ok ? memory.phys_footprint / 1048576.0 : -1, (long)process.thermalState, (int)process.lowPowerModeEnabled);
    perf_last_stall = stall_ns; perf_reset_window(&frame_perf);
}
static id<MTLFunction> shader_fn(uint32_t o, HShader *h, const uint16_t *extra, int n_extra, uint32_t depth_mask) {
    uint32_t key = depth_mask * 2654435761u;
    for (int i = 0; i < n_extra; i++) key = (key ^ extra[i]) * 16777619u;
    for (int i = 0; i < h->nvar; i++) if (h->var_key[i] == key) return h->var_fn[i];
    SMInfo info = h->info; info.depth_mask_in = depth_mask;
    char err[256];
    char *msl = sm_translate((const uint32_t *)(void *)(MEM + G32(OBJ_F(o, 0))), G32(OBJ_F(o, 1)), &info, extra, n_extra, err, sizeof err);
    if (!msl) { fprintf(stderr, "[metal] translate failed: %s\n", err); return nil; }
    NSError *e = nil;
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:msl] options:copts error:&e];
    uint64_t dt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0;
    stall_ns += dt;
    if (dt > 4000000) fprintf(stderr, "[metal] shader compile %.1f ms (%s)\n", (double)dt / 1e6, h->info.is_ps ? "ps" : "vs");
    free(msl);
    if (!lib) { fprintf(stderr, "[metal] compile failed: %s\n", e.localizedDescription.UTF8String); return nil; }
    id<MTLFunction> f = [lib newFunctionWithName:h->info.is_ps ? @"pmain" : @"vmain"];
    [h.keep addObject:f];
    if (h->nvar < 16) { h->var_key[h->nvar] = key; h->var_fn[h->nvar] = f; h->nvar++; }
    return f;
}

static MTLVertexFormat decl_fmt(int t) {
    switch (t) {
    case 0: return MTLVertexFormatFloat;  case 1: return MTLVertexFormatFloat2; case 2: return MTLVertexFormatFloat3; case 3: return MTLVertexFormatFloat4;
    case 4: return MTLVertexFormatUChar4Normalized_BGRA; case 5: return MTLVertexFormatUChar4; case 6: return MTLVertexFormatShort2;
    case 7: return MTLVertexFormatShort4; case 8: return MTLVertexFormatUChar4Normalized; case 9: return MTLVertexFormatShort2Normalized;
    case 10: return MTLVertexFormatShort4Normalized; case 11: return MTLVertexFormatUShort2Normalized; case 12: return MTLVertexFormatUShort4Normalized;
    case 13: return MTLVertexFormatUInt1010102Normalized; case 14: return MTLVertexFormatInt1010102Normalized;
    case 15: return MTLVertexFormatHalf2; case 16: return MTLVertexFormatHalf4;
    }
    return MTLVertexFormatInvalid;
}

// build the vertex descriptor: decl elements matched to VS input registers by (usage, index)
static MTLVertexDescriptor *vertex_desc(D3DState *s, const SMInfo *vi, uint32_t *streams_used, NSMutableString *key) {
    MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
    *streams_used = 0;
    if (!s->decl) return nil;
    uint32_t e = G32(OBJ_F(s->decl, 0)), n = G32(OBJ_F(s->decl, 1));
    for (uint32_t i = 0; i < n; i++, e += 8) {
        uint16_t stream, off; uint8_t type, method, usage, uidx;
        memcpy(&stream, MEM + e, 2); memcpy(&off, MEM + e + 2, 2); type = MEM[e + 4]; method = MEM[e + 5]; usage = MEM[e + 6]; uidx = MEM[e + 7];
        if (stream == 0xFF) break;
        (void)method;
        for (int r = 0; r < 16; r++) {
            if (vi->in_usage[r] != usage || vi->in_index[r] != uidx) continue;
            vd.attributes[r].format = decl_fmt(type); vd.attributes[r].offset = off; vd.attributes[r].bufferIndex = stream;
            *streams_used |= 1u << stream;
            [key appendFormat:@"a%d:%d:%d:%d;", r, type, off, stream];
        }
    }
    for (int st = 0; st < 16; st++) if (*streams_used & (1u << st)) {
        vd.layouts[st].stride = s->stream_stride[st] ? s->stream_stride[st] : 4;
        if (s->stream_freq[st] & 0x80000000u) {
            uint32_t div = s->stream_freq[st] & 0x3FFFFFFFu;
            vd.layouts[st].stepFunction = MTLVertexStepFunctionPerInstance;
            vd.layouts[st].stepRate = div ? div : 1;
        } else {
            vd.layouts[st].stepFunction = MTLVertexStepFunctionPerVertex;
        }
        [key appendFormat:@"s%d:%u:%u;", st, s->stream_stride[st], s->stream_freq[st]];
    }
    return vd;
}

static MTLBlendFactor blendf(uint32_t b) {
    switch (b) {
    case 1: return MTLBlendFactorZero; case 2: return MTLBlendFactorOne; case 3: return MTLBlendFactorSourceColor;
    case 4: return MTLBlendFactorOneMinusSourceColor; case 5: return MTLBlendFactorSourceAlpha; case 6: return MTLBlendFactorOneMinusSourceAlpha;
    case 7: return MTLBlendFactorDestinationAlpha; case 8: return MTLBlendFactorOneMinusDestinationAlpha; case 9: return MTLBlendFactorDestinationColor;
    case 10: return MTLBlendFactorOneMinusDestinationColor; case 11: return MTLBlendFactorSourceAlphaSaturated;
    case 14: return MTLBlendFactorBlendColor; case 15: return MTLBlendFactorOneMinusBlendColor;
    }
    return MTLBlendFactorOne;
}
static MTLBlendOperation blendop(uint32_t o) {
    switch (o) { case 2: return MTLBlendOperationSubtract; case 3: return MTLBlendOperationReverseSubtract; case 4: return MTLBlendOperationMin; case 5: return MTLBlendOperationMax; }
    return MTLBlendOperationAdd;
}
static MTLCompareFunction cmpf(uint32_t f) {
    switch (f) {
    case 1: return MTLCompareFunctionNever; case 2: return MTLCompareFunctionLess; case 3: return MTLCompareFunctionEqual; case 4: return MTLCompareFunctionLessEqual;
    case 5: return MTLCompareFunctionGreater; case 6: return MTLCompareFunctionNotEqual; case 7: return MTLCompareFunctionGreaterEqual;
    }
    return MTLCompareFunctionAlways;
}
static MTLStencilOperation stencilop(uint32_t o) {
    switch (o) {
    case 2: return MTLStencilOperationZero; case 3: return MTLStencilOperationReplace; case 4: return MTLStencilOperationIncrementClamp;
    case 5: return MTLStencilOperationDecrementClamp; case 6: return MTLStencilOperationInvert; case 7: return MTLStencilOperationIncrementWrap;
    case 8: return MTLStencilOperationDecrementWrap;
    }
    return MTLStencilOperationKeep;
}

// ---- render passes ----------------------------------------------------------------------------------
static void end_pass(void) { if (enc) { [enc endEncoding]; enc = nil; } }

static void ensure_cmd(void) { if (!cmd) cmd = [queue commandBuffer]; }

static void begin_pass(D3DState *s, uint32_t clear_flags, uint32_t color, float z, uint32_t stencil) {
    end_pass(); ensure_cmd();
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    for (int i = 0; i < 4; i++) {
        NSUInteger lv, sl; id<MTLTexture> t = surf_target(s->rt[i], &lv, &sl);
        if (!t) continue;
        rp.colorAttachments[i].texture = t; rp.colorAttachments[i].level = lv; rp.colorAttachments[i].slice = sl;
        rp.colorAttachments[i].loadAction = (clear_flags & 1) ? MTLLoadActionClear : MTLLoadActionLoad;
        rp.colorAttachments[i].clearColor = MTLClearColorMake(((color >> 16) & 255) / 255.0, ((color >> 8) & 255) / 255.0, (color & 255) / 255.0, (color >> 24) / 255.0);
        rp.colorAttachments[i].storeAction = MTLStoreActionStore;
    }
    if (s->ds) {
        NSUInteger lv, sl; id<MTLTexture> t = surf_target(s->ds, &lv, &sl);
        if (t) {
            rp.depthAttachment.texture = t; rp.depthAttachment.loadAction = (clear_flags & 2) ? MTLLoadActionClear : MTLLoadActionLoad;
            rp.depthAttachment.clearDepth = z; rp.depthAttachment.storeAction = MTLStoreActionStore;
            if (t.pixelFormat == MTLPixelFormatDepth32Float_Stencil8) {
                rp.stencilAttachment.texture = t; rp.stencilAttachment.loadAction = (clear_flags & 4) ? MTLLoadActionClear : MTLLoadActionLoad;
                rp.stencilAttachment.clearStencil = stencil; rp.stencilAttachment.storeAction = MTLStoreActionStore;
            }
        }
    }
    enc = [cmd renderCommandEncoderWithDescriptor:rp];
    ec_reset();
    memcpy(enc_rt, s->rt, sizeof enc_rt); enc_ds = s->ds;
}
static void ensure_pass(D3DState *s) {
    if (enc && !memcmp(enc_rt, s->rt, sizeof enc_rt) && enc_ds == s->ds) return;
    begin_pass(s, 0, 0, 1, 0);
}

// ---- ring buffer --------------------------------------------------------------------------------------
static uint32_t ring_put(const void *p, uint32_t n) {
    uint32_t off = (ring_off + 255) & ~255u;
    if (off + n > RING_SIZE) { fprintf(stderr, "[metal] ring overflow (%u bytes this frame)\n", off + n); off = 0; }
    memcpy((uint8_t *)ring[ring_idx].contents + off, p, n);
    ring_off = off + n;
    return off;
}

// ---- draws ----------------------------------------------------------------------------------------------
typedef struct { uint32_t k[8]; __unsafe_unretained id<MTLSamplerState> st; } SampEnt;
static SampEnt samp_tab[1024];
static NSMutableArray *samp_keep;
static id<MTLSamplerState> sampler(D3DState *s, int i, int compare) {
    uint32_t *ss = s->ss[i];
    uint32_t k[8] = {ss[1], ss[2], ss[3], ss[5], ss[6], ss[7], ss[10], (uint32_t)compare};
    uint32_t h = 2166136261u; for (int j = 0; j < 8; j++) h = (h ^ k[j]) * 16777619u;
    for (uint32_t p = 0; p < 1024; p++) {
        SampEnt *e = &samp_tab[(h + p) & 1023];
        if (!e->st) break;
        if (!memcmp(e->k, k, sizeof k)) return e->st;
    }
    MTLSamplerDescriptor *d = [MTLSamplerDescriptor new];
    MTLSamplerAddressMode am[] = {MTLSamplerAddressModeRepeat, MTLSamplerAddressModeRepeat, MTLSamplerAddressModeMirrorRepeat,
                                  MTLSamplerAddressModeClampToEdge, MTLSamplerAddressModeClampToBorderColor, MTLSamplerAddressModeMirrorClampToEdge};
    d.sAddressMode = am[ss[1] < 6 ? ss[1] : 1]; d.tAddressMode = am[ss[2] < 6 ? ss[2] : 1]; d.rAddressMode = am[ss[3] < 6 ? ss[3] : 1];
    d.magFilter = ss[5] >= 2 ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
    d.minFilter = ss[6] >= 2 ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
    d.mipFilter = ss[7] == 0 ? MTLSamplerMipFilterNotMipmapped : ss[7] == 1 ? MTLSamplerMipFilterNearest : MTLSamplerMipFilterLinear;
    d.maxAnisotropy = (ss[6] == 3 || ss[5] == 3) ? (ss[10] ? ss[10] : 1) : 1;
    if (compare) { d.compareFunction = MTLCompareFunctionLessEqual; d.minFilter = d.magFilter = MTLSamplerMinMagFilterLinear; }
    id<MTLSamplerState> st = [dev newSamplerStateWithDescriptor:d];
    [samp_keep addObject:st];
    for (uint32_t p = 0; p < 1024; p++) {
        SampEnt *e = &samp_tab[(h + p) & 1023];
        if (!e->st) { memcpy(e->k, k, sizeof k); e->st = st; break; }
    }
    return st;
}

static int prim_info(uint32_t prim, uint32_t count, MTLPrimitiveType *pt, uint32_t *nverts) {
    switch (prim) {
    case 1: *pt = MTLPrimitiveTypePoint; *nverts = count; return 1;
    case 2: *pt = MTLPrimitiveTypeLine; *nverts = count * 2; return 1;
    case 3: *pt = MTLPrimitiveTypeLineStrip; *nverts = count + 1; return 1;
    case 4: *pt = MTLPrimitiveTypeTriangle; *nverts = count * 3; return 1;
    case 5: *pt = MTLPrimitiveTypeTriangleStrip; *nverts = count + 2; return 1;
    case 6: *pt = MTLPrimitiveTypeTriangle; *nverts = count * 3; return 2;     // fan: expanded
    }
    return 0;
}

// Everything a pipeline depends on, compared with memcmp.
typedef struct {
    uint32_t vs, ps, decl, depth_mask, fvf;
    uint32_t stride[8], inst_step[8];
    uint32_t rtfmt[4], rtwm[4], dsfmt, samples;
    uint32_t blend_en, src, dst, op, sep, srca, dsta, opa;
} PipeKey;
typedef struct { PipeKey k; uint32_t streams; __unsafe_unretained id<MTLRenderPipelineState> pso; } PipeEnt;
#define PIPE_TAB 16384
static PipeEnt *pipe_tab;
static NSMutableArray *pipe_keep;
static uint32_t pipe_count;

typedef struct { uint32_t key; __unsafe_unretained id<MTLDepthStencilState> st; } DssEnt;
static DssEnt dss_tab[4096];
static NSMutableArray *dss_keep;
static uint32_t last_vs_off, last_ps_off, last_vs_n, last_ps_n, last_ring_for_consts = 99;

// The original movie renderer uses SetFVF(XYZRHW | TEX1), null shaders and
// 24-byte screen-space vertices (EC0280). These vertices bypass vertex processing:
// https://learn.microsoft.com/en-us/windows/win32/direct3d9/mapping-fvf-codes-to-a-directx-9-declaration
// Support its single texture stage; retain explicit rejection of other fixed-function layouts.
static int screen_fvf(D3DState *s) {
    uint32_t color=s->tss[0][1], alpha=s->tss[0][4];
    return !s->vs && !s->ps && !s->decl && s->fvf==0x104 && s->stream_stride[0]>=24 &&
        s->tex[0] && OBJ_KIND(s->tex[0])==K_TEX &&
        (color==2 || (color==4 && s->tss[0][3]<=1)) && s->tss[0][2]==2 &&
        (alpha==2 || (alpha==4 && s->tss[0][6]<=1)) && s->tss[0][5]==2 &&
        s->tss[1][1]<=1;
}
static HShader *screen_shader(int pixel) {
    static HShader *stages[2];
    if(!stages[pixel]) {
        HShader *stage=[HShader new];
        stage->info.max_const=-1; stage->info.major=3;
        stage->info.samplers=pixel?1:0;
        stages[pixel]=stage;
    }
    return stages[pixel];
}
static id<MTLFunction> screen_function(int pixel) {
    static id<MTLLibrary> library;
    if(!library) {
        NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
            "struct In { float4 p [[attribute(0)]]; float2 uv [[attribute(1)]]; };\n"
            "struct Out { float4 p [[position]]; float2 uv; };\n"
            "struct ScreenSys { uint alpha_func; float alpha_ref; uint fog_mode,fog_enable; float4 fog_color,fog_params; uint fog_table,opaque,p1,p2; };\n"
            "vertex Out screen_v(In v [[stage_in]], constant float4 &vp [[buffer(23)]]) {\n"
            " float w=1.0/v.p.w; float2 q=(v.p.xy-vp.xy+0.5)/vp.zw;\n"
            " Out o; o.p=float4((q*float2(2,-2)+float2(-1,1))*w,v.p.z*w,w); o.uv=v.uv; return o; }\n"
            "fragment float4 screen_p(Out v [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant ScreenSys &u [[buffer(3)]]) { float4 c=t.sample(s,v.uv); if(u.opaque)c.a=1; return c; }\n";
        NSError *error=nil;
        library=[dev newLibraryWithSource:source options:copts error:&error];
        if(!library)fprintf(stderr,"[metal] screen FVF shader failed: %s\n",error.localizedDescription.UTF8String);
    }
    return [library newFunctionWithName:pixel?@"screen_p":@"screen_v"];
}

static uint32_t decl_streams(D3DState *s) {
    uint32_t e = G32(OBJ_F(s->decl, 0)), n = G32(OBJ_F(s->decl, 1)), m = 0;
    for (uint32_t i = 0; i < n; i++, e += 8) { uint16_t st; memcpy(&st, MEM + e, 2); if (st == 0xFF) break; if (st < 16) m |= 1u << st; }
    return m;
}

static int setup_draw(D3DState *s) {
    int screen=screen_fvf(s);
    if ((!s->vs || !s->ps) && !screen) {
        if(ff_skipped++<8)fprintf(stderr,"[metal] unsupported fixed draw fvf=%#x stride=%u vs=%#x ps=%#x color=%u/%u/%u alpha=%u/%u/%u next=%u\n",
            s->fvf,s->stream_stride[0],s->vs,s->ps,s->tss[0][1],s->tss[0][2],s->tss[0][3],s->tss[0][4],s->tss[0][5],s->tss[0][6],s->tss[1][1]);
        return 0;
    }
    if (!s->decl && !screen) return 0;
    ensure_pass(s);
    PipeKey k; memset(&k, 0, sizeof k);
    k.vs = s->vs; k.ps = s->ps; k.decl = s->decl;
    k.fvf = screen?s->fvf:0;
    for (int i = 0; i < 16; i++) {
        uint32_t t = s->tex[i];
        if (t && OBJ_KIND(t) == K_TEX && is_depth_fmt(G32(OBJ_F(t, T_FMT)))) k.depth_mask |= 1u << i;
    }
    for (int i = 0; i < 8; i++) {
        k.stride[i] = s->stream_stride[i];
        if (s->stream_freq[i] & 0x80000000u) {
            uint32_t div = s->stream_freq[i] & 0x3FFFFFFFu;
            k.inst_step[i] = div ? div : 1;
        }
    }
    for (int i = 0; i < 4; i++) {
        NSUInteger lv, sl; id<MTLTexture> t = surf_target(s->rt[i], &lv, &sl);
        if (!t) continue;
        k.rtfmt[i] = (uint32_t)t.pixelFormat; k.samples = (uint32_t)t.sampleCount;
        k.rtwm[i] = i == 0 ? s->rs[168] : s->rs[189 + i];
    }
    if (s->ds) { NSUInteger lv, sl; id<MTLTexture> t = surf_target(s->ds, &lv, &sl); if (t) { k.dsfmt = (uint32_t)t.pixelFormat; k.samples = (uint32_t)t.sampleCount; } }
    if (s->rs[27]) { k.blend_en = 1; k.src = s->rs[19]; k.dst = s->rs[20]; k.op = s->rs[171];
        if (s->rs[206]) { k.sep = 1; k.srca = s->rs[207]; k.dsta = s->rs[208]; k.opa = s->rs[209]; } }

    uint32_t h = 2166136261u; const uint32_t *kw = (const uint32_t *)&k;
    for (size_t i = 0; i < sizeof k / 4; i++) h = (h ^ kw[i]) * 16777619u;
    PipeEnt *pe = NULL;
    for (uint32_t p = 0; p < PIPE_TAB; p++) {
        PipeEnt *e = &pipe_tab[(h + p) & (PIPE_TAB - 1)];
        if (!e->pso) { pe = e; break; }
        if (!memcmp(&e->k, &k, sizeof k)) { pe = e; break; }
    }
    if (!pe) return 0;
    __unsafe_unretained HShader *vs = screen?screen_shader(0):host_shader(s->vs), *ps = screen?screen_shader(1):host_shader(s->ps);
    if (!vs || !ps) return 0;
    if (!pe->pso) {
        // miss: link the stages, translate/compile, describe vertices, build the pipeline
        uint16_t extra[16]; int ne = 0;
        for (int i = 0; i < ps->info.n_io; i++) {
            int found = 0;
            for (int j = 0; j < vs->info.n_io; j++) if (vs->info.io_keys[j] == ps->info.io_keys[i]) found = 1;
            if (!found && ne < 16) extra[ne++] = ps->info.io_keys[i];
        }
        id<MTLFunction> vf = screen?screen_function(0):shader_fn(s->vs, vs, extra, ne, 0), pf = screen?screen_function(1):shader_fn(s->ps, ps, NULL, 0, k.depth_mask);
        if (!vf || !pf) return 0;
        NSMutableString *unused = [NSMutableString string];
        uint32_t streams;
        SMInfo vi = vs->info;
        MTLVertexDescriptor *vd;
        if(screen) {
            vd=[MTLVertexDescriptor vertexDescriptor]; streams=1;
            vd.attributes[0].format=MTLVertexFormatFloat4; vd.attributes[0].offset=0; vd.attributes[0].bufferIndex=0;
            vd.attributes[1].format=MTLVertexFormatFloat2; vd.attributes[1].offset=16; vd.attributes[1].bufferIndex=0;
            vd.layouts[0].stride=s->stream_stride[0];
        } else vd = vertex_desc(s, &vi, &streams, unused);
        if (!vd) return 0;
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = vf; pd.fragmentFunction = pf; pd.vertexDescriptor = vd;
        for (int i = 0; i < 4; i++) {
            if (!k.rtfmt[i]) continue;
            pd.colorAttachments[i].pixelFormat = (MTLPixelFormat)k.rtfmt[i];
            uint32_t wm = k.rtwm[i];
            pd.colorAttachments[i].writeMask = (wm & 1 ? MTLColorWriteMaskRed : 0) | (wm & 2 ? MTLColorWriteMaskGreen : 0) | (wm & 4 ? MTLColorWriteMaskBlue : 0) | (wm & 8 ? MTLColorWriteMaskAlpha : 0);
            if (k.blend_en) {
                pd.colorAttachments[i].blendingEnabled = YES;
                pd.colorAttachments[i].sourceRGBBlendFactor = blendf(k.src); pd.colorAttachments[i].destinationRGBBlendFactor = blendf(k.dst);
                pd.colorAttachments[i].rgbBlendOperation = blendop(k.op);
                pd.colorAttachments[i].sourceAlphaBlendFactor = blendf(k.sep ? k.srca : k.src);
                pd.colorAttachments[i].destinationAlphaBlendFactor = blendf(k.sep ? k.dsta : k.dst);
                pd.colorAttachments[i].alphaBlendOperation = blendop(k.sep ? k.opa : k.op);
            }
        }
        if (k.dsfmt) { pd.depthAttachmentPixelFormat = (MTLPixelFormat)k.dsfmt; if (k.dsfmt == MTLPixelFormatDepth32Float_Stencil8) pd.stencilAttachmentPixelFormat = (MTLPixelFormat)k.dsfmt; }
        pd.rasterSampleCount = k.samples ? k.samples : 1;
        NSError *e = nil;
        uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        id<MTLRenderPipelineState> pso = [dev newRenderPipelineStateWithDescriptor:pd error:&e];
        uint64_t dt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0;
        stall_ns += dt;
        if (dt > 4000000) fprintf(stderr, "[metal] pipeline build %.1f ms\n", (double)dt / 1e6);
        if (!pso) { fprintf(stderr, "[metal] pipeline failed: %s\n", e.localizedDescription.UTF8String); return 0; }
        [pipe_keep addObject:pso];
        pe->k = k; pe->pso = pso; pe->streams = streams; pipe_count++;
        if(screen)fprintf(stderr,"[metal] screen FVF pipeline ready fvf=%#x stride=%u\n",s->fvf,s->stream_stride[0]);
    }
    if (ec.pso != pe->pso) { [enc setRenderPipelineState:pe->pso]; ec.pso = pe->pso; }

    // depth / stencil
    uint32_t dkey = (s->rs[7] ? 1 : 0) | (s->rs[14] ? 2 : 0) | (s->rs[23] << 2) | (s->rs[52] ? 64 : 0) | (s->rs[56] << 7) | (s->rs[53] << 11) |
                    (s->rs[54] << 15) | (s->rs[55] << 19) | ((s->rs[58] & 0xFF) << 23);
    dkey ^= (s->rs[59] & 0xFF) * 2654435761u;
    id<MTLDepthStencilState> ds = nil;
    for (uint32_t p = 0; p < 4096; p++) {
        DssEnt *e = &dss_tab[(dkey * 2654435761u + p) & 4095];
        if (!e->st) {
            MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
            dd.depthCompareFunction = s->rs[7] ? cmpf(s->rs[23]) : MTLCompareFunctionAlways;
            dd.depthWriteEnabled = s->rs[7] && s->rs[14];
            if (s->rs[52]) {
                MTLStencilDescriptor *sd = [MTLStencilDescriptor new];
                sd.stencilCompareFunction = cmpf(s->rs[56]); sd.stencilFailureOperation = stencilop(s->rs[53]);
                sd.depthFailureOperation = stencilop(s->rs[54]); sd.depthStencilPassOperation = stencilop(s->rs[55]);
                sd.readMask = s->rs[58]; sd.writeMask = s->rs[59];
                dd.frontFaceStencil = sd; dd.backFaceStencil = sd;
            }
            ds = [dev newDepthStencilStateWithDescriptor:dd];
            [dss_keep addObject:ds];
            e->key = dkey; e->st = ds;
            break;
        }
        if (e->key == dkey) { ds = e->st; break; }
    }
    if (ec.dss != ds) { [enc setDepthStencilState:ds]; ec.dss = ds; }
    uint32_t cull = s->rs[22] == 2 ? MTLCullModeFront : s->rs[22] == 3 ? MTLCullModeBack : MTLCullModeNone;
    uint32_t fill = s->rs[8] == 2 ? MTLTriangleFillModeLines : MTLTriangleFillModeFill;
    float bias, slope; memcpy(&bias, &s->rs[195], 4); memcpy(&slope, &s->rs[175], 4);
    float vpz0, vpz1; memcpy(&vpz0, &s->viewport[4], 4); memcpy(&vpz1, &s->viewport[5], 4);
    MTLViewport vp = {s->viewport[0], s->viewport[1], s->viewport[2], s->viewport[3], vpz0, vpz1};
    if (!ec.fixed_valid) [enc setFrontFacingWinding:MTLWindingClockwise];
    if (!ec.fixed_valid || ec.sref != s->rs[57]) { [enc setStencilReferenceValue:s->rs[57]]; ec.sref = s->rs[57]; }
    if (!ec.fixed_valid || ec.cull != cull) { [enc setCullMode:(MTLCullMode)cull]; ec.cull = cull; }
    if (!ec.fixed_valid || ec.fill != fill) { [enc setTriangleFillMode:(MTLTriangleFillMode)fill]; ec.fill = fill; }
    if (!ec.fixed_valid || ec.bias != bias || ec.slope != slope) { [enc setDepthBias:bias * 16777216.0f slopeScale:slope clamp:0]; ec.bias = bias; ec.slope = slope; }
    if (!ec.fixed_valid || memcmp(&ec.vp, &vp, sizeof vp)) { [enc setViewport:vp]; ec.vp = vp; }
    NSUInteger lv, sl; id<MTLTexture> rt0 = surf_target(s->rt[0], &lv, &sl);
    NSUInteger tw = rt0 ? MAX(1, rt0.width >> lv) : s->width, th = rt0 ? MAX(1, rt0.height >> lv) : s->height;
    MTLScissorRect sc = {0, 0, tw, th};
    if (s->rs[174]) {
        int x0 = (int)s->scissor[0], y0 = (int)s->scissor[1], x1 = (int)s->scissor[2], y1 = (int)s->scissor[3];
        x0 = MAX(0, MIN(x0, (int)tw)); x1 = MAX(x0, MIN(x1, (int)tw)); y0 = MAX(0, MIN(y0, (int)th)); y1 = MAX(y0, MIN(y1, (int)th));
        sc = (MTLScissorRect){(NSUInteger)x0, (NSUInteger)y0, (NSUInteger)(x1 - x0), (NSUInteger)(y1 - y0)};
    }
    if (!ec.fixed_valid || memcmp(&ec.sc, &sc, sizeof sc)) { [enc setScissorRect:sc]; ec.sc = sc; }
    uint32_t bc = s->rs[193];
    if (!ec.fixed_valid || ec.bc != bc) {
        [enc setBlendColorRed:((bc >> 16) & 255) / 255.0f green:((bc >> 8) & 255) / 255.0f blue:(bc & 255) / 255.0f alpha:(bc >> 24) / 255.0f];
        ec.bc = bc;
    }
    ec.fixed_valid = 1;

    // constants: re-upload only what changed since the last draw in this frame's ring
    // only the registers the bound shaders read (max_const from reflection); re-upload when the game
    // changed constants, the ring rotated, or this shader reads past what the last upload covered
    uint32_t vn = (uint32_t)(vs->info.max_const + 1), pn = (uint32_t)(ps->info.max_const + 1);
    if (vn > 256) vn = 256;
    if (pn > 224) pn = 224;
    if (s->vsc_dirty || last_ring_for_consts != ring_idx || vn > last_vs_n) {
        last_vs_off = ring_put(s->vsc, (vn ? vn : 1) * 16); last_vs_n = vn; s->vsc_dirty = 0;
    }
    if (s->psc_dirty || last_ring_for_consts != ring_idx || pn > last_ps_n) {
        last_ps_off = ring_put(s->psc, (pn ? pn : 1) * 16); last_ps_n = pn; s->psc_dirty = 0;
    }
    last_ring_for_consts = ring_idx;
    ec_vbuf(ring[ring_idx], last_vs_off, 20);
    ec_vbytes(s->vsi, sizeof s->vsi, 21);
    ec_vbytes(s->vsb, sizeof s->vsb, 22);
    float vsys[4] = {s->viewport[2] ? 1.0f / (float)s->viewport[2] : 0, s->viewport[3] ? -1.0f / (float)s->viewport[3] : 0, 0, 0};
    if(screen)for(unsigned i=0;i<4;i++)vsys[i]=(float)s->viewport[i];
    ec_vbytes(vsys, sizeof vsys, 23);
    ec_fbuf(ring[ring_idx], last_ps_off, 0);
    ec_fbytes(s->psi, sizeof s->psi, 1);
    ec_fbytes(s->psb, sizeof s->psb, 2);
    struct { uint32_t alpha_func; float alpha_ref; uint32_t fog_mode, fog_enable; float fog_color[4]; float fog_params[4]; uint32_t fog_table, p0, p1, p2; } psys;
    psys.alpha_func = s->rs[15] ? s->rs[25] : 8; psys.alpha_ref = (float)(s->rs[24] & 255) / 255.0f;
    psys.fog_enable = s->rs[28] && ps->info.major < 3; psys.fog_table = s->rs[35] != 0; psys.fog_mode = s->rs[35] ? s->rs[35] : s->rs[140];
    uint32_t fc = s->rs[34];
    psys.fog_color[0] = ((fc >> 16) & 255) / 255.0f; psys.fog_color[1] = ((fc >> 8) & 255) / 255.0f; psys.fog_color[2] = (fc & 255) / 255.0f; psys.fog_color[3] = 1;
    memcpy(&psys.fog_params[0], &s->rs[36], 4); memcpy(&psys.fog_params[1], &s->rs[37], 4); memcpy(&psys.fog_params[2], &s->rs[38], 4); psys.fog_params[3] = 0;
    // XRGB has no alpha channel. The paravirtual GPU samples its unused byte
    // despite an alpha-one texture view; enforce the D3D format in this shader.
    psys.p0 = screen && (G32(OBJ_F(s->tex[0],T_FMT))==22 || G32(OBJ_F(s->tex[0],T_FMT))==33);
    psys.p1 = psys.p2 = 0;
    _Static_assert(sizeof psys <= 256, "psys");
    ec_fbytes(&psys, sizeof psys, 3);

    static id<MTLTexture> dummy_tex, dummy_dtex;
    for (int i = 0; i < 16; i++) {
        if (!(ps->info.samplers & (1u << i))) continue;
        __unsafe_unretained HTex *t = host_tex(s->tex[i]);
        id<MTLTexture> tv = nil;
        if (t) {
            tv = (k.depth_mask >> i) & 1 ? t.tex : t.view;
        } else if ((k.depth_mask >> i) & 1) {
            if (!dummy_dtex) {
                MTLTextureDescriptor *dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8 width:1 height:1 mipmapped:NO];
                dd.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
                dd.storageMode = MTLStorageModePrivate;
                dummy_dtex = [dev newTextureWithDescriptor:dd];
            }
            tv = dummy_dtex;
        } else {
            if (!dummy_tex) {
                MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:1 height:1 mipmapped:NO];
                td.usage = MTLTextureUsageShaderRead;
                td.storageMode = MTLStorageModeShared;
                dummy_tex = [dev newTextureWithDescriptor:td];
                uint32_t black = 0xFF000000u;
                [dummy_tex replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:&black bytesPerRow:4];
            }
            tv = dummy_tex;
        }
        if (ec.ftex[i] != tv) { [enc setFragmentTexture:tv atIndex:i]; ec.ftex[i] = tv; }
        id<MTLSamplerState> sm = sampler(s, i, 0);
        if (ec.fsamp[i] != sm) { [enc setFragmentSamplerState:sm atIndex:i]; ec.fsamp[i] = sm; }
    }
    for (int i = 0; i < 4; i++) {
        if (!(vs->info.samplers & (1u << i))) continue;
        __unsafe_unretained HTex *t = host_tex(s->tex[16 + i]);
        if (t) {
            if (ec.vtex[i] != t.view) { [enc setVertexTexture:t.view atIndex:i]; ec.vtex[i] = t.view; }
            id<MTLSamplerState> sm = sampler(s, 16 + i, 0);
            if (ec.vsamp[i] != sm) { [enc setVertexSamplerState:sm atIndex:i]; ec.vsamp[i] = sm; }
        }
    }
    return (int)pe->streams | 0x10000;
}

// A static buffer's GPU copy, or nil when it must go through the ring (dynamic / keeps changing).
#define BUF_STREAMING 8u                                     // uploads after which a buffer counts as streaming
static id<MTLBuffer> static_buf(uint32_t b) __attribute__((ns_returns_not_retained));
static id<MTLBuffer> static_buf(uint32_t b) {
    if (G32(OBJ_F(b, B_USAGE)) & 0x200) return nil;            // D3DUSAGE_DYNAMIC
    uint32_t ups = G32(OBJ_F(b, B_UPS));
    if (ups >= BUF_STREAMING) return nil;
    __unsafe_unretained id<MTLBuffer> h = (__bridge id<MTLBuffer>)host_get(b);
    if (h && !G32(OBJ_F(b, B_DIRTY))) return h;
    uint32_t len = G32(OBJ_F(b, B_LEN));
    if (!len) return nil;
    P32(OBJ_F(b, B_DIRTY), 0); P32(OBJ_F(b, B_UPS), ups + 1);
    if (ups + 1 >= BUF_STREAMING) return nil;
    id<MTLBuffer> m = [dev newBufferWithBytes:MEM + G32(OBJ_F(b, B_DATA)) length:len options:MTLResourceStorageModeShared];
    host_set(b, m);
    return m;
}

static void bind_streams(D3DState *s, uint32_t streams, uint32_t first_vertex, uint32_t nverts, uint32_t inst_count) {
    for (int st = 0; st < 16; st++) {
        if (!(streams & (1u << st))) continue;
        uint32_t b = s->stream[st];
        if (!b) continue;
        uint32_t stride = s->stream_stride[st], len = G32(OBJ_F(b, B_LEN)), data = G32(OBJ_F(b, B_DATA));
        uint32_t start, n;
        if (s->stream_freq[st] & 0x80000000u) {
            uint32_t div = s->stream_freq[st] & 0x3FFFFFFFu;
            uint32_t rate = div ? div : 1;
            uint32_t ninst = (inst_count + rate - 1) / rate;
            start = s->stream_off[st];
            n = ninst * stride + 64;
        } else {
            start = s->stream_off[st] + first_vertex * stride;
            n = nverts * stride + 64;
        }
        if (start >= len) continue;
        if (start + n > len) n = len - start;
        __unsafe_unretained id<MTLBuffer> sb = (start & 3) ? nil : static_buf(b);
        if (sb) { ec_vbuf(sb, start, st); continue; }
        uint32_t off = ring_put(MEM + data + start, n);
        ec_vbuf(ring[ring_idx], off, st);
    }
}

static void d3d_backend_draw_impl(D3DState *s, uint32_t prim, uint32_t start, uint32_t count, int indexed, int32_t base_vertex, uint32_t min_index, uint32_t num_vertices) {
    s->draws++;
    if (!count) return;
    int r = setup_draw(s);
    if (!r) return;
    MTLPrimitiveType pt; uint32_t n;
    int kind = prim_info(prim, count, &pt, &n);
    if (!kind) return;
    if (!indexed) {
        bind_streams(s, (uint32_t)r & 0xFFFF, start, n, 1);
        if (kind == 2) {   // fan -> list indices
            uint16_t *ix = malloc(sizeof(uint16_t) * n);
            for (uint32_t i = 0; i < count; i++) { ix[3 * i] = 0; ix[3 * i + 1] = (uint16_t)(i + 1); ix[3 * i + 2] = (uint16_t)(i + 2); }
            uint32_t off = ring_put(ix, 2 * n); free(ix);
            [enc drawIndexedPrimitives:pt indexCount:n indexType:MTLIndexTypeUInt16 indexBuffer:ring[ring_idx] indexBufferOffset:off];
        } else [enc drawPrimitives:pt vertexStart:0 vertexCount:n];
    } else {
        uint32_t ib = s->indices;
        if (!ib) return;
        uint32_t inst_count = (s->stream_freq[0] & 0x40000000u) ? (s->stream_freq[0] & 0x3FFFFFFFu) : 1u;
        if (!inst_count) return;
        int i32 = G32(OBJ_F(ib, B_FMT)) == 102;
        uint32_t isz = i32 ? 4 : 2, idata = G32(OBJ_F(ib, B_DATA));
        // vertices the indices can touch: [base+min, base+min+num_vertices)
        bind_streams(s, (uint32_t)r & 0xFFFF, (uint32_t)(base_vertex + (int32_t)min_index), num_vertices, inst_count);
        if (kind == 2) return;   // indexed fans: not used by FNV
        __unsafe_unretained id<MTLBuffer> ibuf = ((start * isz) & 3) ? nil : static_buf(ib);
        uint32_t ioff = ibuf ? start * isz : ring_put(MEM + idata + start * isz, n * isz);
        [enc drawIndexedPrimitives:pt indexCount:n indexType:i32 ? MTLIndexTypeUInt32 : MTLIndexTypeUInt16 indexBuffer:ibuf ? ibuf : ring[ring_idx]
                 indexBufferOffset:ioff instanceCount:inst_count baseVertex:-(NSInteger)min_index baseInstance:0];
    }
    draws_done++;
}

static void d3d_backend_draw_up_impl(D3DState *s, uint32_t prim, uint32_t count, uint32_t vdata, uint32_t vstride, uint32_t idata, uint32_t ifmt, uint32_t min_index, uint32_t num_vertices) {
    s->draws++;
    if (!count || !vdata) return;
    uint32_t saved_stride = s->stream_stride[0];
    s->stream_stride[0] = vstride;
    int r = setup_draw(s);
    s->stream_stride[0] = saved_stride;
    if (!r) return;
    MTLPrimitiveType pt; uint32_t n;
    int kind = prim_info(prim, count, &pt, &n);
    if (!kind) return;
    uint32_t nv = idata ? min_index + num_vertices : n;
    uint32_t off = ring_put(MEM + vdata, nv * vstride);
    ec_vbuf(ring[ring_idx], off, 0);
    if (idata) {
        uint32_t isz = ifmt == 102 ? 4 : 2, ioff = ring_put(MEM + idata, n * isz);
        [enc drawIndexedPrimitives:pt indexCount:n indexType:isz == 4 ? MTLIndexTypeUInt32 : MTLIndexTypeUInt16 indexBuffer:ring[ring_idx] indexBufferOffset:ioff];
    } else if (kind == 2) {
        uint16_t *ix = malloc(sizeof(uint16_t) * n);
        for (uint32_t i = 0; i < count; i++) { ix[3 * i] = 0; ix[3 * i + 1] = (uint16_t)(i + 1); ix[3 * i + 2] = (uint16_t)(i + 2); }
        uint32_t ioff = ring_put(ix, 2 * n); free(ix);
        [enc drawIndexedPrimitives:pt indexCount:n indexType:MTLIndexTypeUInt16 indexBuffer:ring[ring_idx] indexBufferOffset:ioff];
    } else [enc drawPrimitives:pt vertexStart:0 vertexCount:n];
    draws_done++;
}

static void d3d_backend_clear_impl(D3DState *s, uint32_t count, uint32_t rects, uint32_t flags, uint32_t color, float z, uint32_t stencil) {
    (void)count; (void)rects;   // partial-rect clears are treated as full clears for now
    begin_pass(s, flags, color, z, stencil);
}

// ---- blits ------------------------------------------------------------------------------------------
static id<MTLRenderPipelineState> blit_pso[8];
static id<MTLRenderPipelineState> blit_pipeline(MTLPixelFormat pf) {
    static NSMutableDictionary *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    id<MTLRenderPipelineState> p = cache[@(pf)];
    if (p) return p;
    static id<MTLLibrary> lib;
    if (!lib) {
        NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "struct V { float4 p [[position]]; float2 uv; };\n"
            "vertex V bv(uint i [[vertex_id]], constant float4 &r [[buffer(0)]]) { float2 q = float2((i << 1) & 2, i & 2); V v; v.p = float4(q * 2.0 - 1.0, 0, 1); v.p.y = -v.p.y; v.uv = r.xy + q * r.zw; return v; }\n"
            "fragment float4 bf(V v [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) { return t.sample(s, v.uv); }\n";
        lib = [dev newLibraryWithSource:src options:copts error:nil];
    }
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"bv"]; d.fragmentFunction = [lib newFunctionWithName:@"bf"];
    d.colorAttachments[0].pixelFormat = pf;
    p = [dev newRenderPipelineStateWithDescriptor:d error:nil];
    cache[@(pf)] = p;
    (void)blit_pso;
    return p;
}
static void blit(id<MTLTexture> src, id<MTLTexture> dst, NSUInteger dlevel, NSUInteger dslice, int linear) {
    if (!src || !dst) return;
    end_pass(); ensure_cmd();
    if (src.sampleCount > 1) {   // MSAA resolve
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = src; rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
        rp.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
        rp.colorAttachments[0].resolveTexture = dst; rp.colorAttachments[0].resolveLevel = dlevel; rp.colorAttachments[0].resolveSlice = dslice;
        [[cmd renderCommandEncoderWithDescriptor:rp] endEncoding];
        return;
    }
    if (src.width == (dst.width >> dlevel) && src.height == (dst.height >> dlevel) && src.pixelFormat == dst.pixelFormat) {
        id<MTLBlitCommandEncoder> b = [cmd blitCommandEncoder];
        [b copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(src.width, src.height, 1)
                 toTexture:dst destinationSlice:dslice destinationLevel:dlevel destinationOrigin:MTLOriginMake(0, 0, 0)];
        [b endEncoding];
        return;
    }
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = dst; rp.colorAttachments[0].level = dlevel; rp.colorAttachments[0].slice = dslice;
    rp.colorAttachments[0].loadAction = MTLLoadActionDontCare; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [cmd renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:blit_pipeline(dst.pixelFormat)];
    float r[4] = {0, 0, 1, 1};
    [e setVertexBytes:r length:16 atIndex:0];
    [e setFragmentTexture:src atIndex:0];
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.minFilter = sd.magFilter = linear ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
    [e setFragmentSamplerState:[dev newSamplerStateWithDescriptor:sd] atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
}
static void d3d_backend_stretch_impl(D3DState *s, uint32_t src, uint32_t srect, uint32_t dst, uint32_t drect, uint32_t filter) {
    (void)s; (void)srect; (void)drect;
    NSUInteger sl, ss, dl, dsl;
    id<MTLTexture> a = surf_target(src, &sl, &ss), b = surf_target(dst, &dl, &dsl);
    if (!a || !b || a == b) return;
    if (a.pixelFormat >= MTLPixelFormatDepth16Unorm && a.pixelFormat <= MTLPixelFormatX32_Stencil8) {
        if (a.pixelFormat == b.pixelFormat && a.width == MAX(1u, b.width >> dl) &&
            a.height == MAX(1u, b.height >> dl) && a.sampleCount == 1 && b.sampleCount == 1)
            blit(a, b, dl, dsl, 0);
        return;
    }
    blit(a, b, dl, dsl, filter >= 2);
}
static void d3d_backend_colorfill_impl(D3DState *s, uint32_t surf, uint32_t rect, uint32_t color) {
    (void)rect;
    uint32_t saved[4]; memcpy(saved, s->rt, sizeof saved); uint32_t sd = s->ds;
    memset(s->rt, 0, sizeof s->rt); s->rt[0] = surf; s->ds = 0;
    begin_pass(s, 1, color, 1, 0);
    end_pass();
    memcpy(s->rt, saved, sizeof saved); s->ds = sd;
}
static void d3d_backend_readback_impl(D3DState *s, uint32_t rt, uint32_t dst) {
    (void)s;
    if (!rt || !dst || OBJ_KIND(rt) != K_SURF || OBJ_KIND(dst) != K_SURF) return;
    NSUInteger sl = 0, ss = 0;
    id<MTLTexture> src = surf_target(rt, &sl, &ss);
    if (!src) return;
    uint32_t dw = G32(OBJ_F(dst, S_W)), dh = G32(OBJ_F(dst, S_H)), dfmt = G32(OBJ_F(dst, S_FMT));
    if (!dw || !dh || d3d_fmt_block(dfmt)) return;
    Fmt f = fmt_map(dfmt);
    MTLPixelFormat pf = f.pf != MTLPixelFormatInvalid ? f.pf : src.pixelFormat;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:dw height:dh mipmapped:NO];
    td.storageMode = MTLStorageModeShared;
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> staging = [dev newTextureWithDescriptor:td];
    if (!staging) return;
    end_pass(); ensure_cmd();
    NSUInteger sw = MAX((NSUInteger)1, src.width >> sl), sh = MAX((NSUInteger)1, src.height >> sl);
    if (src.sampleCount == 1 && sw == dw && sh == dh && src.pixelFormat == pf) {
        id<MTLBlitCommandEncoder> b = [cmd blitCommandEncoder];
        [b copyFromTexture:src sourceSlice:ss sourceLevel:sl sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(dw, dh, 1)
                 toTexture:staging destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        [b endEncoding];
    } else {
        blit(src, staging, 0, 0, 1);
    }
    end_pass();
    [cmd commit];
    [cmd waitUntilCompleted];
    cmd = nil;
    uint32_t pitch = 0, sz = 0;
    uint8_t *out = d3d_surf_write_begin(dst, &pitch, &sz);
    if (out) {
        if (dfmt == 20) { // D3DFMT_R8G8B8 (24-bit BGR)
            size_t bpr = (size_t)dw * 4;
            uint8_t *tmp = malloc(bpr * dh);
            if (tmp) {
                [staging getBytes:tmp bytesPerRow:bpr fromRegion:MTLRegionMake2D(0, 0, dw, dh) mipmapLevel:0];
                for (uint32_t y = 0; y < dh && (uint64_t)(y + 1) * pitch <= sz; y++) {
                    const uint8_t *sp = tmp + (size_t)y * bpr;
                    uint8_t *dp = out + (size_t)y * pitch;
                    for (uint32_t x = 0; x < dw; x++) {
                        dp[0] = sp[0]; dp[1] = sp[1]; dp[2] = sp[2];
                        sp += 4; dp += 3;
                    }
                }
                free(tmp);
            }
        } else if ((uint64_t)pitch * dh <= sz) {
            [staging getBytes:out bytesPerRow:pitch fromRegion:MTLRegionMake2D(0, 0, dw, dh) mipmapLevel:0];
        }
    }
    d3d_surf_write_end(dst);
}

// ---- resource lifetime --------------------------------------------------------------------------------
// Shader prewarm: the game creates (nearly) all its shaders at boot. Translate each one's default
// variant now and compile it on background threads; the compiled result lands in Metal's on-disk
// shader cache, so the draw-time compile of that variant later is a cache hit instead of a stall of
// up to ~130 ms. Results are discarded here; FNV_NO_PREWARM=1 disables.
static void prewarm_shader(uint32_t o) {
    static int off = -1;
    static dispatch_queue_t q; static dispatch_semaphore_t width;
    if (off < 0) {
        off = getenv("FNV_NO_PREWARM") != NULL;
        q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
        width = dispatch_semaphore_create(4);
    }
    if (off) return;
    SMInfo info; char err[256];
    const uint32_t *tok = (const uint32_t *)(void *)(MEM + G32(OBJ_F(o, 0)));
    uint32_t ntok = G32(OBJ_F(o, 1));
    if (!sm_reflect(tok, ntok, &info, err, sizeof err)) return;
    info.depth_mask_in = 0;
    char *msl = sm_translate(tok, ntok, &info, NULL, 0, err, sizeof err);
    if (!msl) return;
    NSString *src = [NSString stringWithUTF8String:msl];
    free(msl);
    dispatch_async(q, ^{
        dispatch_semaphore_wait(width, DISPATCH_TIME_FOREVER);
        @autoreleasepool { (void)[dev newLibraryWithSource:src options:copts error:nil]; }
        dispatch_semaphore_signal(width);
    });
}
static void d3d_backend_created_impl(uint32_t o) {
    if (o && (OBJ_KIND(o) == K_VS || OBJ_KIND(o) == K_PS)) prewarm_shader(o);
}
static void d3d_backend_dirty_impl(uint32_t o) {
    if (!o) return;
    if (OBJ_KIND(o) == K_VB || OBJ_KIND(o) == K_IB) { P32(OBJ_F(o, B_DIRTY), 1); return; }
    if (OBJ_KIND(o) != K_SURF) return;
    P32(OBJ_F(o, S_DIRTY), 1);
    uint32_t cont = G32(OBJ_F(o, S_CONT));
    if (cont) P32(OBJ_F(cont, T_DIRTY), 1);
}
static void d3d_backend_release_impl(uint32_t o) {
    uint32_t k = OBJ_KIND(o);
    if (k != K_TEX && k != K_CUBE && k != K_SURF && k != K_VS && k != K_PS && k != K_VB && k != K_IB) return;
    uint32_t i = G32(host_field(o));
    if (!i) return;
    if (k == K_TEX || k == K_CUBE || k == K_SURF) { memset(ec.ftex, 0, sizeof ec.ftex); memset(ec.vtex, 0, sizeof ec.vtex); }
    if (k == K_VB || k == K_IB) memset(ec.vbuf, 0, sizeof ec.vbuf);
    host_drop(o);
}

// ---- window / present ---------------------------------------------------------------------------------
// FNV_DUMP_FRAMES="300,1200,..." : save those frames' backbuffer as frame_<n>.png (GPU readback)
static int want_dump(uint64_t f) {
    static char list[512]; static int init;
    if (!init) { init = 1; const char *e = getenv("FNV_DUMP_FRAMES"); if (e) snprintf(list, sizeof list, ",%s,", e); }
    if (!list[0]) return 0;
    char k[32]; snprintf(k, sizeof k, ",%llu,", (unsigned long long)f);
    return strstr(list, k) != NULL;
}
static void dump_png(id<MTLTexture> src, uint64_t frame) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:src.width height:src.height mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> t = [dev newTextureWithDescriptor:d];
    blit(src, t, 0, 0, 0);
    end_pass();
    [cmd commit]; [cmd waitUntilCompleted]; cmd = nil; ensure_cmd();
    size_t w = t.width, h = t.height, bpr = w * 4;
    uint8_t *px = malloc(bpr * h);
    [t getBytes:px bytesPerRow:bpr fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, w, h, 8, bpr, cs, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    char path[512];
    const char *dir = getenv("FNV_DUMP_DIR");
    if (dir && dir[0]) snprintf(path, sizeof path, "%s/frame_%llu.png", dir, (unsigned long long)frame);
    else snprintf(path, sizeof path, "frame_%llu.png", (unsigned long long)frame);
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL(url, (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    CGImageDestinationAddImage(dst, img, NULL); CGImageDestinationFinalize(dst);
    CFRelease(dst); CFRelease(url); CGImageRelease(img); CGContextRelease(ctx); CGColorSpaceRelease(cs); free(px);
    fprintf(stderr, "[metal] dumped %s (%zux%zu)\n", path, w, h);
}

// ---- recorder ---------------------------------------------------------------------------------------------
// FNV_RECORD=<file.mov> : every presented frame is scaled on the GPU into a pooled CVPixelBuffer and
// appended to a hardware H.264 stream with its wall-clock timestamp. Fragmented, so a killed run still
// leaves a playable file. FNV_RECORD_SIZE=WxH (default 1920x1080).
static AVAssetWriter *rec_writer;
static AVAssetWriterInput *rec_input;
static AVAssetWriterInputPixelBufferAdaptor *rec_adaptor;
static CVMetalTextureCacheRef rec_cache;
static dispatch_queue_t rec_q;
static uint64_t rec_t0, rec_frames, rec_dropped;
static int rec_w, rec_h, rec_on;
static void rec_finish(void) {
    if (!rec_on) return;
    rec_on = 0;
    dispatch_sync(rec_q, ^{});
    [rec_input markAsFinished];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [rec_writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(done); }];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC));
    fprintf(stderr, "[rec] finished %s: %llu frames, %llu dropped, status %ld\n", rec_writer.outputURL.path.UTF8String,
            (unsigned long long)rec_frames, (unsigned long long)rec_dropped, (long)rec_writer.status);
}
static void rec_init(void) {
    const char *path = getenv("FNV_RECORD");
    if (!path) return;
    rec_w = 1920; rec_h = 1080;
    const char *sz = getenv("FNV_RECORD_SIZE");
    if (sz) sscanf(sz, "%dx%d", &rec_w, &rec_h);
    NSURL *url = [NSURL fileURLWithPath:@(path)];
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
    NSError *err = nil;
    rec_writer = [AVAssetWriter assetWriterWithURL:url fileType:AVFileTypeQuickTimeMovie error:&err];
    if (!rec_writer) { fprintf(stderr, "[rec] %s\n", err.localizedDescription.UTF8String); return; }
    rec_writer.movieFragmentInterval = CMTimeMake(5, 1);
    NSDictionary *vs = @{AVVideoCodecKey: AVVideoCodecTypeH264, AVVideoWidthKey: @(rec_w), AVVideoHeightKey: @(rec_h),
                         AVVideoCompressionPropertiesKey: @{AVVideoAverageBitRateKey: @(16000000), AVVideoExpectedSourceFrameRateKey: @60,
                                                            AVVideoMaxKeyFrameIntervalKey: @120}};
    rec_input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:vs];
    rec_input.expectsMediaDataInRealTime = YES;
    rec_adaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:rec_input
        sourcePixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA), (id)kCVPixelBufferWidthKey: @(rec_w),
                                      (id)kCVPixelBufferHeightKey: @(rec_h), (id)kCVPixelBufferMetalCompatibilityKey: @YES,
                                      (id)kCVPixelBufferIOSurfacePropertiesKey: @{}}];
    [rec_writer addInput:rec_input];
    if (![rec_writer startWriting]) { fprintf(stderr, "[rec] startWriting: %s\n", rec_writer.error.localizedDescription.UTF8String); return; }
    [rec_writer startSessionAtSourceTime:kCMTimeZero];
    CVMetalTextureCacheCreate(NULL, NULL, dev, NULL, &rec_cache);
    rec_q = dispatch_queue_create("fnv.rec", DISPATCH_QUEUE_SERIAL);
    rec_on = 1;
    atexit(rec_finish);
    fprintf(stderr, "[rec] recording %dx%d to %s\n", rec_w, rec_h, path);
}
// called inside present, before the command buffer is committed
static void rec_frame(id<MTLTexture> src) {
    if (!rec_on || !src || src.sampleCount > 1) return;
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (!rec_t0) rec_t0 = now;
    if (!rec_input.readyForMoreMediaData || !rec_adaptor.pixelBufferPool) { rec_dropped++; return; }
    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(NULL, rec_adaptor.pixelBufferPool, &pb) != kCVReturnSuccess) { rec_dropped++; return; }
    CVMetalTextureRef mt = NULL;
    CVMetalTextureCacheCreateTextureFromImage(NULL, rec_cache, pb, NULL, MTLPixelFormatBGRA8Unorm, (size_t)rec_w, (size_t)rec_h, 0, &mt);
    id<MTLTexture> dst = mt ? CVMetalTextureGetTexture(mt) : nil;
    if (!dst) { if (mt) CFRelease(mt); CVPixelBufferRelease(pb); rec_dropped++; return; }
    blit(src, dst, 0, 0, 1);
    CMTime t = CMTimeMake((int64_t)((now - rec_t0) / 1000), 1000000);
    [cmd addCompletedHandler:^(id<MTLCommandBuffer> b) {
        (void)b;
        dispatch_async(rec_q, ^{
            if (rec_on && rec_input.readyForMoreMediaData && [rec_adaptor appendPixelBuffer:pb withPresentationTime:t]) rec_frames++;
            else rec_dropped++;
            CFRelease(mt); CVPixelBufferRelease(pb);
        });
    }];
}

// ---- post-process (SMAA 1x) & MetalFX Spatial upscaling -----------------------------------------------
static id<MTLTexture> resolve_1x_tex;
static id<MTLTexture> resolve_to_1x(id<MTLTexture> src) {
    if (!src || src.sampleCount <= 1) return src;
    if (!resolve_1x_tex || resolve_1x_tex.width != src.width || resolve_1x_tex.height != src.height) {
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat width:src.width height:src.height mipmapped:NO];
        d.storageMode = MTLStorageModePrivate;
        d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        resolve_1x_tex = [dev newTextureWithDescriptor:d];
    }
    blit(src, resolve_1x_tex, 0, 0, 0);
    return resolve_1x_tex;
}

static id<MTLRenderPipelineState> smaa_edge_pso, smaa_weight_pso, smaa_blend_pso;
static id<MTLSamplerState> smaa_nearest_samp, smaa_linear_samp;
static id<MTLTexture> smaa_edges, smaa_weights, smaa_out;
static int smaa_init_failed;

static int smaa_ensure_pipelines(void) {
    if (smaa_init_failed) return 0;
    if (smaa_edge_pso) return 1;
    NSString *src =
        @"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct SV { float4 p [[position]]; float2 uv; };\n"
        "vertex SV smaa_vs(uint i [[vertex_id]]) {\n"
        "  float2 q = float2((i << 1) & 2, i & 2);\n"
        "  SV v; v.p = float4(q * 2.0 - 1.0, 0.0, 1.0); v.p.y = -v.p.y; v.uv = q; return v;\n"
        "}\n"
        "static inline float luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }\n"
        "static inline float edge_delta(float3 a, float3 b) {\n"
        "  float3 d = abs(a - b);\n"
        "  return max(abs(luma(a) - luma(b)), 0.5 * max(d.r, max(d.g, d.b)));\n"
        "}\n"
        "fragment float2 smaa_edge_fs(SV v [[stage_in]], texture2d<float> col [[texture(0)]], sampler sN [[sampler(0)]]) {\n"
        "  float2 px = 1.0 / float2(col.get_width(), col.get_height());\n"
        "  float3 c = col.sample(sN, v.uv).rgb;\n"
        "  float3 cL = col.sample(sN, v.uv + float2(-px.x, 0.0)).rgb;\n"
        "  float3 cT = col.sample(sN, v.uv + float2(0.0, -px.y)).rgb;\n"
        "  float dL = edge_delta(c, cL);\n"
        "  float dT = edge_delta(c, cT);\n"
        "  if (dL < 0.08 && dT < 0.08) return float2(0.0);\n"
        "  float3 cR = col.sample(sN, v.uv + float2(px.x, 0.0)).rgb;\n"
        "  float3 cB = col.sample(sN, v.uv + float2(0.0, px.y)).rgb;\n"
        "  float3 cLL = col.sample(sN, v.uv + float2(-2.0 * px.x, 0.0)).rgb;\n"
        "  float3 cTT = col.sample(sN, v.uv + float2(0.0, -2.0 * px.y)).rgb;\n"
        "  float dR = edge_delta(c, cR), dB = edge_delta(c, cB);\n"
        "  float dLL = edge_delta(cL, cLL), dTT = edge_delta(cT, cTT);\n"
        "  float maxCross = max(max(dL, dR), max(dT, dB));\n"
        "  float eH = (dT >= 0.08 && dT >= 0.5 * max(maxCross, dTT)) ? 1.0 : 0.0;\n"
        "  float eV = (dL >= 0.08 && dL >= 0.5 * max(maxCross, dLL)) ? 1.0 : 0.0;\n"
        "  return float2(eH, eV);\n"
        "}\n"
        "fragment float4 smaa_weight_fs(SV v [[stage_in]], texture2d<float> edges [[texture(0)]], sampler sN [[sampler(0)]]) {\n"
        "  float2 px = 1.0 / float2(edges.get_width(), edges.get_height());\n"
        "  float2 e = edges.sample(sN, v.uv).rg;\n"
        "  float4 w = float4(0.0);\n"
        "  if (e.r > 0.5) {\n"
        "    float d1 = 0.0, d2 = 0.0;\n"
        "    for (int k = 1; k < 16; k++) {\n"
        "      if (edges.sample(sN, v.uv + float2(-float(k) * px.x, 0.0)).r <= 0.5) break;\n"
        "      d1 += 1.0;\n"
        "    }\n"
        "    for (int k = 1; k < 16; k++) {\n"
        "      if (edges.sample(sN, v.uv + float2(float(k) * px.x, 0.0)).r <= 0.5) break;\n"
        "      d2 += 1.0;\n"
        "    }\n"
        "    float cTL = edges.sample(sN, v.uv + float2(-d1 * px.x, -px.y)).g;\n"
        "    float cBL = edges.sample(sN, v.uv + float2(-d1 * px.x, 0.0)).g;\n"
        "    float cTR = edges.sample(sN, v.uv + float2((d2 + 1.0) * px.x, -px.y)).g;\n"
        "    float cBR = edges.sample(sN, v.uv + float2((d2 + 1.0) * px.x, 0.0)).g;\n"
        "    float y1 = (cBL > 0.5 && cTL < 0.5) ? 0.5 : ((cTL > 0.5 && cBL < 0.5) ? -0.5 : 0.0);\n"
        "    float y2 = (cBR > 0.5 && cTR < 0.5) ? 0.5 : ((cTR > 0.5 && cBR < 0.5) ? -0.5 : 0.0);\n"
        "    float len = d1 + d2 + 1.0;\n"
        "    float y = mix(y1, y2, (d1 + 0.5) / len);\n"
        "    if (y1 * y2 > 0.0) y *= 0.25;\n"
        "    w.r = max(y, 0.0); w.g = max(-y, 0.0);\n"
        "  }\n"
        "  if (e.g > 0.5) {\n"
        "    float d1 = 0.0, d2 = 0.0;\n"
        "    for (int k = 1; k < 16; k++) {\n"
        "      if (edges.sample(sN, v.uv + float2(0.0, -float(k) * px.y)).g <= 0.5) break;\n"
        "      d1 += 1.0;\n"
        "    }\n"
        "    for (int k = 1; k < 16; k++) {\n"
        "      if (edges.sample(sN, v.uv + float2(0.0, float(k) * px.y)).g <= 0.5) break;\n"
        "      d2 += 1.0;\n"
        "    }\n"
        "    float cLT = edges.sample(sN, v.uv + float2(-px.x, -d1 * px.y)).r;\n"
        "    float cRT = edges.sample(sN, v.uv + float2(0.0, -d1 * px.y)).r;\n"
        "    float cLB = edges.sample(sN, v.uv + float2(-px.x, (d2 + 1.0) * px.y)).r;\n"
        "    float cRB = edges.sample(sN, v.uv + float2(0.0, (d2 + 1.0) * px.y)).r;\n"
        "    float x1 = (cRT > 0.5 && cLT < 0.5) ? 0.5 : ((cLT > 0.5 && cRT < 0.5) ? -0.5 : 0.0);\n"
        "    float x2 = (cRB > 0.5 && cLB < 0.5) ? 0.5 : ((cLB > 0.5 && cRB < 0.5) ? -0.5 : 0.0);\n"
        "    float len = d1 + d2 + 1.0;\n"
        "    float x = mix(x1, x2, (d1 + 0.5) / len);\n"
        "    if (x1 * x2 > 0.0) x *= 0.25;\n"
        "    w.b = max(x, 0.0); w.a = max(-x, 0.0);\n"
        "  }\n"
        "  return w;\n"
        "}\n"
        "fragment float4 smaa_blend_fs(SV v [[stage_in]], texture2d<float> col [[texture(0)]],\n"
        "                              texture2d<float> weights [[texture(1)]],\n"
        "                              sampler sN [[sampler(0)]], sampler sL [[sampler(1)]]) {\n"
        "  float2 px = 1.0 / float2(col.get_width(), col.get_height());\n"
        "  float2 w0 = weights.sample(sN, v.uv).rb;\n"
        "  float wTop = w0.x, wLeft = w0.y;\n"
        "  float wBot = weights.sample(sN, v.uv + float2(0.0, px.y)).g;\n"
        "  float wRight = weights.sample(sN, v.uv + float2(px.x, 0.0)).a;\n"
        "  float hMax = max(wTop, wBot), vMax = max(wLeft, wRight);\n"
        "  if (hMax < 1e-5 && vMax < 1e-5) return col.sample(sN, v.uv);\n"
        "  if (hMax > vMax) {\n"
        "    float s = wTop + wBot;\n"
        "    float4 c1 = col.sample(sL, v.uv + float2(0.0, -wTop * px.y));\n"
        "    float4 c2 = col.sample(sL, v.uv + float2(0.0, wBot * px.y));\n"
        "    return (c1 * wTop + c2 * wBot) / s;\n"
        "  } else {\n"
        "    float s = wLeft + wRight;\n"
        "    float4 c1 = col.sample(sL, v.uv + float2(-wLeft * px.x, 0.0));\n"
        "    float4 c2 = col.sample(sL, v.uv + float2(wRight * px.x, 0.0));\n"
        "    return (c1 * wLeft + c2 * wRight) / s;\n"
        "  }\n"
        "}\n";
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:src options:copts error:&err];
    if (!lib) {
        fprintf(stderr, "[smaa] shader compile error: %s\n", err.localizedDescription.UTF8String);
        smaa_init_failed = 1;
        return 0;
    }
    id<MTLFunction> vs = [lib newFunctionWithName:@"smaa_vs"];
    id<MTLFunction> fEdge = [lib newFunctionWithName:@"smaa_edge_fs"];
    id<MTLFunction> fWeight = [lib newFunctionWithName:@"smaa_weight_fs"];
    id<MTLFunction> fBlend = [lib newFunctionWithName:@"smaa_blend_fs"];

    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = vs;
    d.fragmentFunction = fEdge;
    d.colorAttachments[0].pixelFormat = MTLPixelFormatRG8Unorm;
    smaa_edge_pso = [dev newRenderPipelineStateWithDescriptor:d error:&err];
    if (!smaa_edge_pso) {
        fprintf(stderr, "[smaa] edge PSO error: %s\n", err.localizedDescription.UTF8String);
        smaa_init_failed = 1;
        return 0;
    }
    d.fragmentFunction = fWeight;
    d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    smaa_weight_pso = [dev newRenderPipelineStateWithDescriptor:d error:&err];
    if (!smaa_weight_pso) {
        fprintf(stderr, "[smaa] weight PSO error: %s\n", err.localizedDescription.UTF8String);
        smaa_edge_pso = nil; smaa_init_failed = 1;
        return 0;
    }
    d.fragmentFunction = fBlend;
    d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    smaa_blend_pso = [dev newRenderPipelineStateWithDescriptor:d error:&err];
    if (!smaa_blend_pso) {
        fprintf(stderr, "[smaa] blend PSO error: %s\n", err.localizedDescription.UTF8String);
        smaa_edge_pso = nil; smaa_weight_pso = nil; smaa_init_failed = 1;
        return 0;
    }

    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
    sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest;
    smaa_nearest_samp = [dev newSamplerStateWithDescriptor:sd];
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
    smaa_linear_samp = [dev newSamplerStateWithDescriptor:sd];
    return 1;
}

static id<MTLTexture> smaa_make_rt(MTLPixelFormat pf, NSUInteger w, NSUInteger h) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:w height:h mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    return [dev newTextureWithDescriptor:td];
}

static id<MTLTexture> run_smaa(id<MTLTexture> src) {
    if (!src || src.pixelFormat != MTLPixelFormatBGRA8Unorm || !smaa_ensure_pipelines()) return src;
    NSUInteger w = src.width, h = src.height;
    if (!smaa_edges || smaa_edges.width != w || smaa_edges.height != h) {
        smaa_edges = smaa_make_rt(MTLPixelFormatRG8Unorm, w, h);
        smaa_weights = smaa_make_rt(MTLPixelFormatRGBA8Unorm, w, h);
        smaa_out = smaa_make_rt(MTLPixelFormatBGRA8Unorm, w, h);
    }
    if (!smaa_edges || !smaa_weights || !smaa_out) return src;
    end_pass(); ensure_cmd();

    // Pass 1: Edge detection
    MTLRenderPassDescriptor *rp1 = [MTLRenderPassDescriptor renderPassDescriptor];
    rp1.colorAttachments[0].texture = smaa_edges;
    rp1.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rp1.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e1 = [cmd renderCommandEncoderWithDescriptor:rp1];
    [e1 setRenderPipelineState:smaa_edge_pso];
    [e1 setFragmentTexture:src atIndex:0];
    [e1 setFragmentSamplerState:smaa_nearest_samp atIndex:0];
    [e1 drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e1 endEncoding];

    // Pass 2: Blending weights
    MTLRenderPassDescriptor *rp2 = [MTLRenderPassDescriptor renderPassDescriptor];
    rp2.colorAttachments[0].texture = smaa_weights;
    rp2.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rp2.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e2 = [cmd renderCommandEncoderWithDescriptor:rp2];
    [e2 setRenderPipelineState:smaa_weight_pso];
    [e2 setFragmentTexture:smaa_edges atIndex:0];
    [e2 setFragmentSamplerState:smaa_nearest_samp atIndex:0];
    [e2 drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e2 endEncoding];

    // Pass 3: Neighborhood blending
    MTLRenderPassDescriptor *rp3 = [MTLRenderPassDescriptor renderPassDescriptor];
    rp3.colorAttachments[0].texture = smaa_out;
    rp3.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rp3.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e3 = [cmd renderCommandEncoderWithDescriptor:rp3];
    [e3 setRenderPipelineState:smaa_blend_pso];
    [e3 setFragmentTexture:src atIndex:0];
    [e3 setFragmentTexture:smaa_weights atIndex:1];
    [e3 setFragmentSamplerState:smaa_nearest_samp atIndex:0];
    [e3 setFragmentSamplerState:smaa_linear_samp atIndex:1];
    [e3 drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e3 endEncoding];

    return smaa_out;
}

static id<MTLRenderPipelineState> fxaa_pso;
static id<MTLSamplerState> fxaa_samp;
static id<MTLTexture> fxaa_out;
static int fxaa_init_failed;

static int fxaa_ensure_pipelines(void) {
    if (fxaa_init_failed) return 0;
    if (fxaa_pso) return fxaa_samp != nil;
    NSString *src =
        @"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct SV { float4 p [[position]]; float2 uv; };\n"
        "vertex SV fxaa_vs(uint i [[vertex_id]]) {\n"
        "  float2 q = float2((i << 1) & 2, i & 2);\n"
        "  SV v; v.p = float4(q * 2.0 - 1.0, 0.0, 1.0); v.p.y = -v.p.y; v.uv = q; return v;\n"
        "}\n"
        "static inline float fxaa_luma(float3 c) { return dot(c, float3(0.299, 0.587, 0.114)); }\n"
        "fragment float4 fxaa_fs(SV v [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {\n"
        "  float2 rcp = 1.0 / float2(tex.get_width(), tex.get_height());\n"
        "  float3 rgbM  = tex.sample(s, v.uv).rgb;\n"
        "  float3 rgbNW = tex.sample(s, v.uv + float2(-1.0, -1.0) * rcp).rgb;\n"
        "  float3 rgbNE = tex.sample(s, v.uv + float2( 1.0, -1.0) * rcp).rgb;\n"
        "  float3 rgbSW = tex.sample(s, v.uv + float2(-1.0,  1.0) * rcp).rgb;\n"
        "  float3 rgbSE = tex.sample(s, v.uv + float2( 1.0,  1.0) * rcp).rgb;\n"
        "  float lM = fxaa_luma(rgbM), lNW = fxaa_luma(rgbNW), lNE = fxaa_luma(rgbNE);\n"
        "  float lSW = fxaa_luma(rgbSW), lSE = fxaa_luma(rgbSE);\n"
        "  float lMin = min(lM, min(min(lNW, lNE), min(lSW, lSE)));\n"
        "  float lMax = max(lM, max(max(lNW, lNE), max(lSW, lSE)));\n"
        "  if (lMax - lMin < max(0.0312, lMax * 0.125)) return float4(rgbM, 1.0);\n"
        "  float2 dir = float2(-((lNW + lNE) - (lSW + lSE)), ((lNW + lSW) - (lNE + lSE)));\n"
        "  float dirReduce = max((lNW + lNE + lSW + lSE) * (0.25 * (1.0 / 8.0)), 1.0 / 128.0);\n"
        "  float rcpDirMin = 1.0 / (min(abs(dir.x), abs(dir.y)) + dirReduce);\n"
        "  dir = clamp(dir * rcpDirMin, float2(-8.0), float2(8.0)) * rcp;\n"
        "  float3 rgbA = 0.5 * (tex.sample(s, v.uv + dir * (1.0 / 3.0 - 0.5)).rgb +\n"
        "                      tex.sample(s, v.uv + dir * (2.0 / 3.0 - 0.5)).rgb);\n"
        "  float3 rgbB = rgbA * 0.5 + 0.25 * (tex.sample(s, v.uv + dir * -0.5).rgb +\n"
        "                                     tex.sample(s, v.uv + dir *  0.5).rgb);\n"
        "  float lB = fxaa_luma(rgbB);\n"
        "  return float4((lB < lMin || lB > lMax) ? rgbA : rgbB, 1.0);\n"
        "}\n";
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:src options:copts error:&err];
    if (!lib) {
        fprintf(stderr, "[fxaa] shader compile error: %s\n", err.localizedDescription.UTF8String);
        fxaa_init_failed = 1;
        return 0;
    }
    id<MTLFunction> vs = [lib newFunctionWithName:@"fxaa_vs"];
    id<MTLFunction> fs = [lib newFunctionWithName:@"fxaa_fs"];
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = vs;
    d.fragmentFunction = fs;
    d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    fxaa_pso = [dev newRenderPipelineStateWithDescriptor:d error:&err];
    if (!fxaa_pso) {
        fprintf(stderr, "[fxaa] pipeline error: %s\n", err.localizedDescription.UTF8String);
        fxaa_init_failed = 1;
        return 0;
    }
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
    sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
    fxaa_samp = [dev newSamplerStateWithDescriptor:sd];
    if (!fxaa_samp) { fxaa_pso = nil; fxaa_init_failed = 1; return 0; }
    return 1;
}

static id<MTLTexture> run_fxaa(id<MTLTexture> src) {
    if (!src || src.pixelFormat != MTLPixelFormatBGRA8Unorm || !fxaa_ensure_pipelines()) return src;
    NSUInteger w = src.width, h = src.height;
    if (!fxaa_out || fxaa_out.width != w || fxaa_out.height != h) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                      width:w height:h mipmapped:NO];
        td.storageMode = MTLStorageModePrivate;
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        fxaa_out = [dev newTextureWithDescriptor:td];
    }
    if (!fxaa_out) return src;
    end_pass(); ensure_cmd();
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = fxaa_out;
    rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [cmd renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:fxaa_pso];
    [e setFragmentTexture:src atIndex:0];
    [e setFragmentSamplerState:fxaa_samp atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
    return fxaa_out;
}

static const char *aa_name(void) {
    int aa = fnv_graphics_aa();
    return aa == 1 ? "smaa" : (aa == 2 ? "fxaa" : "off");
}

static id<MTLFXSpatialScaler> mfx_scaler;
static id<MTLTexture> mfx_out;
// Headless bilinear parity: a windowed present scales the final texture into the
// drawable; with no drawable (benchmarks/dumps) we scale it explicitly so both
// upscalers pay for an output-resolution pass and dumps are output-sized.
static id<MTLTexture> linear_out;
static NSUInteger linear_out_w, linear_out_h;
static NSUInteger mfx_in_w, mfx_in_h, mfx_out_w, mfx_out_h;
static MTLPixelFormat mfx_in_fmt;

static id<MTLTexture> run_metalfx_spatial(id<MTLTexture> src, NSUInteger outW, NSUInteger outH) {
    if (!src || !outW || !outH) return nil;
    if (![MTLFXSpatialScalerDescriptor supportsDevice:dev]) return nil;
    if (!mfx_scaler || mfx_in_w != src.width || mfx_in_h != src.height ||
        mfx_out_w != outW || mfx_out_h != outH || mfx_in_fmt != src.pixelFormat) {
        MTLFXSpatialScalerDescriptor *desc = [MTLFXSpatialScalerDescriptor new];
        desc.colorTextureFormat = src.pixelFormat;
        desc.outputTextureFormat = MTLPixelFormatBGRA8Unorm;
        desc.inputWidth = src.width;
        desc.inputHeight = src.height;
        desc.outputWidth = outW;
        desc.outputHeight = outH;
        desc.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
        mfx_scaler = [desc newSpatialScalerWithDevice:dev];
        if (!mfx_scaler) {
            fprintf(stderr, "[metalfx] failed to create spatial scaler (%lux%lu -> %lux%lu)\n",
                    (unsigned long)src.width, (unsigned long)src.height, (unsigned long)outW, (unsigned long)outH);
            return nil;
        }
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                      width:outW height:outH mipmapped:NO];
        td.storageMode = MTLStorageModePrivate;
        td.usage = mfx_scaler.outputTextureUsage | MTLTextureUsageShaderRead;
        mfx_out = [dev newTextureWithDescriptor:td];
        if (!mfx_out) { mfx_scaler = nil; return nil; }
        mfx_in_w = src.width; mfx_in_h = src.height;
        mfx_out_w = outW; mfx_out_h = outH;
        mfx_in_fmt = src.pixelFormat;
        fprintf(stderr, "[metalfx] spatial scaler %lux%lu -> %lux%lu (AA=%s)\n",
                (unsigned long)mfx_in_w, (unsigned long)mfx_in_h, (unsigned long)mfx_out_w, (unsigned long)mfx_out_h,
                aa_name());
    }
    MTLTextureUsage req = mfx_scaler.colorTextureUsage;
    if ((src.usage & req) != req) return nil;
    end_pass(); ensure_cmd();
    mfx_scaler.colorTexture = src;
    mfx_scaler.inputContentWidth = src.width;
    mfx_scaler.inputContentHeight = src.height;
    mfx_scaler.outputTexture = mfx_out;
    [mfx_scaler encodeToCommandBuffer:cmd];
    return mfx_out;
}

void d3d_backend_init(D3DState *s) {
    trace_metal = getenv("FNV_TRACE_METAL") != NULL;
    dev = MTLCreateSystemDefaultDevice();
    queue = [dev newCommandQueue];
    copts = [MTLCompileOptions new];
    if (@available(macOS 15.0, iOS 18.0, *)) {
        copts.mathMode = MTLMathModeSafe;
    }

    pipe_tab = calloc(PIPE_TAB, sizeof *pipe_tab); pipe_keep = [NSMutableArray array];
    samp_keep = [NSMutableArray array]; dss_keep = [NSMutableArray array];
    for (int i = 0; i < 3; i++) ring[i] = [dev newBufferWithLength:RING_SIZE options:MTLResourceStorageModeShared | MTLResourceCPUCacheModeWriteCombined];
    if (!dev || !queue || !ring[0] || !ring[1] || !ring[2]) {
        fprintf(stderr, "[metal] Metal device, queue, or upload buffers unavailable\n");
        abort();
    }
    rec_init();
    inflight = dispatch_semaphore_create(3);

    unsigned outW = fnv_output_width() ? fnv_output_width() : s->width;
    unsigned outH = fnv_output_height() ? fnv_output_height() : s->height;
    if (getenv("FNV_HEADLESS")) {          // offscreen: real rendering, no window, no focus change
        fprintf(stderr, "[metal] %s, offscreen %ux%u -> %ux%u (upscaler=%s, aa=%s)\n",
                dev.name.UTF8String, s->width, s->height, outW, outH,
                fnv_graphics_upscaler() == 1 ? "metalfx" : "bilinear",
                aa_name());
        dispatch_semaphore_wait(inflight, DISPATCH_TIME_FOREVER);
        return;
    }
    layer = fnv_surface(dev, CGSizeMake(outW, outH));
    if (!layer) { fprintf(stderr, "[metal] no Metal surface\n"); abort(); }
    dispatch_semaphore_wait(inflight, DISPATCH_TIME_FOREVER);
}
static void d3d_backend_resize_impl(D3DState *s) {
    unsigned outW = fnv_output_width() ? fnv_output_width() : s->width;
    unsigned outH = fnv_output_height() ? fnv_output_height() : s->height;
    fnv_resize_surface(CGSizeMake(outW, outH));
}

void host_pump_events(void) { fnv_wait_active(); }

static void d3d_backend_present_impl(D3DState *s) {
    @autoreleasepool {
        uint64_t present_start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        uint64_t present_thread = 0; pthread_threadid_np(NULL, &present_thread);
        perf_add_interval(&frame_perf, present_start, perf_thread_cpu_ns(), present_thread);
        end_pass(); ensure_cmd();
        uint64_t drawable_start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        id<CAMetalDrawable> drawable = layer ? [layer nextDrawable] : nil;
        frame_perf.drawable_ns += clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - drawable_start;
        HTex *bb = host_tex(s->backbuffer);
        NSUInteger outW = drawable ? drawable.texture.width : (fnv_output_width() ? fnv_output_width() : s->width);
        NSUInteger outH = drawable ? drawable.texture.height : (fnv_output_height() ? fnv_output_height() : s->height);
        id<MTLTexture> final_tex = bb ? bb.tex : nil;
        if (final_tex && final_tex.sampleCount > 1) final_tex = resolve_to_1x(final_tex);
        if (final_tex && fnv_graphics_aa() == 1) final_tex = run_smaa(final_tex) ?: final_tex;
        else if (final_tex && fnv_graphics_aa() == 2) final_tex = run_fxaa(final_tex) ?: final_tex;
        if (final_tex && (final_tex.width != outW || final_tex.height != outH) && fnv_graphics_upscaler() == 1) {
            id<MTLTexture> up = run_metalfx_spatial(final_tex, outW, outH);
            if (up) final_tex = up;
        }
        if (!drawable && final_tex && fnv_graphics_upscaler() != 1 &&
            (final_tex.width != outW || final_tex.height != outH)) {
            if (!linear_out || linear_out_w != outW || linear_out_h != outH) {
                MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                              width:outW height:outH mipmapped:NO];
                td.storageMode = MTLStorageModePrivate;
                td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
                linear_out = [dev newTextureWithDescriptor:td];
                linear_out_w = outW; linear_out_h = outH;
            }
            if (linear_out) { blit(final_tex, linear_out, 0, 0, 1); final_tex = linear_out; }
        }
        if (final_tex && (want_dump(s->frames + 1) || input_take_dump_request())) dump_png(final_tex, s->frames + 1);
        if (drawable && final_tex) blit(final_tex, drawable.texture, 0, 0, 1);
        if (final_tex) rec_frame(final_tex);
        if (drawable) {
            if (!getenv("FNV_NOVSYNC") && fnv_display_refresh() > 62) {
                [cmd presentDrawable:drawable afterMinimumDuration:1.0 / 60.5];
            } else {
                [cmd presentDrawable:drawable];
            }
        }
        dispatch_semaphore_t sem = inflight;
        [cmd addCompletedHandler:^(id<MTLCommandBuffer> b) { perf_gpu_completed(b); dispatch_semaphore_signal(sem); }];
        [cmd commit];
        cmd = nil;
        uint64_t inflight_start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        dispatch_semaphore_wait(inflight, DISPATCH_TIME_FOREVER);
        frame_perf.inflight_ns += clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - inflight_start;
        frame_perf.present_ns += clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - present_start;
        frame_perf.presents++;
        if (ring_off > frame_perf.upload_peak) frame_perf.upload_peak = ring_off;
        ring_idx = (ring_idx + 1) % 3; ring_off = 0;
        // stats
        static uint64_t t0, f0, d0;
        uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        if (!t0) t0 = now;
        s->frames++;
        { static uint64_t prev_draws; input_frame_draws(s->draws - prev_draws); prev_draws = s->draws; }
        input_script_tick(s->frames);
        if (now - t0 >= 2000000000ull) {
            double sec = (double)(now - t0) / 1e9;
            fprintf(stderr, "[metal] frame %llu: %.1f fps, %.0f draws/frame (%.0f rendered), %lu pipelines, ff-skipped %llu\n",
                    (unsigned long long)s->frames, (double)(s->frames - f0) / sec, (double)(s->draws - d0) / (double)(s->frames - f0),
                    (double)draws_done / (double)(s->frames - f0), (unsigned long)pipe_count, (unsigned long long)ff_skipped);
            perf_report();
            t0 = now; f0 = s->frames; d0 = s->draws; draws_done = 0;
        }
    }
}

// ---- locked public entry points -----------------------------------------------------------------------
void d3d_backend_draw(D3DState *s, uint32_t p, uint32_t a, uint32_t n, int ix, int32_t bv, uint32_t mi, uint32_t nv) { LOCKED_BEGIN d3d_backend_draw_impl(s, p, a, n, ix, bv, mi, nv); LOCKED_END }
void d3d_backend_draw_up(D3DState *s, uint32_t p, uint32_t n, uint32_t vd, uint32_t vs, uint32_t id, uint32_t ifm, uint32_t mi, uint32_t nv) { LOCKED_BEGIN d3d_backend_draw_up_impl(s, p, n, vd, vs, id, ifm, mi, nv); LOCKED_END }
void d3d_backend_clear(D3DState *s, uint32_t c, uint32_t r, uint32_t f, uint32_t col, float z, uint32_t st) { LOCKED_BEGIN d3d_backend_clear_impl(s, c, r, f, col, z, st); LOCKED_END }
void d3d_backend_stretch(D3DState *s, uint32_t a, uint32_t b, uint32_t d, uint32_t e, uint32_t f) { LOCKED_BEGIN d3d_backend_stretch_impl(s, a, b, d, e, f); LOCKED_END }
void d3d_backend_colorfill(D3DState *s, uint32_t a, uint32_t b, uint32_t c) { LOCKED_BEGIN d3d_backend_colorfill_impl(s, a, b, c); LOCKED_END }
void d3d_backend_readback(D3DState *s, uint32_t a, uint32_t b) { LOCKED_BEGIN d3d_backend_readback_impl(s, a, b); LOCKED_END }
void d3d_backend_created(uint32_t o) { LOCKED_BEGIN d3d_backend_created_impl(o); LOCKED_END }
void d3d_backend_dirty(uint32_t o) { LOCKED_BEGIN d3d_backend_dirty_impl(o); LOCKED_END }
void d3d_backend_release(uint32_t o) { LOCKED_BEGIN d3d_backend_release_impl(o); LOCKED_END }
static void pace_60fps(void) {
    static int novsync = -1;
    if (novsync < 0) novsync = getenv("FNV_NOVSYNC") != NULL;
    if (novsync) return;
    static uint64_t prev_ns;
    const uint64_t step_ns = 16666667ull; // 60 Hz ceiling keeps Skyrim Havok physics stable
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (!prev_ns) { prev_ns = now; return; }
    uint64_t target = prev_ns + step_ns;
    if (now < target) {
        uint64_t rem = target - now;
        if (rem > 1000000ull) {
            struct timespec ts = { (time_t)((rem - 500000ull) / 1000000000ull), (long)((rem - 500000ull) % 1000000000ull) };
            nanosleep(&ts, NULL);
        }
        while (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < target) {}
        prev_ns = target;
    } else {
        prev_ns = now;
    }
}
void d3d_backend_present(D3DState *s) {
    LOCKED_BEGIN d3d_backend_present_impl(s); LOCKED_END
    // Avoid software sleep fighting hardware VSync on 60 Hz panels; only pace when headless/non-vsync.
    if (!layer || !layer.displaySyncEnabled) pace_60fps();
    host_pump_events();
}
void d3d_backend_resize(D3DState *s) { LOCKED_BEGIN d3d_backend_resize_impl(s); LOCKED_END }
