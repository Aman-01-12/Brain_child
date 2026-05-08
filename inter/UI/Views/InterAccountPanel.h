// ============================================================================
// InterAccountPanel.h
// inter
//
// Account management panel — Profile, Security, and Danger Zone.
//
// Provides UI surfaces for:
//   • Viewing current email and subscription tier
//   • Changing password (POST /auth/change-password)
//   • Changing email address (POST /auth/change-email → verification link)
//   • Listing and revoking active sessions (GET+DELETE /auth/sessions)
//   • Deleting the account (DELETE /auth/account)
//
// ISOLATION INVARIANT [G8]:
// This view has NO side effects on networking or auth state directly.
// All actions are forwarded to the delegate, which calls InterTokenService.
// ============================================================================

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class InterAccountPanel;

// ---------------------------------------------------------------------------
// MARK: - Delegate Protocol
// ---------------------------------------------------------------------------

@protocol InterAccountPanelDelegate <NSObject>

/// User submitted a password change. Delegate calls POST /auth/change-password
/// and invokes the completion block with nil on success or an NSError on failure.
- (void)accountPanel:(InterAccountPanel *)panel
  didRequestChangePassword:(NSString *)currentPassword
             newPassword:(NSString *)newPassword
              completion:(void (^)(NSError *_Nullable error))completion;

/// User submitted an email change. Delegate calls POST /auth/change-email
/// and invokes completion with nil on success (verification email sent).
- (void)accountPanel:(InterAccountPanel *)panel
   didRequestChangeEmail:(NSString *)password
               newEmail:(NSString *)newEmail
             completion:(void (^)(NSError *_Nullable error))completion;

/// Panel requests the active sessions list. Delegate calls GET /auth/sessions.
- (void)accountPanelDidRequestLoadSessions:(InterAccountPanel *)panel
                                completion:(void (^)(NSArray<NSDictionary *> *_Nullable sessions,
                                                     NSError *_Nullable error))completion;

/// User tapped "Revoke" on a session row. Delegate calls DELETE /auth/sessions/:id.
- (void)accountPanel:(InterAccountPanel *)panel
 didRequestRevokeSession:(NSString *)sessionId
             completion:(void (^)(NSError *_Nullable error))completion;

/// User confirmed account deletion. Delegate calls DELETE /auth/account.
/// On success, delegate should also clear auth state and show the login UI.
- (void)accountPanel:(InterAccountPanel *)panel
 didRequestDeleteAccount:(NSString *)password
             completion:(void (^)(NSError *_Nullable error))completion;

@optional

/// Called after the server confirmed account deletion (after the completion
/// above fires with nil). The delegate should dismiss the account window and
/// show the login screen.
///
/// If this method is not implemented, InterAccountPanel will dismiss its own
/// window as a safe fallback, preventing the UI from being left open after
/// a successful deletion.
- (void)accountPanelDidDeleteAccount:(InterAccountPanel *)panel;

@end

// ---------------------------------------------------------------------------
// MARK: - InterAccountPanel
// ---------------------------------------------------------------------------

/// A self-contained account management view displayed in its own window.
///
/// Contains four sections in a scrollable layout:
///   1. Profile  — current email and subscription tier
///   2. Security — change password + change email forms
///   3. Sessions — active session list with per-row revoke buttons
///   4. Danger Zone — account deletion with password confirmation
///
/// All network I/O is delegated; the view only handles layout and user input.
@interface InterAccountPanel : NSView <NSTableViewDataSource, NSTableViewDelegate>

/// Delegate that handles all network operations. Typically the AppDelegate.
@property (nonatomic, weak, nullable) id<InterAccountPanelDelegate> delegate;

/// Populate the profile section with live data. Call on the main thread after
/// the window opens so the UI reflects the current authenticated session.
- (void)setEmail:(nullable NSString *)email tier:(nullable NSString *)tier;

/// Populate the sessions table. Passing nil or an empty array shows an empty state.
- (void)setSessions:(nullable NSArray<NSDictionary *> *)sessions;

/// Show or hide the loading spinner over the sessions table.
- (void)setSessionsLoading:(BOOL)loading;

/// Display a transient error banner at the top of the panel.
- (void)showBannerError:(NSString *)message;

/// Clear the error banner.
- (void)clearBanner;

@end

NS_ASSUME_NONNULL_END
