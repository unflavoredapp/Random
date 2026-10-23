#import <UIKit/UIKit.h>
#import "UCDisassembler.h"

NS_ASSUME_NONNULL_BEGIN
@interface UCStringsBrowserViewController : UITableViewController
- (instancetype)initWithFunction:(UCFunction *)function;
@end
NS_ASSUME_NONNULL_END
