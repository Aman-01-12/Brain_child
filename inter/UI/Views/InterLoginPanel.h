#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class InterLoginPanel;

/// Delegate protocol for handling login/register actions from the login panel.
@protocol InterLoginPanelDelegate <NSObject>

/// User tapped "Log In" with valid credentials.
- (void)loginPanel:(InterLoginPanel *)panel
    didRequestLoginWithEmail:(NSString *)email
                    password:(NSString *)password;

/// User tapped "Create Account" with valid fields.
- (void)loginPanel:(InterLoginPanel *)panel
    didRequestRegisterWithEmail:(NSString *)email
                       password:(NSString *)password
                    displayName:(NSString *)displayName;

@end

/// Self-contained login/register panel.
///
/// Two modes: Login (email + password) and Register (email + password + display name).
/// Toggled via a "Create Account" / "Back to Login" link.
@interface InterLoginPanel : NSView

@property (nonatomic, weak, nullable) id<InterLoginPanelDelegate> delegate;

/// Show an error message below the form (e.g. "Invalid credentials").
- (void)showError:(NSString *)message;

/// Clear any displayed error.
- (void)clearError;

/// Enable or disable the action button during async operations.
- (void)setActionsEnabled:(BOOL)enabled;

/// Show or hide a loading spinner.
- (void)setLoading:(BOOL)loading;

@end

NS_ASSUME_NONNULL_END
