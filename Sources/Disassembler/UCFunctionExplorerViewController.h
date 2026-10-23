#import <UIKit/UIKit.h>
#import "UCDisassembler.h"
NS_ASSUME_NONNULL_BEGIN
@interface UCFunctionExplorerViewController : UITableViewController
- (instancetype)initWithFunctions:(NSArray<UCFunction *> *)functions;
@end
NS_ASSUME_NONNULL_END
