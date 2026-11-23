#import "JarvisObjC.h"

@implementation ObjCException

+ (BOOL)catching:(NS_NOESCAPE void (^)(void))block error:(NSError **)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.samarth.jarvis.objc-exception"
                                         code:1
                                     userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason ?: @"(no reason)"],
            }];
        }
        return NO;
    }
}

@end
