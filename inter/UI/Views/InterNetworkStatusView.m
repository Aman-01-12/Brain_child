#import "InterNetworkStatusView.h"

@interface InterNetworkStatusView ()
@property (nonatomic, assign) InterNetworkQualityLevel qualityLevel;
@end

@implementation InterNetworkStatusView

static const NSUInteger kBarCount = 4;
static const CGFloat kBarWidth    = 6.0;
static const CGFloat kBarSpacing  = 3.0;
static const CGFloat kBarMinH     = 4.0;
static const CGFloat kBarMaxH     = 16.0;

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) {
        return nil;
    }
    self.qualityLevel = InterNetworkQualityLevelUnknown;
    return self;
}

- (void)setQualityLevel:(InterNetworkQualityLevel)level {
    if (_qualityLevel == level) {
        return;
    }
    _qualityLevel = level;
    [self setNeedsDisplay:YES];
}

- (NSSize)intrinsicContentSize {
    CGFloat totalW = kBarCount * kBarWidth + (kBarCount - 1) * kBarSpacing;
    return NSMakeSize(totalW, kBarMaxH);
}

- (BOOL)isFlipped {
    return NO;
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    NSColor *activeColor = [self colorForLevel:self.qualityLevel];
    NSColor *inactiveColor = [NSColor colorWithWhite:0.3 alpha:0.6];

    NSUInteger filledBars = (NSUInteger)self.qualityLevel;
    CGFloat heightStep = (kBarMaxH - kBarMinH) / (CGFloat)(kBarCount - 1);

    for (NSUInteger i = 0; i < kBarCount; i++) {
        CGFloat x = i * (kBarWidth + kBarSpacing);
        CGFloat barH = kBarMinH + heightStep * i;
        NSRect barRect = NSMakeRect(x, 0, kBarWidth, barH);

        BOOL isFilled = (i < filledBars);
        NSColor *color = isFilled ? activeColor : inactiveColor;
        [color setFill];

        NSBezierPath *bar = [NSBezierPath bezierPathWithRoundedRect:barRect xRadius:1.5 yRadius:1.5];
        [bar fill];
    }
}

- (NSColor *)colorForLevel:(InterNetworkQualityLevel)level {
    switch (level) {
        case InterNetworkQualityLevelExcellent:
            return [NSColor systemGreenColor];
        case InterNetworkQualityLevelGood:
            return [NSColor colorWithRed:0.6 green:0.8 blue:0.2 alpha:1.0];
        case InterNetworkQualityLevelPoor:
            return [NSColor systemOrangeColor];
        case InterNetworkQualityLevelLost:
            return [NSColor systemRedColor];
        case InterNetworkQualityLevelUnknown:
        default:
            return [NSColor colorWithWhite:0.4 alpha:0.8];
    }
}

@end
