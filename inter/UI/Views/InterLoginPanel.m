#import "InterLoginPanel.h"

#if __has_include("inter-Swift.h")
#import "inter-Swift.h"
#endif

// The auth screen is now SwiftUI (`AuthView`), hosted via the Swift `InterAuthHostView`
// bridge. This class is a thin Obj-C shell that preserves the original public API and the
// `InterLoginPanelDelegate` contract, so `AppDelegate` (which owns the auth backend wiring)
// is unchanged. The former AppKit implementation (fields, OAuth buttons, strength meter,
// show/hide toggle) was replaced 1:1 — its behavior now lives in `AuthViewModel` + `AuthView`.

@interface InterLoginPanel ()
@property (nonatomic, strong) InterAuthHostView *host;
@end

@implementation InterLoginPanel

#pragma mark - Lifecycle

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) return nil;
    [self buildAuthHost];
    return self;
}

- (void)buildAuthHost {
    self.host = [[InterAuthHostView alloc] initWithFrame:self.bounds];
    self.host.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    __weak typeof(self) weakSelf = self;
    self.host.onLogin = ^(NSString *email, NSString *password) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.delegate loginPanel:strongSelf didRequestLoginWithEmail:email password:password];
    };
    self.host.onRegister = ^(NSString *email, NSString *password, NSString *displayName) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.delegate loginPanel:strongSelf
            didRequestRegisterWithEmail:email password:password displayName:displayName];
    };
    self.host.onOAuth = ^(NSString *provider) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if ([strongSelf.delegate respondsToSelector:@selector(loginPanel:didRequestOAuthWithProvider:)]) {
            [strongSelf.delegate loginPanel:strongSelf didRequestOAuthWithProvider:provider];
        }
    };
    self.host.onForgotPassword = ^(NSString *email) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if ([strongSelf.delegate respondsToSelector:@selector(loginPanel:didRequestPasswordResetForEmail:)]) {
            [strongSelf.delegate loginPanel:strongSelf didRequestPasswordResetForEmail:email];
        }
    };

    [self addSubview:self.host];
}

#pragma mark - Public API

- (void)showError:(NSString *)message {
    [self.host showError:message ?: @""];
}

- (void)setRegisterMode:(BOOL)isRegister {
    [self.host setRegisterMode:isRegister];
}

- (void)showInfo:(NSString *)message {
    [self.host showInfo:message ?: @""];
}

- (void)clearError {
    [self.host clearError];
}

- (void)setActionsEnabled:(BOOL)enabled {
    [self.host setActionsEnabled:enabled];
}

- (void)setLoading:(BOOL)loading {
    [self.host setLoading:loading];
}

@end
