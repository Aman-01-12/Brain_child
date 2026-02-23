//
//  CapWindow.m
//  inter
//
//  Created by Aman Verma on 16/01/26.
//


#import "CapWindow.h"

@implementation CapWindow

- (BOOL)canBecomeKeyWindow {
    return YES;
}

- (BOOL)worksWhenModal {
    return YES;
}

@end