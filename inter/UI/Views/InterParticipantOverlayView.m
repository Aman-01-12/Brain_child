#import "InterParticipantOverlayView.h"
#import <QuartzCore/QuartzCore.h>

@interface InterParticipantOverlayView ()
@property (nonatomic, strong) NSView *containerView;
@property (nonatomic, strong) NSView *pulsingDot;
@property (nonatomic, strong) NSTextField *messageLabel;
@property (nonatomic, strong) NSButton *waitButton;
@property (nonatomic, strong) NSButton *endCallButton;
@property (nonatomic, assign) InterParticipantOverlayState currentState;
@end

@implementation InterParticipantOverlayView

#pragma mark - Lifecycle

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) {
        return nil;
    }
    [self buildOverlayUI];
    return self;
}

#pragma mark - Public

- (void)setOverlayState:(InterParticipantOverlayState)state {
    self.currentState = state;

    switch (state) {
        case InterParticipantOverlayStateHidden:
            self.hidden = YES;
            [self stopPulseAnimation];
            break;

        case InterParticipantOverlayStateWaiting:
            self.hidden = NO;
            self.messageLabel.stringValue = @"Waiting for participant…";
            self.pulsingDot.hidden = NO;
            self.waitButton.hidden = YES;
            self.endCallButton.hidden = YES;
            [self startPulseAnimation];
            break;

        case InterParticipantOverlayStateParticipantLeft:
            self.hidden = NO;
            self.messageLabel.stringValue = @"Participant left.";
            self.pulsingDot.hidden = YES;
            self.waitButton.hidden = NO;
            self.endCallButton.hidden = NO;
            [self stopPulseAnimation];
            break;
    }
}

#pragma mark - Actions

- (void)handleWait:(id)sender {
#pragma unused(sender)
    id<InterParticipantOverlayDelegate> d = self.delegate;
    if ([d respondsToSelector:@selector(overlayDidRequestWait:)]) {
        [d overlayDidRequestWait:self];
    }
}

- (void)handleEndCall:(id)sender {
#pragma unused(sender)
    id<InterParticipantOverlayDelegate> d = self.delegate;
    if ([d respondsToSelector:@selector(overlayDidRequestEndCall:)]) {
        [d overlayDidRequestEndCall:self];
    }
}

#pragma mark - Pulse Animation

- (void)startPulseAnimation {
    [self.pulsingDot.layer removeAnimationForKey:@"pulse"];

    CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
    pulse.fromValue = @1.0;
    pulse.toValue = @0.25;
    pulse.duration = 0.9;
    pulse.autoreverses = YES;
    pulse.repeatCount = HUGE_VALF;
    pulse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [self.pulsingDot.layer addAnimation:pulse forKey:@"pulse"];
}

- (void)stopPulseAnimation {
    [self.pulsingDot.layer removeAnimationForKey:@"pulse"];
}

#pragma mark - UI Construction

- (void)buildOverlayUI {
    self.wantsLayer = YES;
    self.layer.backgroundColor = [[NSColor colorWithWhite:0.0 alpha:0.55] CGColor];

    // Centered container
    CGFloat containerW = 280.0;
    CGFloat containerH = 120.0;
    CGFloat cx = (self.bounds.size.width - containerW) / 2.0;
    CGFloat cy = (self.bounds.size.height - containerH) / 2.0;

    self.containerView = [[NSView alloc] initWithFrame:NSMakeRect(cx, cy, containerW, containerH)];
    self.containerView.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin |
                                          NSViewMinYMargin | NSViewMaxYMargin;
    self.containerView.wantsLayer = YES;
    self.containerView.layer.backgroundColor = [[NSColor colorWithWhite:0.1 alpha:0.85] CGColor];
    self.containerView.layer.cornerRadius = 14.0;
    self.containerView.layer.borderWidth = 1.0;
    self.containerView.layer.borderColor = [[NSColor colorWithWhite:1.0 alpha:0.12] CGColor];
    [self addSubview:self.containerView];

    // Pulsing dot
    self.pulsingDot = [[NSView alloc] initWithFrame:NSMakeRect((containerW - 10) / 2.0, 86, 10, 10)];
    self.pulsingDot.wantsLayer = YES;
    self.pulsingDot.layer.cornerRadius = 5.0;
    self.pulsingDot.layer.backgroundColor = [NSColor systemGreenColor].CGColor;
    self.pulsingDot.hidden = YES;
    [self.containerView addSubview:self.pulsingDot];

    // Message label
    self.messageLabel = [NSTextField labelWithString:@""];
    self.messageLabel.frame = NSMakeRect(10, 56, containerW - 20, 22);
    self.messageLabel.alignment = NSTextAlignmentCenter;
    self.messageLabel.font = [NSFont systemFontOfSize:15 weight:NSFontWeightMedium];
    self.messageLabel.textColor = [NSColor colorWithWhite:0.92 alpha:1.0];
    [self.containerView addSubview:self.messageLabel];

    // Wait button
    CGFloat btnW = 110.0;
    CGFloat btnH = 30.0;
    CGFloat btnY = 14.0;
    self.waitButton = [[NSButton alloc] initWithFrame:NSMakeRect(20, btnY, btnW, btnH)];
    [self.waitButton setTitle:@"Wait"];
    [self.waitButton setTarget:self];
    [self.waitButton setAction:@selector(handleWait:)];
    self.waitButton.hidden = YES;
    [self.containerView addSubview:self.waitButton];

    // End Call button
    self.endCallButton = [[NSButton alloc] initWithFrame:NSMakeRect(containerW - btnW - 20, btnY, btnW, btnH)];
    [self.endCallButton setTitle:@"End Call"];
    [self.endCallButton setTarget:self];
    [self.endCallButton setAction:@selector(handleEndCall:)];
    self.endCallButton.hidden = YES;
    [self.containerView addSubview:self.endCallButton];
}

@end
