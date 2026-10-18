#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface TachiImageCodec : NSObject
+ (nullable NSDictionary *)decodeImageData:(NSData *)data NS_SWIFT_NAME(decode(_:));
+ (nullable NSData *)encodePixels:(NSData *)argb width:(NSUInteger)width height:(NSUInteger)height format:(NSString *)format quality:(NSUInteger)quality NS_SWIFT_NAME(encode(_:width:height:format:quality:));
@end
// JNI stays private to the implementation so Swift consumers need no JVM headers.
FOUNDATION_EXPORT BOOL TachiRegisterImageCodec(void *environment);
NS_ASSUME_NONNULL_END
