#import "MagicSrPlugin.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <os/lock.h>
#import <stdatomic.h>

#if __has_include(<flutter_webrtc/FlutterWebRTCPlugin.h>)
#import <flutter_webrtc/FlutterWebRTCPlugin.h>
#else
@import flutter_webrtc;
#endif
#import <WebRTC/WebRTC.h>

#include "mc_interface.h"

#include <math.h>
#include <string.h>

@interface MagicSrPlugin () <FlutterTexture, RTCVideoRenderer>
@property(nonatomic, strong) NSObject<FlutterTextureRegistry> *textures;
@property(nonatomic, strong) NSObject<FlutterPluginRegistrar> *registrar;
@property(nonatomic, strong) RTCVideoTrack *videoTrack;
@property(nonatomic, strong) id<MTLDevice> device;
@property(nonatomic, strong) id<MTLTexture> inputTexture;
@property(nonatomic, strong) id<MTLTexture> outputTexture;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, assign) int64_t textureId;
@property(nonatomic, assign) void *srHandle;
@property(nonatomic, assign) int sessionW;
@property(nonatomic, assign) int sessionH;
@property(nonatomic, assign) int outW;
@property(nonatomic, assign) int outH;
@property(nonatomic, strong) FlutterMethodChannel *channel;
@property(nonatomic, assign) BOOL loggedFirst;
@property(nonatomic, assign) int failLogCount;
@property(nonatomic, assign) int lastOutW;
@property(nonatomic, assign) int lastOutH;
@end

@implementation MagicSrPlugin {
    CVPixelBufferRef _pixelBuffer;
    os_unfair_lock _lock;
    atomic_int _busy;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    MagicSrPlugin *instance = [[MagicSrPlugin alloc] init];
    instance.registrar = registrar;
    instance.textures = registrar.textures;
    instance.queue = dispatch_queue_create("video_call.magic_sr", DISPATCH_QUEUE_SERIAL);
    instance.device = MTLCreateSystemDefaultDevice();
    instance.textureId = -1;
    instance.failLogCount = 0;
    instance.lastOutW = 0;
    instance.lastOutH = 0;
    instance->_lock = OS_UNFAIR_LOCK_INIT;
    atomic_init(&instance->_busy, 0);
    instance.channel = [FlutterMethodChannel methodChannelWithName:@"video_call/magic_sr"
                                                   binaryMessenger:registrar.messenger];
    [registrar addMethodCallDelegate:instance channel:instance.channel];
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
    if ([call.method isEqualToString:@"start"]) {
        NSString *trackId = call.arguments[@"trackId"];
        NSError *error = nil;
        int64_t textureId = [self startWithTrackId:trackId error:&error];
        if (error) {
            result([FlutterError errorWithCode:@"start_failed" message:error.localizedDescription details:nil]);
        } else {
            result(@(textureId));
        }
    } else if ([call.method isEqualToString:@"stop"]) {
        [self stop];
        result(nil);
    } else {
        result(FlutterMethodNotImplemented);
    }
}

- (int64_t)startWithTrackId:(NSString *)trackId error:(NSError **)error {
    [self stop];
    self.failLogCount = 0;
    self.lastOutW = 0;
    self.lastOutH = 0;
    if (trackId.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"MagicSr" code:1 userInfo:@{NSLocalizedDescriptionKey: @"trackId required"}];
        }
        return -1;
    }
    FlutterWebRTCPlugin *webrtc = [FlutterWebRTCPlugin sharedSingleton];
    RTCMediaStreamTrack *media = [webrtc trackForId:trackId peerConnectionId:nil];
    if (![media isKindOfClass:[RTCVideoTrack class]]) {
        media = [webrtc remoteTrackForId:trackId];
    }
    if (![media isKindOfClass:[RTCVideoTrack class]]) {
        if (error) {
            *error = [NSError errorWithDomain:@"MagicSr"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"video track not found: %@", trackId]}];
        }
        return -1;
    }
    if (!self.device) {
        if (error) {
            *error = [NSError errorWithDomain:@"MagicSr" code:3 userInfo:@{NSLocalizedDescriptionKey: @"no Metal device"}];
        }
        return -1;
    }
    self.textureId = [self.textures registerTexture:self];
    self.videoTrack = (RTCVideoTrack *)media;
    [self.videoTrack addRenderer:self];
    return self.textureId;
}

- (void)detachFromEngineForRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    [self stop];
}

