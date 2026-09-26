#import "MagicStreamingEncoder.h"
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <VideoToolbox/VideoToolbox.h>
#import <objc/runtime.h>

#include "mc_streaming.h"

#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static const NSUInteger kMagicStreamingMaxPending = 8;
static atomic_bool gMagicStreamingEnabled = false;

@interface VtCbrVideoEncoder : NSObject <RTCVideoEncoder>
- (instancetype)initWithEncoder:(id<RTCVideoEncoder>)encoder;
@end

@interface VtCbrVideoEncoder ()
@property(nonatomic, strong) id<RTCVideoEncoder> inner;
@property(nonatomic, assign) uint32_t lastBitrateBps;
@property(nonatomic, assign) uint32_t cbrTargetBps;
@property(nonatomic, assign) size_t encodedBytes;
@property(nonatomic, assign) NSTimeInterval encodedWindowStart;
@end

static VTCompressionSessionRef VtSessionFromEncoder(id encoder) {
    if (encoder == nil) {
        return NULL;
    }
    Class cls = object_getClass(encoder);
    Ivar ivar = class_getInstanceVariable(cls, "_compressionSession");
    if (ivar == NULL) {
        unsigned int n = 0;
        Ivar *list = class_copyIvarList(cls, &n);
        for (unsigned i = 0; i < n; i++) {
            const char *type = ivar_getTypeEncoding(list[i]);
            if (type && strstr(type, "OpaqueVTCompressionSession")) {
                ivar = list[i];
                break;
            }
        }
        free(list);
    }
    if (ivar == NULL) {
        return NULL;
    }
    return *(VTCompressionSessionRef *)((uintptr_t)(__bridge void *)encoder +
                                        (uintptr_t)ivar_getOffset(ivar));
}

static void CbrLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"%@", line);
    static dispatch_queue_t q;
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("vt.cbr.log", DISPATCH_QUEUE_SERIAL);
        path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/vt_cbr.log"];
    });
    NSTimeInterval ts = [NSDate date].timeIntervalSince1970;
    dispatch_async(q, ^{
        NSString *row = [NSString stringWithFormat:@"%.3f %@\n", ts, line];
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        [fh seekToEndOfFile];
        [fh writeData:[row dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    });
}

static void McsFileLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"%@", line);
    static dispatch_queue_t q;
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("mcs.file.log", DISPATCH_QUEUE_SERIAL);
        path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/mcs.log"];
    });
    NSTimeInterval ts = [NSDate date].timeIntervalSince1970;
    dispatch_async(q, ^{
        NSString *row = [NSString stringWithFormat:@"%.3f %@\n", ts, line];
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        [fh seekToEndOfFile];
        [fh writeData:[row dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    });
}

static uint32_t U32Ivar(id obj, const char *name) {
    if (obj == nil) {
        return 0;
    }
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), name);
    if (ivar == NULL) {
        return 0;
    }
    return *(uint32_t *)((uintptr_t)(__bridge void *)obj + (uintptr_t)ivar_getOffset(ivar));
}

static void ForceCbrEncodeMode(id encoder) {
    Ivar ivar = class_getInstanceVariable(object_getClass(encoder), "_encodeMode");
    if (ivar == NULL) {
        return;
    }
    *(int64_t *)((uintptr_t)(__bridge void *)encoder + (uintptr_t)ivar_getOffset(ivar)) = 1;
}

