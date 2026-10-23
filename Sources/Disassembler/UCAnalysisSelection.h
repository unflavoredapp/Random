#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Shared local navigation state for all analysis viewers.
/// View controllers communicate through notifications instead of retaining each other.
@interface UCAnalysisSelection : NSObject
+ (instancetype)shared;
@property (nonatomic, assign, readonly) uint64_t address;
@property (nonatomic, assign, readonly) uint64_t functionAddress;
@property (nonatomic, copy, nullable, readonly) NSString *kind;
- (void)selectAddress:(uint64_t)address functionAddress:(uint64_t)functionAddress kind:(nullable NSString *)kind;
@end

FOUNDATION_EXPORT NSNotificationName const UCAnalysisSelectionDidChangeNotification;
FOUNDATION_EXPORT NSString * const UCAnalysisSelectionAddressKey;
FOUNDATION_EXPORT NSString * const UCAnalysisSelectionFunctionKey;
FOUNDATION_EXPORT NSString * const UCAnalysisSelectionKindKey;

NS_ASSUME_NONNULL_END
