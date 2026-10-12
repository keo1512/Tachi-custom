#import <Flutter/Flutter.h>
#import <UIKit/UIKit.h>

@interface TachiSourceBrowser : UIViewController
+ (void)openURL:(NSString *)url result:(FlutterResult)result NS_SWIFT_NAME(open(url:result:));
@end