static void ApplyVtCbr(id encoder, uint32_t bitrateBps) {
    VTCompressionSessionRef session = VtSessionFromEncoder(encoder);
    if (session == NULL || bitrateBps == 0) {
        static int sNoSession;
        if (session == NULL && !sNoSession) {
            sNoSession = 1;
            CbrLog(@"[VT-CBR] no compression session on %@", [encoder class]);
        }
        return;
    }
    ForceCbrEncodeMode(encoder);
    uint32_t fps = U32Ivar(encoder, "_targetFrameRate");
    if (fps == 0) {
        fps = 30;
    }
    int32_t fps32 = (int32_t)fps;
    CFNumberRef fpsNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &fps32);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_ExpectedFrameRate, fpsNum);
    CFRelease(fpsNum);
    int64_t br = (int64_t)bitrateBps;
    CFNumberRef num = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &br);
    OSStatus st = -1;
    int64_t got = -1;
    int hasCbr = -1;
    BOOL cbrOk = NO;
    if (@available(iOS 16.0, *)) {
        static int sLoggedSupport;
        if (!sLoggedSupport) {
            sLoggedSupport = 1;
            CFDictionaryRef supported = NULL;
            VTSessionCopySupportedPropertyDictionary(session, &supported);
            hasCbr = (supported != NULL &&
                      CFDictionaryContainsKey(supported, kVTCompressionPropertyKey_ConstantBitRate))
                         ? 1
                         : 0;
            if (supported) {
                CFRelease(supported);
            }
        }
        VTSessionSetProperty(session, kVTCompressionPropertyKey_AverageBitRate, kCFNull);
        VTSessionSetProperty(session, kVTCompressionPropertyKey_DataRateLimits, kCFNull);
        st = VTSessionSetProperty(session, kVTCompressionPropertyKey_ConstantBitRate, num);
        CFTypeRef copied = NULL;
        if (VTSessionCopyProperty(session, kVTCompressionPropertyKey_ConstantBitRate, NULL, &copied) ==
                noErr &&
            copied != NULL && CFGetTypeID(copied) == CFNumberGetTypeID()) {
            CFNumberGetValue((CFNumberRef)copied, kCFNumberSInt64Type, &got);
        }
        if (copied) {
            CFRelease(copied);
        }
        cbrOk = (st == noErr && got > 0);
    }
    if (!cbrOk) {
        VTSessionSetProperty(session, kVTCompressionPropertyKey_AverageBitRate, num);
        int64_t bytes = br / 8;
        double window = 1.0;
        CFNumberRef bytesNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &bytes);
        CFNumberRef windowNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &window);
        const void *limitVals[2] = {bytesNum, windowNum};
        CFArrayRef limits = CFArrayCreate(kCFAllocatorDefault, limitVals, 2, &kCFTypeArrayCallBacks);
        VTSessionSetProperty(session, kVTCompressionPropertyKey_DataRateLimits, limits);
        CFRelease(limits);
        CFRelease(bytesNum);
        CFRelease(windowNum);
        if (st != noErr) {
            st = noErr;
        }
    }
    uint32_t target = U32Ivar(encoder, "_targetBitrateBps");
    uint32_t encBr = U32Ivar(encoder, "_encoderBitrateBps");
    uint32_t maxBr = U32Ivar(encoder, "_maxBitrate");
    static uint32_t sLoggedBr;
    static OSStatus sLoggedSt = 1;
    static int sLoggedN;
    if (st != 0 || sLoggedBr != bitrateBps || sLoggedSt != st || sLoggedN < 6) {
        sLoggedBr = bitrateBps;
        sLoggedSt = st;
        sLoggedN += 1;
        CbrLog(@"[VT-CBR] bitrate=%u cbr=%d got=%lld has=%d locked=%d fps=%u target=%u encoder=%u max=%u session=%p %@",
               bitrateBps, (int)st, got, hasCbr, cbrOk ? 1 : 0, fps, target, encBr, maxBr, session,
               [encoder class]);
    }
    CFRelease(num);
}

static void HookH264BitrateUpdate(void) {
    Class cls = NSClassFromString(@"RTCVideoEncoderH264");
    if (cls == Nil) {
        CbrLog(@"[VT-CBR] RTCVideoEncoderH264 missing");
        return;
    }
    SEL sels[2] = {
        NSSelectorFromString(@"updateEncoderBitrateAndFrameRate"),
        NSSelectorFromString(@"configureCompressionSession"),
    };
    for (int i = 0; i < 2; i++) {
        SEL sel = sels[i];
        Method method = class_getInstanceMethod(cls, sel);
        if (method == NULL) {
            CbrLog(@"[VT-CBR] missing %@", NSStringFromSelector(sel));
            continue;
        }
        IMP original = method_getImplementation(method);
        IMP replacement = imp_implementationWithBlock(^void(id self) {
            ForceCbrEncodeMode(self);
            ((void (*)(id, SEL))original)(self, sel);
            uint32_t bps = U32Ivar(self, "_maxBitrate");
            if (bps == 0) {
                bps = U32Ivar(self, "_targetBitrateBps");
            }
            if (bps == 0) {
                bps = U32Ivar(self, "_encoderBitrateBps");
            }
            ApplyVtCbr(self, bps);
        });
        method_setImplementation(method, replacement);
        CbrLog(@"[VT-CBR] hooked %@", NSStringFromSelector(sel));
    }
}

