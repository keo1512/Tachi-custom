#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface LocalComicRarReader : NSObject
+ (nullable NSDictionary<NSString *, NSData *> *)readData:(NSData *)data error:(NSError **)error NS_SWIFT_NAME(read(_:));
@end
NS_ASSUME_NONNULL_END
