#import <UIKit/UIKit.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

/// Browses every ObjC class currently loaded in the running process, and
/// drills into a class's methods, opening the disassembler on whichever one
/// is selected. Live-runtime only: a class that hasn't been loaded yet won't
/// appear until it is (same constraint as -[UCDisassembler objcMethodNameAtAddress:]).
@interface UCClassBrowserViewController : UIViewController

/// Snapshots the currently-loaded class list at init time. Call again
/// (re-push a fresh instance) to pick up classes loaded afterwards.
- (instancetype)init;

@end

NS_ASSUME_NONNULL_END