@implementation VtCbrVideoEncoder

- (instancetype)initWithEncoder:(id<RTCVideoEncoder>)encoder {
    self = [super init];
    if (self) {
        _inner = encoder;
    }
    return self;
}

- (void)setCallback:(RTCVideoEncoderCallback)callback {
    __weak typeof(self) weakSelf = self;
    [_inner setCallback:^BOOL(RTCEncodedImage *image, id<RTCCodecSpecificInfo> info) {
        VtCbrVideoEncoder *strongSelf = weakSelf;
        if (strongSelf != nil && image.buffer.length > 0) {
            NSTimeInterval now = [NSDate date].timeIntervalSince1970;
            if (strongSelf.encodedWindowStart <= 0) {
                strongSelf.encodedWindowStart = now;
            }
            strongSelf.encodedBytes += image.buffer.length;
            NSTimeInterval dt = now - strongSelf.encodedWindowStart;
            if (dt >= 1.0) {
                int kbps = (int)(strongSelf.encodedBytes * 8.0 / dt / 1000.0);
                CbrLog(@"[VT-CBR] encoded %d kbps bytes=%zu dt=%.2f target=%u",
                       kbps, strongSelf.encodedBytes, dt, strongSelf.lastBitrateBps);
                strongSelf.encodedBytes = 0;
                strongSelf.encodedWindowStart = now;
            }
        }
        return callback ? callback(image, info) : NO;
    }];
}

- (NSInteger)startEncodeWithSettings:(RTCVideoEncoderSettings *)settings
                       numberOfCores:(int)numberOfCores {
    uint32_t maxKbps = settings.maxBitrate > 0 ? (uint32_t)settings.maxBitrate : 1800u;
    _cbrTargetBps = maxKbps * 1000u;
    _lastBitrateBps = _cbrTargetBps;
    CbrLog(@"[VT-CBR] start %dx%d startKbps=%u maxKbps=%u fps=%u lockCbr=%u",
           settings.width, settings.height, settings.startBitrate, settings.maxBitrate,
           settings.maxFramerate, _cbrTargetBps);
    NSInteger rc = [_inner startEncodeWithSettings:settings numberOfCores:numberOfCores];
    ApplyVtCbr(_inner, _cbrTargetBps);
    return rc;
}

- (NSInteger)releaseEncoder {
    return [_inner releaseEncoder];
}

- (NSInteger)encode:(RTCVideoFrame *)frame
    codecSpecificInfo:(nullable id<RTCCodecSpecificInfo>)codecSpecificInfo
           frameTypes:(NSArray<NSNumber *> *)frameTypes {
    NSInteger rc = [_inner encode:frame codecSpecificInfo:codecSpecificInfo frameTypes:frameTypes];
    if (_cbrTargetBps > 0) {
        ApplyVtCbr(_inner, _cbrTargetBps);
    }
    return rc;
}

- (int)setBitrate:(uint32_t)bitrateKbit framerate:(uint32_t)framerate {
    uint32_t kbps = _cbrTargetBps > 0 ? (_cbrTargetBps / 1000u) : bitrateKbit;
    _lastBitrateBps = kbps * 1000u;
    int rc = [_inner setBitrate:kbps framerate:framerate];
    ApplyVtCbr(_inner, _lastBitrateBps);
    return rc;
}

- (NSString *)implementationName {
    NSString *name = [_inner implementationName] ?: @"encoder";
    return [name stringByAppendingString:@"+cbr"];
}

