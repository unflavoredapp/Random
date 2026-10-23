
#import <UIKit/UIKit.h>
#import "UCDisassembler.h"

NS_ASSUME_NONNULL_BEGIN

@interface UCPseudocodeViewController : UIViewController

- (instancetype)initWithPseudocode:(NSString *)pseudocode
                             title:(nullable NSString *)title;

/// Generates lightweight linear/goto C-like pseudocode from an annotated
/// UCFunction. CFG edges are intentionally preserved rather than reconstructed
/// into compiler-grade if/else/loop syntax.
+ (NSString *)pseudocodeForFunction:(UCFunction *)function;

@end

NS_ASSUME_NONNULL_END
