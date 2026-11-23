#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Swift cannot catch NSException. AVAudioEngine raises them (for example from installTapOnBus when
/// the input device changes under it), which would otherwise abort the app.
@interface ObjCException : NSObject
/// Runs `block` and converts an Objective-C NSException into an NSError. Swift: `try ObjCException.catching { … }`.
+ (BOOL)catching:(NS_NOESCAPE void (^)(void))block error:(NSError *_Nullable *_Nullable)error;
@end

NS_ASSUME_NONNULL_END