- (void)stop {
    if (self.videoTrack) {
        [self.videoTrack removeRenderer:self];
        self.videoTrack = nil;
    }
    if (self.queue) {
        dispatch_sync(self.queue, ^{
            [self teardownEngine];
        });
    } else {
        [self teardownEngine];
    }
    if (self.textureId >= 0) {
        [self.textures unregisterTexture:self.textureId];
        self.textureId = -1;
    }
    os_unfair_lock_lock(&_lock);
    if (_pixelBuffer) {
        CVPixelBufferRelease(_pixelBuffer);
        _pixelBuffer = nil;
    }
    os_unfair_lock_unlock(&_lock);
}

- (void)teardownEngine {
    if (self.srHandle) {
        mc_nscaler_disable(self.srHandle);
        self.srHandle = NULL;
    }
    self.inputTexture = nil;
    self.outputTexture = nil;
    self.sessionW = 0;
    self.sessionH = 0;
    self.outW = 0;
    self.outH = 0;
    self.loggedFirst = NO;
}

- (CVPixelBufferRef)copyPixelBuffer {
    CVPixelBufferRef buffer = nil;
    os_unfair_lock_lock(&_lock);
    if (_pixelBuffer) {
        buffer = CVBufferRetain(_pixelBuffer);
    }
    os_unfair_lock_unlock(&_lock);
    return buffer;
}

- (void)setSize:(CGSize)size {
    (void)size;
}

- (void)renderFrame:(RTCVideoFrame *)frame {
    if (!frame) {
        return;
    }
    int expected = 0;
    if (!atomic_compare_exchange_strong(&_busy, &expected, 1)) {
        return;
    }
    dispatch_async(self.queue, ^{
        [self processFrame:frame];
        atomic_store(&self->_busy, 0);
    });
}

- (void)processFrame:(RTCVideoFrame *)frame {
    RTCI420Buffer *i420 = [frame.buffer toI420];
    if (!i420) {
        return;
    }
    const int srcW = i420.width;
    const int srcH = i420.height;
    const int rotation = (int)frame.rotation;
    int rw = srcW;
    int rh = srcH;
    if (rotation == 90 || rotation == 270) {
        rw = srcH;
        rh = srcW;
    }
    if (rw < 64 || rh < 64) {
        return;
    }

    NSMutableData *rgba = [NSMutableData dataWithLength:(NSUInteger)srcW * srcH * 4];
    [self i420:i420 toRgba:(uint8_t *)rgba.mutableBytes];
    NSMutableData *rotated = [NSMutableData dataWithLength:(NSUInteger)rw * rh * 4];
    [self rotateRgba:(const uint8_t *)rgba.bytes
               width:srcW
              height:srcH
            rotation:rotation
                 dst:(uint8_t *)rotated.mutableBytes];

    NSError *initError = nil;
    if (![self ensureSessionWidth:rw height:rh error:&initError]) {
        [self logFail:[NSString stringWithFormat:@"init failed: %@", initError.localizedDescription ?: @"init failed"]];
        return;
    }
    [self.inputTexture replaceRegion:MTLRegionMake2D(0, 0, rw, rh)
                         mipmapLevel:0
                           withBytes:rotated.bytes
                         bytesPerRow:(NSUInteger)rw * 4];

    mc_nscaler_input_frame_t inFrame;
    mc_nscaler_output_frame_t outFrame;
    memset(&inFrame, 0, sizeof(inFrame));
    memset(&outFrame, 0, sizeof(outFrame));
    inFrame.handle.pointer = (__bridge void *)self.inputTexture;
    inFrame.format = (uint32_t)MTLPixelFormatRGBA8Unorm;
    inFrame.mip_count = 1;
    inFrame.width = (unsigned int)rw;
    inFrame.height = (unsigned int)rh;
    outFrame.handle.pointer = (__bridge void *)self.outputTexture;
    outFrame.format = (uint32_t)MTLPixelFormatRGBA8Unorm;
    outFrame.mip_count = 1;
    outFrame.width = (unsigned int)self.outW;
    outFrame.height = (unsigned int)self.outH;

    void *handle = self.srHandle;
    int ret = mc_nscaler_enable(&handle, &inFrame, &outFrame);
    self.srHandle = handle;
    if (ret != 0) {
        [self logFail:[NSString stringWithFormat:@"mc_nscaler_enable process ret=%d", ret]];
        return;
    }
    if (!self.loggedFirst) {
        self.loggedFirst = YES;
        NSLog(@"[MagicSr] first process ok version=%s in=%dx%d out=%dx%d",
              mc_nscaler_version(), rw, rh, self.outW, self.outH);
    }

    NSMutableData *outRgba = [NSMutableData dataWithLength:(NSUInteger)self.outW * self.outH * 4];
    [self.outputTexture getBytes:outRgba.mutableBytes
                     bytesPerRow:(NSUInteger)self.outW * 4
                      fromRegion:MTLRegionMake2D(0, 0, self.outW, self.outH)
                     mipmapLevel:0];
    if (self.outW != self.lastOutW || self.outH != self.lastOutH) {
        self.lastOutW = self.outW;
        self.lastOutH = self.outH;
        int outW = self.outW;
        int outH = self.outH;
        FlutterMethodChannel *channel = self.channel;
        dispatch_async(dispatch_get_main_queue(), ^{
            [channel invokeMethod:@"onOutputSize"
                        arguments:@{@"width": @(outW), @"height": @(outH)}];
        });
    }
    [self publishRgba:(const uint8_t *)outRgba.bytes width:self.outW height:self.outH];
}

