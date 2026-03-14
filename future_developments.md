# Future Developments

## Feature: Multi-Interviewer Roles and Remote Mode Switching

### Status
Deferred for a post-v1 release.

This document describes a future feature where:
1. The interview host can promote additional participants to interviewer.
2. An interviewer can remotely switch an interviewee between secure kiosk mode and normal mode during a live interview.
3. The participant can later be switched back into secure mode.

This is intentionally not part of the first production version. The first version should continue with the current, simpler model:
1. Interview creator is treated as the interviewer.
2. A participant joining an interview room by code is treated as the interviewee.
3. Interviewee enters the secure flow on join.

## Why This Is Deferred

The current app already has a working role approximation:
1. The creator of an interview room acts as the interviewer.
2. A joiner to an interview room enters the interviewee flow.
3. The interviewee path applies the stricter secure window behavior.

That is sufficient for v1 because the relationship is static and predictable.

The proposed future feature is materially different because it introduces live, mutable authority during an active session. That requires a stronger server-authoritative model than the current room-type-based client branching.

## Problem Statement

The current model is entry-driven:
1. Host creates the room.
2. Joiner joins the room.
3. The app derives behavior from room type and local entry flow.

The future feature requires state that can change after join:
1. A normal participant can be promoted to interviewer.
2. An interviewee can be temporarily released from secure mode.
3. The same interviewee can be forced back into secure mode later.
4. These changes must happen without ambiguity, race conditions, or client-side trust assumptions.

This cannot be modeled safely as a simple local UI toggle.

## Architecture Principle

For this feature, the source of truth must be the server.

Use two layers of authority:
1. Join-time authority.
2. Live session authority.

### 1. Join-Time Authority
This should be carried in the token and initial join response.

Examples:
1. Participant identity.
2. Baseline role.
3. Baseline permissions.
4. Whether the participant may issue control actions.

### 2. Live Session Authority
This should be stored and managed by the backend during the room lifetime.

Examples:
1. Current participant role.
2. Current participant runtime mode.
3. Whether the participant is currently in secure mode or normal mode.
4. Which interviewer issued the latest control change.
5. Whether a pending mode switch is awaiting acknowledgment.

## Important Design Rule

JWT metadata alone must not be treated as the only source of truth for this feature.

Reason:
1. Tokens are issued at a point in time.
2. This feature requires live updates after join.
3. Promotions and runtime mode switches are mutable session state.

Therefore:
1. Token = baseline authority.
2. Backend session state = current live authority.

## Proposed Future Data Model

### Participant Role
A participant should have an explicit server-owned role.

Recommended values:
1. `owner`
2. `interviewer`
3. `interviewee`
4. `participant`

`owner` is the creator of the room and has the highest authority for that session.

### Participant Runtime Mode
A participant should also have an explicit live runtime mode.

Recommended values:
1. `secure_interview`
2. `normal_interview`
3. `normal_call`

For the future feature, the key transition is between:
1. `secure_interview`
2. `normal_interview`

### Permission Flags
A role alone is not enough. Add explicit capabilities.

Recommended examples:
1. `canPromoteInterviewer`
2. `canDemoteInterviewer`
3. `canSwitchParticipantMode`
4. `canForceSecureMode`
5. `canReleaseSecureMode`
6. `canShareExternally`
7. `canShareThisApp`
8. `canUseSystemAudio`

## Proposed Server Responsibilities

The backend should own the following responsibilities.

### 1. Role Assignment
The server decides:
1. who is owner,
2. who is interviewer,
3. who is interviewee,
4. who is allowed to change others.

### 2. Session Policy Storage
The server keeps authoritative session state for each participant.

For example:
1. participant identity,
2. current role,
3. current runtime mode,
4. granted capabilities,
5. last change timestamp,
6. last changed by,
7. reason for change.

### 3. Command Validation
Every control action must be validated server-side.

Examples:
1. interviewer attempts to promote another participant,
2. interviewer attempts to switch interviewee from secure to normal,
3. interviewer attempts to restore secure mode.

The server should reject invalid operations, including:
1. participant trying to promote themselves without authority,
2. non-interviewer trying to change another participant,
3. stale commands based on old client state,
4. switching a participant into a mode disallowed by room policy.

### 4. Broadcast of Approved Changes
After validation, the server broadcasts the resulting authoritative update to all affected clients.

The client should react to approved state, not optimistic local assumptions.

## Proposed Control Plane

This feature should use a dedicated control plane, not ad hoc local UI state.

Recommended options:
1. backend WebSocket control channel,
2. LiveKit data channel messages mediated by the server,
3. server-backed command API plus push event stream.

Recommended event types:
1. `participant.role.updated`
2. `participant.mode.updated`
3. `participant.permission.updated`
4. `session.policy.snapshot`
5. `session.policy.error`

Recommended command types:
1. `promote_to_interviewer`
2. `demote_from_interviewer`
3. `switch_to_secure_mode`
4. `switch_to_normal_mode`

Each command should contain:
1. command id,
2. issuer identity,
3. target identity,
4. requested action,
5. reason,
6. client timestamp.

Each approved event should contain:
1. command id,
2. target identity,
3. resulting role or mode,
4. server timestamp,
5. issuer identity,
6. revision number.

