#import "InterCallSessionCoordinator.h"

@interface InterCallSessionCoordinator ()
@property (nonatomic, assign, readwrite) InterCallSessionPhase phase;
@property (nonatomic, assign, readwrite) InterCallMode currentCallMode;
@property (nonatomic, assign, readwrite) InterInterviewRole currentInterviewRole;
@end

@implementation InterCallSessionCoordinator

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }

    _phase = InterCallSessionPhaseIdle;
    _currentCallMode = InterCallModeNone;
    _currentInterviewRole = InterInterviewRoleNone;
    return self;
}

- (BOOL)beginEnteringMode:(InterCallMode)mode role:(InterInterviewRole)role {
    if (mode == InterCallModeNone || self.phase != InterCallSessionPhaseIdle) {
        return NO;
    }

    BOOL invalidNormalModeRole = (mode == InterCallModeNormal && role != InterInterviewRoleNone);
    BOOL invalidInterviewModeRole = (mode == InterCallModeInterview && role == InterInterviewRoleNone);
    if (invalidNormalModeRole || invalidInterviewModeRole) {
        return NO;
    }

    self.currentCallMode = mode;
    self.currentInterviewRole = role;
    self.phase = InterCallSessionPhaseEntering;
    return YES;
}

- (void)markActive {
    if (self.phase != InterCallSessionPhaseEntering) {
        return;
    }

    self.phase = InterCallSessionPhaseActive;
}

- (BOOL)beginExit {
    if (self.phase == InterCallSessionPhaseIdle || self.phase == InterCallSessionPhaseExiting) {
        return NO;
    }

    self.phase = InterCallSessionPhaseExiting;
    return YES;
}

- (void)finishExit {
    self.phase = InterCallSessionPhaseIdle;
    self.currentCallMode = InterCallModeNone;
    self.currentInterviewRole = InterInterviewRoleNone;
}

- (void)cancelExitIfNeeded {
    if (self.phase != InterCallSessionPhaseExiting) {
        return;
    }

    if (self.currentCallMode == InterCallModeNone) {
        self.phase = InterCallSessionPhaseIdle;
        self.currentInterviewRole = InterInterviewRoleNone;
        return;
    }

    self.phase = InterCallSessionPhaseActive;
}

@end