- (BOOL)ensureSessionWidth:(int)width height:(int)height error:(NSError **)error {
    if (self.srHandle && self.sessionW == width && self.sessionH == height) {
        return YES;
    }
    [self teardownEngine];

    NSString *modelPath = [self modelPath];
    if (modelPath.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"MagicSr" code:4 userInfo:@{NSLocalizedDescriptionKey: @"model bin missing"}];
        }
        return NO;
    }

    MTLTextureDescriptor *inDesc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                           width:width
                                                          height:height
                                                       mipmapped:NO];
    inDesc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    inDesc.storageMode = MTLStorageModeShared;
    self.inputTexture = [self.device newTextureWithDescriptor:inDesc];

    const int outW = (int)llround((double)width * 1.5);
    const int outH = (int)llround((double)height * 1.5);
    MTLTextureDescriptor *outDesc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                           width:outW
                                                          height:outH
                                                       mipmapped:NO];
    outDesc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    outDesc.storageMode = MTLStorageModeShared;
    self.outputTexture = [self.device newTextureWithDescriptor:outDesc];
    if (!self.inputTexture || !self.outputTexture) {
        if (error) {
            *error = [NSError errorWithDomain:@"MagicSr" code:5 userInfo:@{NSLocalizedDescriptionKey: @"texture create failed"}];
        }
        return NO;
    }

    ctrl_param_t param;
    memset(&param, 0, sizeof(param));
    param.input_type = INPUT_TEXTURE_RGB8Unorm;
    param.scaler_factor = 1.5f;
    param.alg_mode = SPATIAL_BALANCED_MODE;
    param.log_level = MAGIC_LOG_INFO;
    param.backend = MAGIC_BACKEND_METAL;
    param.spatial_sharpen_level = 1;
    param.gpu_context.device = (__bridge void *)self.device;
    strncpy(param.model_path, modelPath.UTF8String, sizeof(param.model_path) - 1);

    output_status_params_t st;
    memset(&st, 0, sizeof(st));
    void *handle = NULL;
    int rc = mc_nscaler_control(&handle, MC_NSCALER_CMD_SET_PARAM, &param, &st);
    self.srHandle = handle;
    if (rc != 0 || !self.srHandle) {
        if (error) {
            NSString *msg = [NSString stringWithFormat:@"mc_nscaler_control SET_PARAM rc=%d model=%@", rc, modelPath];
            *error = [NSError errorWithDomain:@"MagicSr" code:rc userInfo:@{NSLocalizedDescriptionKey: msg}];
        }
        [self teardownEngine];
        return NO;
    }
    self.sessionW = width;
    self.sessionH = height;
    self.outW = (int)st.output_width > 0 ? (int)st.output_width : outW;
    self.outH = (int)st.output_height > 0 ? (int)st.output_height : outH;
    /* SET_PARAM create defaults to 640x360 until first enable supplies size. */
    if (st.width != 0 && st.height != 0 && ((int)st.width != width || (int)st.height != height)) {
        self.outW = outW;
        self.outH = outH;
    }
    if (self.outW != outW || self.outH != outH) {
        MTLTextureDescriptor *resized =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                               width:self.outW
                                                              height:self.outH
                                                           mipmapped:NO];
        resized.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        resized.storageMode = MTLStorageModeShared;
        self.outputTexture = [self.device newTextureWithDescriptor:resized];
    }
    NSLog(@"[MagicSr] nscaler init ok version=%s mode=SPATIAL_BALANCED scale=1.5 sharpen=1 %dx%d -> %dx%d model=%@",
          mc_nscaler_version(), width, height, self.outW, self.outH, modelPath);
    return YES;
}

- (NSString *)modelPath {
    NSString *path = [[NSBundle mainBundle] pathForResource:@"magic_sr_gpu_params" ofType:@"bin"];
    if (path.length == 0) {
        NSLog(@"[MagicSr] combined model magic_sr_gpu_params.bin missing from bundle");
        return nil;
    }
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    unsigned long long size = [attrs fileSize];
    if (size < 3000000) {
        NSLog(@"[MagicSr] combined model too small path=%@ size=%llu", path, size);
        return nil;
    }
    NSLog(@"[MagicSr] model=%@ bytes=%llu", path, size);
    return path;
}

