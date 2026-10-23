//
//  AVX512Color.h
//  AVX512
//
//  Created by Benny Wong on 6/18/19.
//  Copyright © 2020 AVX512 Team. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AVX512Color : NSObject

@property (readonly, class) UIColor *primaryBackgroundColor;
+ (UIColor *)primaryBackgroundColorWithAlpha:(CGFloat)alpha;

@property (readonly, class) UIColor *secondaryBackgroundColor;
+ (UIColor *)secondaryBackgroundColorWithAlpha:(CGFloat)alpha;

@property (readonly, class) UIColor *tertiaryBackgroundColor;
+ (UIColor *)tertiaryBackgroundColorWithAlpha:(CGFloat)alpha;

@property (readonly, class) UIColor *groupedBackgroundColor;
+ (UIColor *)groupedBackgroundColorWithAlpha:(CGFloat)alpha;

@property (readonly, class) UIColor *secondaryGroupedBackgroundColor;
+ (UIColor *)secondaryGroupedBackgroundColorWithAlpha:(CGFloat)alpha;

// Text colors
@property (readonly, class) UIColor *primaryTextColor;
@property (readonly, class) UIColor *deemphasizedTextColor;

// UI element colors
@property (readonly, class) UIColor *tintColor;

/// The app's real, live accent color — read straight from the same
/// NSUserDefaults key ("theme_accent_hex") Swift's `Theme.accentHex` reads,
/// so Objective-C UIKit screens (the CFG viewer, etc.) can match the user's
/// actual chosen accent instead of a hardcoded generic system blue. Falls
/// back to the same default ("FF9A1F") Theme.swift uses when nothing's been
/// set yet.
@property (readonly, class) UIColor *appAccentColor;
@property (readonly, class) UIColor *scrollViewBackgroundColor;
@property (readonly, class) UIColor *iconColor;
@property (readonly, class) UIColor *borderColor;
@property (readonly, class) UIColor *toolbarItemHighlightedColor;
@property (readonly, class) UIColor *toolbarItemSelectedColor;
@property (readonly, class) UIColor *hairlineColor;
@property (readonly, class) UIColor *destructiveColor;

@end

NS_ASSUME_NONNULL_END