- (RTCVideoEncoderQpThresholds *)scalingSettings {
    if ([_inner respondsToSelector:@selector(scalingSettings)]) {
        return [_inner scalingSettings];
    }
    return nil;
}

- (NSInteger)resolutionAlignment {
    if ([_inner respondsToSelector:@selector(resolutionAlignment)]) {
        return [_inner resolutionAlignment];
    }
    return 1;
}

- (BOOL)applyAlignmentToAllSimulcastLayers {
    if ([_inner respondsToSelector:@selector(applyAlignmentToAllSimulcastLayers)]) {
        return [_inner applyAlignmentToAllSimulcastLayers];
    }
    return NO;
}

- (BOOL)supportsNativeHandle {
    if ([_inner respondsToSelector:@selector(supportsNativeHandle)]) {
        return [_inner supportsNativeHandle];
    }
    return NO;
}

@end

@interface MagicStreamingVideoEncoder ()
@property(nonatomic, strong) id<RTCVideoEncoder> inner;
@property(nonatomic, assign) void *handle;
@property(nonatomic, assign) BOOL released;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, id<RTCVideoFrameBuffer>> *pending;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *pendingOrder;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *toI420Us;
@end

static int fill_mcs_input(mc_streaming_input_t *in, id<RTCVideoFrameBuffer> buf,
                          CVPixelBufferRef *locked_pb, id<RTCI420Buffer> *held_i420,
                          int *out_csp) {
    *locked_pb = NULL;
    *held_i420 = nil;
    if (out_csp) {
        *out_csp = MCS_CSP_I420;
    }
    in->width = (int)buf.width;
    in->height = (int)buf.height;
    if ([buf isKindOfClass:[RTCCVPixelBuffer class]]) {
        CVPixelBufferRef pb = [(RTCCVPixelBuffer *)buf pixelBuffer];
        if (pb) {
            OSType fmt = CVPixelBufferGetPixelFormatType(pb);
            size_t planes = CVPixelBufferGetPlaneCount(pb);
            int nv12 = (fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                        fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
            if (nv12 && planes >= 2 &&
                CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess) {
                in->y = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 0);
                in->u = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 1);
                in->v = NULL;
                in->stride_y = (int)CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
                in->stride_u = (int)CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
                in->stride_v = 0;
                if (out_csp) {
                    *out_csp = MCS_CSP_NV12;
                }
                if (in->y && in->u) {
                    *locked_pb = pb;
                    return 0;
                }
                CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
            }
        }
    }
    id<RTCI420Buffer> i420 = [buf toI420];
    if (!i420) {
        return -1;
    }
    *held_i420 = i420;
    in->y = i420.dataY;
    in->u = i420.dataU;
    in->v = i420.dataV;
    in->stride_y = i420.strideY;
    in->stride_u = i420.strideU;
    in->stride_v = i420.strideV;
    if (out_csp) {
        *out_csp = MCS_CSP_I420;
    }
    return 0;
}

static int ensure_mcs_session(void **handle, int csp) {
    mc_streaming_ctrl_params_t p;
    if (!handle) {
        return -1;
    }
    if (*handle) {
        return 0;
    }
    memset(&p, 0, sizeof(p));
    p.codec_type = MCS_H264_ZERO_DELAY_8BIT;
    p.pic_csp = (mc_streaming_csp_e)csp;
    p.log_level = MCS_LOG_ERROR;
    if (mc_streaming_control(handle, MCS_CMD_SET_PARAMS, &p, NULL) != MCS_OK) {
        McsFileLog(@"[MagicStreaming] control SET_PARAMS failed csp=%d", csp);
        return -1;
    }
    {
        mc_streaming_status_params_t st;
        memset(&st, 0, sizeof(st));
        mc_streaming_control(handle, MCS_CMD_GET_STATUS, NULL, &st);
        McsFileLog(@"[MagicStreaming] control SET_PARAMS ok handle=%p ver=%s csp=%d max=%dx%d save=%.2f%%",
                   *handle, mc_streaming_get_version(), csp, st.max_width, st.max_height,
                   (double)st.bits_save_rate);
    }
    return 0;
}

