#import "UCAnalysisSelection.h"

@interface UCAnalysisSelection ()
@property (nonatomic, assign, readwrite) uint64_t address;
@property (nonatomic, assign, readwrite) uint64_t functionAddress;
@property (nonatomic, copy, nullable, readwrite) NSString *kind;
@end

NSNotificationName const UCAnalysisSelectionDidChangeNotification = @"UCAnalysisSelectionDidChangeNotification";
NSString * const UCAnalysisSelectionAddressKey = @"address";
NSString * const UCAnalysisSelectionFunctionKey = @"functionAddress";
NSString * const UCAnalysisSelectionKindKey = @"kind";

@implementation UCAnalysisSelection
+ (instancetype)shared {
    static UCAnalysisSelection *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ s = [UCAnalysisSelection new]; });
    return s;
}
- (void)selectAddress:(uint64_t)address functionAddress:(uint64_t)functionAddress kind:(NSString *)kind {
    self.address = address;
    self.functionAddress = functionAddress;
    self.kind = kind;
    [[NSNotificationCenter defaultCenter] postNotificationName:UCAnalysisSelectionDidChangeNotification object:self userInfo:@{
        UCAnalysisSelectionAddressKey:@(address),
        UCAnalysisSelectionFunctionKey:@(functionAddress),
        UCAnalysisSelectionKindKey:kind ?: @"instruction"
    }];
}
@end