## Client-Side Changes Needed In The Future

### 1. Stop Deriving Role Only From Entry Path
Today, the app derives the secure interviewee path largely from room type and join flow.

For this feature, the client must instead derive behavior from authoritative participant policy received from the backend.

### 2. Introduce Session Policy Model
Add a dedicated client-side policy object separate from the room controller's transport state.

Suggested responsibilities:
1. hold current participant role,
2. hold current participant runtime mode,
3. hold permissions,
4. expose revision-based updates,
5. publish change notifications to UI and controllers.

### 3. Separate Identity From Runtime Mode
A participant may remain an `interviewee` while being temporarily placed in `normal_interview` mode.

That means:
1. role and mode must be separate fields,
2. the UI must not assume one implies the other.

### 4. Live Mode Transition Support
The client must support switching between secure and normal interview modes without corrupting session state.

That requires:
1. a stable room connection across mode transitions,
2. deterministic teardown and rebuild of local windows/controllers,
3. reattachment of local media and remote rendering without disconnecting the room,
4. safe restoration of share policy and secure restrictions.

This area depends on fully activating the existing transition-oriented architecture instead of relying on the current full disconnect-and-rebuild exit path.

## Security Requirements

This feature is security-sensitive and must be implemented as fail-closed.

### 1. Client Must Not Self-Elevate
A client must never be able to:
1. declare itself interviewer,
2. declare itself owner,
3. leave secure mode without an approved server event,
4. grant itself broader sharing permissions.

### 2. All Sensitive Changes Must Be Audited
For each role or mode change, log:
1. who initiated it,
2. who was affected,
3. what changed,
4. when it changed,
5. why it changed,
6. whether the client acknowledged it.

### 3. Secure Mode Restore Must Be Strict
When returning a participant to secure mode, the client must reapply all secure restrictions before the transition is considered complete.

### 4. Revision Numbers Must Be Used
Every server policy update should carry a monotonically increasing revision so the client can reject stale or out-of-order updates.

## User Experience Rules To Decide Before Implementation

This feature needs product-policy decisions before engineering begins.

Questions to answer:
1. Can an interviewer switch a participant to normal mode silently?
2. Should the interviewee see a prompt before the change is applied?
3. Should the interviewee see who initiated the change?
4. Can all interviewers switch mode, or only the room owner?
5. Can a promoted interviewer promote others?
6. Can an interviewee request release from secure mode?
7. Should every change require a reason string for audit logs?

These are not implementation details. They define the security model.

## Suggested Future Implementation Plan

### Phase A: Policy Foundation
1. Add a server-side participant policy model.
2. Add baseline role/capability claims to the token and join response.
3. Add a session policy snapshot response after connect.
4. Add policy revisioning.

### Phase B: Command Validation Layer
1. Add server APIs/events for role promotion and mode switching.
2. Validate every command on the server.
3. Broadcast approved policy changes.
4. Reject unauthorized or stale commands.

### Phase C: Client Policy Consumption
1. Add a dedicated client session policy controller.
2. Parse baseline role/capability from join response.
3. Subscribe to live policy update events.
4. Update UI and window flow from session policy, not only from room type.

### Phase D: Runtime Mode Transitions
1. Activate persistent room transitions instead of full room disconnect.
2. Move secure/normal mode switching onto a deterministic transition path.
3. Rebuild only the affected UI/controller layers during mode change.
4. Keep transport, participant presence, and remote subscription state intact.

### Phase E: Audit, Recovery, and Hardening
1. Add audit logs for every role/mode change.
2. Add reconnect behavior that restores latest server policy snapshot.
3. Add stale-update protection using revision numbers.
4. Add chaos tests and race-condition tests.

## Required Tests For The Future Feature

### Functional Tests
1. Owner promotes another participant to interviewer.
2. Promoted interviewer can switch an interviewee to normal mode.
3. Interviewee is switched back to secure mode.
4. Unauthorized participant cannot perform these actions.

### Recovery Tests
1. Participant reconnects and receives latest role and mode.
2. Policy update arrives while client is transitioning windows.
3. Duplicate or stale commands are ignored safely.

### Security Tests
1. Interviewee cannot self-release from secure mode.
2. Forged local UI state cannot elevate authority.
3. Out-of-order policy events do not corrupt mode state.
4. Forced return to secure mode re-applies all restrictions.

## Why We Should Not Build This Before V1

This feature adds:
1. mutable authority,
2. distributed state synchronization,
3. dynamic security policy,
4. audit requirements,
5. live mode transitions.

That is a materially different complexity class from the current first-release scope.

For v1, the simpler model is the correct choice because:
1. it is understandable,
2. it is already implemented in a partial but functional way,
3. it keeps the interview model deterministic,
4. it avoids introducing a high-risk control plane too early.

## Recommended V1 Position

For the first production version, keep the current simplified policy:
1. creator of interview room = interviewer,
2. joiner of interview room = interviewee,
3. interviewee enters secure flow on join,
4. no live role promotions,
5. no live secure/normal switching.

## Trigger For Reopening This Design

Reopen this document only when at least one of the following becomes a product requirement:
1. multiple interviewers in one session,
2. interviewer handoff,
3. temporary release from secure mode,
4. remote secure-mode restore,
5. administrative participant controls during a live interview.