@implementation MagicStreamingVideoEncoder

+ (void)load {
    [self install];
}

+ (void)setEnabled:(BOOL)enabled {
    atomic_store(&gMagicStreamingEnabled, enabled);
    McsFileLog(@"[MagicStreaming] enabled=%d", enabled ? 1 : 0);
}

+ (BOOL)isEnabled {
    return atomic_load(&gMagicStreamingEnabled);
}

+ (void)install {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = NSClassFromString(@"RTCDefaultVideoEncoderFactory");
        if (cls == Nil) {
            NSLog(@"[MagicStreaming] RTCDefaultVideoEncoderFactory missing");
            return;
        }
        SEL sel = @selector(createEncoder:);
        Method method = class_getInstanceMethod(cls, sel);
        if (method == NULL) {
            NSLog(@"[MagicStreaming] createEncoder: missing");
            return;
        }
        IMP original = method_getImplementation(method);
        IMP replacement = imp_implementationWithBlock(^id(id factory, RTCVideoCodecInfo *info) {
            id<RTCVideoEncoder> encoder = ((id<RTCVideoEncoder>(*)(id, SEL, RTCVideoCodecInfo *))original)(factory, sel, info);
            if (encoder == nil || info == nil) {
                return encoder;
            }
            if (![info.name isEqualToString:kRTCVideoCodecH264Name]) {
                return encoder;
            }
            encoder = [[VtCbrVideoEncoder alloc] initWithEncoder:encoder];
            if ([MagicStreamingVideoEncoder isEnabled]) {
                encoder = [[MagicStreamingVideoEncoder alloc] initWithEncoder:encoder];
            }
            return encoder;
        });
        method_setImplementation(method, replacement);
        NSLog(@"[MagicStreaming] hooked RTCDefaultVideoEncoderFactory createEncoder:");
        HookH264BitrateUpdate();
    });
}

- (instancetype)initWithEncoder:(id<RTCVideoEncoder>)encoder {
    self = [super init];
    if (self) {
        _inner = encoder;
        _pending = [NSMutableDictionary dictionary];
        _pendingOrder = [NSMutableArray array];
        _toI420Us = [NSMutableArray array];
    }
    return self;
}

- (void)dealloc {
    @synchronized(self) {
        _released = YES;
        [self clearPendingLocked];
        if (_handle) {
            mc_streaming_disable(_handle);
            _handle = NULL;
        }
    }
}

- (void)clearPendingLocked {
    [_pending removeAllObjects];
    [_pendingOrder removeAllObjects];
}

- (void)clearPending {
    @synchronized(self) {
        [self clearPendingLocked];
    }
}

- (void)rememberBuffer:(id<RTCVideoFrameBuffer>)buf timestamp:(int32_t)timestamp {
    NSNumber *key = @(timestamp);
    @synchronized(self) {
        _pending[key] = buf;
        [_pendingOrder addObject:key];
        while (_pendingOrder.count > kMagicStreamingMaxPending) {
            NSNumber *old = _pendingOrder.firstObject;
            if (old != nil) {
                [_pendingOrder removeObjectAtIndex:0];
                [_pending removeObjectForKey:old];
            }
        }
    }
}

- (id<RTCVideoFrameBuffer>)takeBuffer:(int32_t)timestamp {
    NSNumber *key = @(timestamp);
    @synchronized(self) {
        id<RTCVideoFrameBuffer> buf = _pending[key];
        if (buf != nil) {
            [_pending removeObjectForKey:key];
            [_pendingOrder removeObject:key];
        }
        return buf;
    }
}

- (void)setCallback:(RTCVideoEncoderCallback)callback {
    __weak typeof(self) weakSelf = self;
    [_inner setCallback:^BOOL(RTCEncodedImage *image, id<RTCCodecSpecificInfo> info) {
        MagicStreamingVideoEncoder *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return callback ? callback(image, info) : NO;
        }
        RTCEncodedImage *processed = [strongSelf processEncoded:image];
        if (processed == nil) {
            return YES;
        }
        return callback ? callback(processed, info) : YES;
    }];
}

