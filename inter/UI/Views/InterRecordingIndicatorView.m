#import "InterRecordingIndicatorView.h"

#import <QuartzCore/QuartzCore.h>

// ---------------------------------------------------------------------------
// MARK: - Constants
// ---------------------------------------------------------------------------

static const CGFloat kRecDotSize = 10.0;
static const CGFloat kRecHorizontalPadding = 10.0;
static const CGFloat kRecItemSpacing = 6.0;
static const CGFloat kRecViewHeight = 28.0;

// ---------------------------------------------------------------------------
// MARK: - InterRecordingIndicatorView
// ---------------------------------------------------------------------------

@implementation InterRecordingIndicatorView {
    NSView *_dotView;
    NSTextField *_recLabel;
    NSTextField *_timeLabel;
    CABasicAnimation *_pulseAnimation;
}

// ---------------------------------------------------------------------------
// MARK: - Init
// ---------------------------------------------------------------------------

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) return nil;

    self.wantsLayer = YES;
    self.layer.backgroundColor = [[NSColor colorWithWhite:0.0 alpha:0.6] CGColor];
    self.layer.cornerRadius = kRecViewHeight / 2.0;

    [self _setupSubviews];

    _indicatorActive = NO;
    _indicatorPaused = NO;
    self.hidden = YES;

    return self;
}

// ---------------------------------------------------------------------------
// MARK: - Subview Setup
// ---------------------------------------------------------------------------

- (void)_setupSubviews {
    // Red dot
    _dotView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kRecDotSize, kRecDotSize)];
    _dotView.wantsLayer = YES;
    _dotView.layer.backgroundColor = [NSColor systemRedColor].CGColor;
    _dotView.layer.cornerRadius = kRecDotSize / 2.0;
    [self addSubview:_dotView];

    // "REC" label
    _recLabel = [self _createLabelWithText:@"REC" bold:YES];
    _recLabel.textColor = [NSColor systemRedColor];
    [self addSubview:_recLabel];

    // Time label "00:00:00"
    _timeLabel = [self _createLabelWithText:@"00:00:00" bold:NO];
    _timeLabel.textColor = [NSColor whiteColor];
    [self addSubview:_timeLabel];

    [self _layoutSubviews];
}

- (NSTextField *)_createLabelWithText:(NSString *)text bold:(BOOL)bold {
    NSTextField *label = [NSTextField labelWithString:text];
    label.editable = NO;
    label.selectable = NO;
    label.bordered = NO;
    label.drawsBackground = NO;
    label.font = bold ? [NSFont boldSystemFontOfSize:11.0] : [NSFont monospacedDigitSystemFontOfSize:11.0 weight:NSFontWeightRegular];
    label.alignment = NSTextAlignmentCenter;
    [label sizeToFit];
    return label;
}

// ---------------------------------------------------------------------------
// MARK: - Layout
// ---------------------------------------------------------------------------

- (void)_layoutSubviews {
    CGFloat x = kRecHorizontalPadding;
    CGFloat midY = kRecViewHeight / 2.0;

    // Dot
    _dotView.frame = NSMakeRect(x, midY - kRecDotSize / 2.0, kRecDotSize, kRecDotSize);
    x += kRecDotSize + kRecItemSpacing;

    // REC label
    NSSize recSize = _recLabel.fittingSize;
    _recLabel.frame = NSMakeRect(x, midY - recSize.height / 2.0, recSize.width, recSize.height);
    x += recSize.width + kRecItemSpacing;

    // Time label
    NSSize timeSize = _timeLabel.fittingSize;
    _timeLabel.frame = NSMakeRect(x, midY - timeSize.height / 2.0, timeSize.width, timeSize.height);
    x += timeSize.width + kRecHorizontalPadding;

    // Set own intrinsic size
    [self setFrameSize:NSMakeSize(x, kRecViewHeight)];
}

- (NSSize)intrinsicContentSize {
    CGFloat width = kRecHorizontalPadding + kRecDotSize + kRecItemSpacing;
    width += _recLabel.fittingSize.width + kRecItemSpacing;
    width += _timeLabel.fittingSize.width + kRecHorizontalPadding;
    return NSMakeSize(width, kRecViewHeight);
}

// ---------------------------------------------------------------------------
// MARK: - Properties
// ---------------------------------------------------------------------------

- (void)setIndicatorActive:(BOOL)indicatorActive {
    _indicatorActive = indicatorActive;
    self.hidden = !indicatorActive;

    if (indicatorActive && !_indicatorPaused) {
        [self _startPulseAnimation];
    } else {
        [self _stopPulseAnimation];
    }

    if (!indicatorActive) {
        _timeLabel.stringValue = @"00:00:00";
    }
}

- (void)setIndicatorPaused:(BOOL)indicatorPaused {
    _indicatorPaused = indicatorPaused;

    if (indicatorPaused) {
        [self _stopPulseAnimation];
        _recLabel.stringValue = @"PAUSED";
        _recLabel.textColor = [NSColor systemYellowColor];
        _dotView.layer.backgroundColor = [NSColor systemYellowColor].CGColor;
        _dotView.layer.opacity = 1.0;
    } else {
        _recLabel.stringValue = @"REC";
        _recLabel.textColor = [NSColor systemRedColor];
        _dotView.layer.backgroundColor = [NSColor systemRedColor].CGColor;
        if (_indicatorActive) {
            [self _startPulseAnimation];
        }
    }

    [_recLabel sizeToFit];
    [self _layoutSubviews];
}

- (void)setElapsedDuration:(NSTimeInterval)duration {
    NSInteger totalSeconds = (NSInteger)duration;
    NSInteger hours = totalSeconds / 3600;
    NSInteger minutes = (totalSeconds % 3600) / 60;
    NSInteger seconds = totalSeconds % 60;

    _timeLabel.stringValue = [NSString stringWithFormat:@"%02ld:%02ld:%02ld",
                              (long)hours, (long)minutes, (long)seconds];
    [self _layoutSubviews];
}

// ---------------------------------------------------------------------------
// MARK: - Pulse Animation
// ---------------------------------------------------------------------------

- (void)_startPulseAnimation {
    [self _stopPulseAnimation];

    CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
    pulse.fromValue = @1.0;
    pulse.toValue = @0.2;
    pulse.duration = 0.8;
    pulse.autoreverses = YES;
    pulse.repeatCount = HUGE_VALF;
    pulse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];

    [_dotView.layer addAnimation:pulse forKey:@"recPulse"];
    _pulseAnimation = pulse;
}

- (void)_stopPulseAnimation {
    [_dotView.layer removeAnimationForKey:@"recPulse"];
    _dotView.layer.opacity = 1.0;
    _pulseAnimation = nil;
}

@end
