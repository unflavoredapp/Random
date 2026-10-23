#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Lists every recorded call/branch site that references a given address
/// (from UCDisasmInstruction.xrefFrom), and jumps to any of them.
@interface UCXrefListViewController : UIViewController

- (instancetype)initWithTargetAddress:(uint64_t)targetAddress
                       sourceAddresses:(NSArray<NSNumber *> *)sourceAddresses;

@end

NS_ASSUME_NONNULL_END