- (NSInteger)startEncodeWithSettings:(RTCVideoEncoderSettings *)settings
                       numberOfCores:(int)numberOfCores {
    @synchronized(self) {
        _released = NO;
    }
    return [_inner startEncodeWithSettings:settings numberOfCores:numberOfCores];
}

- (NSInteger)releaseEncoder {
    @synchronized(self) {
        _released = YES;
    }
    NSInteger rc = [_inner releaseEncoder];
    @synchronized(self) {
        [self logCopySummaryLocked:@"release"];
        [self clearPendingLocked];
        if (_handle) {
            mc_streaming_disable(_handle);
            _handle = NULL;
        }
    }
    return rc;
}

- (void)logCopySummaryLocked:(NSString *)why {
    NSUInteger n = _toI420Us.count;
    if (n == 0) {
        return;
    }
    long long sum = 0;
    int maxUs = 0;
    NSMutableArray<NSNumber *> *sorted = [_toI420Us mutableCopy];
    for (NSNumber *v in _toI420Us) {
        int us = v.intValue;
        sum += us;
        if (us > maxUs) {
            maxUs = us;
        }
    }
    [sorted sortUsingSelector:@selector(compare:)];
    int meanUs = (int)(sum / (long long)n);
    int p95Us = sorted[((n - 1) * 95) / 100].intValue;
    NSString *line = [NSString stringWithFormat:
        @"[MagicStreaming] copy summary %@ n=%lu meanUs=%d p95Us=%d maxUs=%d",
        why, (unsigned long)n, meanUs, p95Us, maxUs];
    NSLog(@"%@", line);
    CbrLog(@"%@", line);
}

- (NSInteger)encode:(RTCVideoFrame *)frame
    codecSpecificInfo:(nullable id<RTCCodecSpecificInfo>)codecSpecificInfo
           frameTypes:(NSArray<NSNumber *> *)frameTypes {
    if (!_released && [MagicStreamingVideoEncoder isEnabled]) {
        CFTimeInterval t0 = CACurrentMediaTime();
        id<RTCVideoFrameBuffer> buf = frame.buffer;
        if (buf != nil) {
            [self rememberBuffer:buf timestamp:frame.timeStamp];
            int us = (int)((CACurrentMediaTime() - t0) * 1e6);
            NSUInteger n = 0;
            @synchronized(self) {
                [_toI420Us addObject:@(us)];
                n = _toI420Us.count;
            }
            if (n == 1 || n % 30 == 0) {
                NSString *line = [NSString stringWithFormat:
                    @"[MagicStreaming] copy n=%lu us=%d buf=%@ %dx%d",
                    (unsigned long)n, us, NSStringFromClass([buf class]),
                    (int)buf.width, (int)buf.height];
                NSLog(@"%@", line);
                CbrLog(@"%@", line);
            }
        }
    }
    return [_inner encode:frame codecSpecificInfo:codecSpecificInfo frameTypes:frameTypes];
}

- (int)setBitrate:(uint32_t)bitrateKbit framerate:(uint32_t)framerate {
    return [_inner setBitrate:bitrateKbit framerate:framerate];
}

- (NSString *)implementationName {
    NSString *name = [_inner implementationName] ?: @"encoder";
    if ([MagicStreamingVideoEncoder isEnabled]) {
        return [name stringByAppendingString:@"+mcs"];
    }
    return name;
}

- (RTCVideoEncoderQpThresholds *)scalingSettings {
    if ([_inner respondsToSelector:@selector(scalingSettings)]) {
        return [_inner scalingSettings];
    }
    return nil;
}

- (NSInteger)resolutionAlignment {
    if ([_inner respondsToSelector:@selector(resolutionAlignment)]) {
        return [_inner resolutionAlignment];
    }
    return 1;
}

- (BOOL)applyAlignmentToAllSimulcastLayers {
    if ([_inner respondsToSelector:@selector(applyAlignmentToAllSimulcastLayers)]) {
        return [_inner applyAlignmentToAllSimulcastLayers];
    }
    return NO;
}

