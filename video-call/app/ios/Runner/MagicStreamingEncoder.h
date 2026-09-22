#import <Flutter/Flutter.h>
#import <Foundation/Foundation.h>
#import <WebRTC/WebRTC.h>

@interface MagicStreamingVideoEncoder : NSObject <RTCVideoEncoder>
- (instancetype)initWithEncoder:(id<RTCVideoEncoder>)encoder;
+ (void)install;
+ (void)setEnabled:(BOOL)enabled;
+ (BOOL)isEnabled;
@end

@interface MagicStreamingPlugin : NSObject <FlutterPlugin>
@end
