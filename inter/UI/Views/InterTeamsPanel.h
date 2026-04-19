// ============================================================================
// InterTeamsPanel.h
// inter
//
// Phase 11.4 — Teams management UI panel.
// Lists teams the user belongs to, allows creating teams, managing members,
// sending invitations, and accepting pending invitations.
// ============================================================================

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class InterTeamsPanel;

@protocol InterTeamsPanelDelegate <NSObject>

/// Create a new team with the given name and optional description.
- (void)teamsPanel:(InterTeamsPanel *)panel
  didRequestCreateTeamName:(NSString *)name
               description:(nullable NSString *)description;

/// Invite one or more email addresses to the given team.
- (void)teamsPanel:(InterTeamsPanel *)panel
didRequestInviteEmails:(NSArray<NSString *> *)emails
            toTeamId:(NSString *)teamId;

/// Accept a pending invitation for the given team.
- (void)teamsPanel:(InterTeamsPanel *)panel
didRequestAcceptInvitationForTeamId:(NSString *)teamId;

/// Remove a member (by memberId) from a team (owner/admin only).
- (void)teamsPanel:(InterTeamsPanel *)panel
didRequestRemoveMemberId:(NSString *)memberId
         fromTeamId:(NSString *)teamId;

/// Delete an entire team (owner only).
- (void)teamsPanel:(InterTeamsPanel *)panel
didRequestDeleteTeamId:(NSString *)teamId;

/// Refresh the teams list from the server.
- (void)teamsPanelDidRequestRefresh:(InterTeamsPanel *)panel;

@end


@interface InterTeamsPanel : NSView

@property (nonatomic, weak, nullable) id<InterTeamsPanelDelegate> delegate;

// -------------------------------------------------------------------------
// Data loading
// -------------------------------------------------------------------------

/// Replace the displayed teams list.
/// Each dict must contain at least: `id`, `name`, `role`, `status`.
/// Optional: `description`, `memberCount`.
- (void)setTeams:(NSArray<NSDictionary<NSString *, id> *> *)teams;

/// Show member detail for the currently selected team.
/// Each member dict: `id`, `teamId`, `email`, `displayName`, `role`, `status`.
- (void)setCurrentTeamMembers:(NSArray<NSDictionary<NSString *, id> *> *)members
                   callerRole:(NSString *)callerRole;

// -------------------------------------------------------------------------
// Status
// -------------------------------------------------------------------------

/// Set a status message shown at the bottom of the panel.
- (void)setStatusText:(NSString *)text;

/// Show or hide a progress spinner.
- (void)setLoading:(BOOL)loading;

// -------------------------------------------------------------------------
// Button state reset (call from delegate after async ops complete)
// -------------------------------------------------------------------------
- (void)resetCreateButton;
- (void)resetInviteButton;
- (void)resetAcceptButton;
- (void)resetDeleteButton;

/// Returns the `id` of the currently selected team, or nil.
- (nullable NSString *)selectedTeamId;

@end

NS_ASSUME_NONNULL_END
