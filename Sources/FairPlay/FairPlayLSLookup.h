// FairPlayLSLookup.h — LaunchServices helpers for installed-app path resolution.
// Brand: Tetherless · https://tetherless.dev
#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Bundle URL from `LSApplicationRecord`, or nil when unavailable / not installed.
NSURL * _Nullable fp_ls_application_record_url(NSString *bundleID);
NS_ASSUME_NONNULL_END