- (void)logFail:(NSString *)detail {
    self.failLogCount += 1;
    if (self.failLogCount <= 3 || self.failLogCount % 30 == 0) {
        NSLog(@"[MagicSr] %@ count=%d", detail, self.failLogCount);
    }
    if (self.failLogCount == 1) {
        FlutterMethodChannel *channel = self.channel;
        NSString *message = detail ?: @"";
        dispatch_async(dispatch_get_main_queue(), ^{
            [channel invokeMethod:@"srFailed" arguments:@{@"message": message}];
        });
    }
}

- (void)publishRgba:(const uint8_t *)rgba width:(int)width height:(int)height {
    CVPixelBufferRef buffer = NULL;
    NSDictionary *attrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferMetalCompatibilityKey: @YES
    };
    CVReturn cr = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                      (__bridge CFDictionaryRef)attrs, &buffer);
    if (cr != kCVReturnSuccess || !buffer) {
        return;
    }
    CVPixelBufferLockBaseAddress(buffer, 0);
    uint8_t *dst = (uint8_t *)CVPixelBufferGetBaseAddress(buffer);
    size_t stride = CVPixelBufferGetBytesPerRow(buffer);
    for (int y = 0; y < height; ++y) {
        const uint8_t *srcRow = rgba + (size_t)y * width * 4;
        uint8_t *dstRow = dst + (size_t)y * stride;
        for (int x = 0; x < width; ++x) {
            dstRow[x * 4 + 0] = srcRow[x * 4 + 2];
            dstRow[x * 4 + 1] = srcRow[x * 4 + 1];
            dstRow[x * 4 + 2] = srcRow[x * 4 + 0];
            dstRow[x * 4 + 3] = srcRow[x * 4 + 3];
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);

    os_unfair_lock_lock(&_lock);
    CVPixelBufferRef old = _pixelBuffer;
    _pixelBuffer = buffer;
    os_unfair_lock_unlock(&_lock);
    if (old) {
        CVPixelBufferRelease(old);
    }
    if (self.textureId >= 0) {
        [self.textures textureFrameAvailable:self.textureId];
    }
}

- (void)i420:(RTCI420Buffer *)i420 toRgba:(uint8_t *)rgba {
    const int width = i420.width;
    const int height = i420.height;
    const uint8_t *y = i420.dataY;
    const uint8_t *u = i420.dataU;
    const uint8_t *v = i420.dataV;
    const int strideY = i420.strideY;
    const int strideU = i420.strideU;
    const int strideV = i420.strideV;
    for (int row = 0; row < height; ++row) {
        const uint8_t *yRow = y + row * strideY;
        const uint8_t *uRow = u + (row / 2) * strideU;
        const uint8_t *vRow = v + (row / 2) * strideV;
        uint8_t *dst = rgba + (size_t)row * width * 4;
        for (int col = 0; col < width; ++col) {
            int C = (int)yRow[col] - 16;
            int D = (int)uRow[col / 2] - 128;
            int E = (int)vRow[col / 2] - 128;
            int r = (298 * C + 409 * E + 128) >> 8;
            int g = (298 * C - 100 * D - 208 * E + 128) >> 8;
            int b = (298 * C + 516 * D + 128) >> 8;
            dst[col * 4 + 0] = (uint8_t)MAX(0, MIN(255, r));
            dst[col * 4 + 1] = (uint8_t)MAX(0, MIN(255, g));
            dst[col * 4 + 2] = (uint8_t)MAX(0, MIN(255, b));
            dst[col * 4 + 3] = 255;
        }
    }
}

- (void)rotateRgba:(const uint8_t *)src width:(int)width height:(int)height rotation:(int)rotation dst:(uint8_t *)dst {
    rotation = ((rotation % 360) + 360) % 360;
    if (rotation == 0) {
        memcpy(dst, src, (size_t)width * height * 4);
        return;
    }
    int outW = (rotation == 180) ? width : height;
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            const uint8_t *s = src + ((size_t)y * width + x) * 4;
            int dx, dy;
            if (rotation == 90) {
                dx = height - 1 - y;
                dy = x;
            } else if (rotation == 180) {
                dx = width - 1 - x;
                dy = height - 1 - y;
            } else {
                dx = y;
                dy = width - 1 - x;
            }
            uint8_t *d = dst + ((size_t)dy * outW + dx) * 4;
            memcpy(d, s, 4);
        }
    }
}

@end
