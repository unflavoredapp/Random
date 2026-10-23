//
//  UIFont+AVX512.h
//  AVX512
//
//  Created by Tanner Bennett on 12/20/19.
//  Copyright © 2020 AVX512 Team. All rights reserved.
//

#import <UIKit/UIKit.h>

@interface UIFont (AVX512)

@property (nonatomic, readonly, class) UIFont *avx512_defaultTableCellFont;
@property (nonatomic, readonly, class) UIFont *avx512_codeFont;
@property (nonatomic, readonly, class) UIFont *avx512_smallCodeFont;

@end
