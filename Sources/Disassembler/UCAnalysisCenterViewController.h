#import <UIKit/UIKit.h>
#import "UCDisassembler.h"

NS_ASSUME_NONNULL_BEGIN

/// Local analysis workspace shared by the disassembler, CFG and pseudocode views.
/// It operates only on the UCFunction/instruction objects already in memory.
@interface UCAnalysisCenterViewController : UIViewController
- (instancetype)initWithFunction:(UCFunction *)function;
@end

NS_ASSUME_NONNULL_END
