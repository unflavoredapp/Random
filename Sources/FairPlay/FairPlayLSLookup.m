// FairPlayLSLookup.m — LaunchServices helpers for installed-app path resolution.
#import "FairPlayLSLookup.h"
#import <objc/runtime.h>
#import <objc/message.h>

NSURL *fp_ls_application_record_url(NSString *bundleID) {
    if (bundleID.length == 0) return nil;
    Class recCls = NSClassFromString(@"LSApplicationRecord");
    SEL initSel = NSSelectorFromString(@"initWithBundleIdentifier:allowPlaceholder:error:");
    if (!recCls || ![recCls instancesRespondToSelector:initSel]) return nil;

    @try {
        NSError *err = nil;
        typedef id (*LSRecInitFn)(__attribute__((ns_consumed)) id, SEL, NSString *, BOOL, NSError * __autoreleasing *)
            __attribute__((ns_returns_retained));
        LSRecInitFn initFn = (LSRecInitFn)[recCls instanceMethodForSelector:initSel];
        id record = initFn([recCls alloc], initSel, bundleID, NO, &err);
        if (!record) return nil;

        for (NSString *key in @[@"URL", @"bundleURL", @"executableURL"]) {
            @try {
                id val = [record valueForKey:key];
                if ([val isKindOfClass:[NSURL class]]) {
                    return (NSURL *)val;
                }
            } @catch (NSException *e) {}
        }
    } @catch (NSException *e) {}
    return nil;
}
