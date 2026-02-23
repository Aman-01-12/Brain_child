//
//  SecureWindow.m
//  inter
//
//  Created by Aman Verma on 16/01/26.
//


#import "SecureWindow.h"

@implementation SecureWindow

- (BOOL)canBecomeKeyWindow {
    return YES;
}

- (BOOL)canBecomeMainWindow {
    return YES;
}

- (BOOL)worksWhenModal {
    return YES;
}

@end