- (BOOL)supportsNativeHandle {
    if ([_inner respondsToSelector:@selector(supportsNativeHandle)]) {
        return [_inner supportsNativeHandle];
    }
    return NO;
}

- (RTCEncodedImage *)processEncoded:(RTCEncodedImage *)image {
    @synchronized(self) {
        if (_released || ![MagicStreamingVideoEncoder isEnabled]) {
            return image;
        }
        id<RTCVideoFrameBuffer> yuv = [self takeBuffer:image.timeStamp];
        if (yuv == nil || image.buffer.length == 0) {
            return image;
        }
        NSData *inData = image.buffer;
        size_t au = inData.length;
        size_t cap = au * 2 + 4096;
        NSMutableData *work = [NSMutableData dataWithLength:cap];

        mc_streaming_input_t in = {0};
        in.frame_type = (image.frameType == RTCFrameTypeVideoFrameKey) ? 1 : 0;
        in.bs = (const uint8_t *)inData.bytes;
        in.au_size = au;
        CVPixelBufferRef locked_pb = NULL;
        id<RTCI420Buffer> held_i420 = nil;
        int pic_csp = MCS_CSP_I420;
        if (fill_mcs_input(&in, yuv, &locked_pb, &held_i420, &pic_csp) != 0) {
            return image;
        }

        mc_streaming_output_t out = {0};
        out.bs = (uint8_t *)work.mutableBytes;
        out.bs_size = cap;

        if (ensure_mcs_session(&_handle, pic_csp) != 0) {
            if (locked_pb) {
                CVPixelBufferUnlockBaseAddress(locked_pb, kCVPixelBufferLock_ReadOnly);
            }
            return image;
        }
        int rc = mc_streaming_enable(&_handle, &in, &out);
        if (locked_pb) {
            CVPixelBufferUnlockBaseAddress(locked_pb, kCVPixelBufferLock_ReadOnly);
        }
        (void)held_i420;
        if (rc != MCS_OK) {
            McsFileLog(@"[MagicStreaming] enable rc=%d out=%zu key=%d %dx%d csp=%d", rc, out.bs_size,
                       (int)in.frame_type, in.width, in.height, pic_csp);
        } else {
            static int first_ok;
            if (!first_ok) {
                mc_streaming_status_params_t st;
                memset(&st, 0, sizeof(st));
                mc_streaming_control(&_handle, MCS_CMD_GET_STATUS, NULL, &st);
                McsFileLog(@"[MagicStreaming] enable first ok out=%zu key=%d %dx%d max=%dx%d save=%.2f%%",
                           out.bs_size, (int)in.frame_type, in.width, in.height, st.max_width,
                           st.max_height, (double)st.bits_save_rate);
                first_ok = 1;
            }
        }
        if (out.bs_size == 0 || out.bs_size > cap) {
            return image;
        }
        image.buffer = [NSData dataWithBytes:out.bs length:out.bs_size];
        return image;
    }
}

@end

@implementation MagicStreamingPlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    [MagicStreamingVideoEncoder install];
    FlutterMethodChannel *channel =
        [FlutterMethodChannel methodChannelWithName:@"video_call/magic_streaming"
                                    binaryMessenger:registrar.messenger];
    MagicStreamingPlugin *instance = [[MagicStreamingPlugin alloc] init];
    [registrar addMethodCallDelegate:instance channel:channel];
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
    if ([call.method isEqualToString:@"setEnabled"]) {
        [MagicStreamingVideoEncoder setEnabled:[call.arguments boolValue]];
        result(nil);
    } else if ([call.method isEqualToString:@"isEnabled"]) {
        result(@([MagicStreamingVideoEncoder isEnabled]));
    } else if ([call.method isEqualToString:@"log"]) {
        NSString *line = [call.arguments isKindOfClass:[NSString class]] ? call.arguments : nil;
        if (line.length > 0) {
            CbrLog(@"%@", line);
        }
        result(nil);
    } else {
        result(FlutterMethodNotImplemented);
    }
}

@end
