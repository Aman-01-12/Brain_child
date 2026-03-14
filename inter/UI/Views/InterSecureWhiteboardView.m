#import "InterSecureWhiteboardView.h"

static const CGFloat InterSecureWhiteboardStrokeWidth = 3.0;
static const CGFloat InterSecureWhiteboardGridSpacing = 32.0;
static const CGFloat InterSecureWhiteboardCornerRadius = 16.0;

@interface InterSecureWhiteboardView ()
@property (nonatomic, strong) NSMutableArray<NSBezierPath *> *completedStrokes;
@property (nonatomic, strong, nullable) NSBezierPath *currentStroke;
@end

@implementation InterSecureWhiteboardView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) {
        return nil;
    }

    _completedStrokes = [NSMutableArray array];
    self.wantsLayer = YES;
    self.canDrawSubviewsIntoLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawDuringViewResize;
    self.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.09 alpha:1.0].CGColor;
    self.layer.cornerRadius = InterSecureWhiteboardCornerRadius;
    self.layer.masksToBounds = YES;
    self.layer.borderWidth = 1.0;
    self.layer.borderColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.08].CGColor;
    return self;
}

- (BOOL)isFlipped {
    return NO;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)clearCanvas {
    [self.completedStrokes removeAllObjects];
    self.currentStroke = nil;
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    // The whiteboard is captured as a secure-tool surface. Clipping the draw pass
    // to the rounded bounds avoids transient square-corner flashes during resize
    // and tool switching while keeping the local and shared visuals identical.
    NSBezierPath *clipPath = [NSBezierPath bezierPathWithRoundedRect:self.bounds
                                                             xRadius:InterSecureWhiteboardCornerRadius
                                                             yRadius:InterSecureWhiteboardCornerRadius];
    [clipPath addClip];

    [[NSColor colorWithCalibratedWhite:0.09 alpha:1.0] setFill];
    NSRectFill(self.bounds);

    [self drawGridInRect:self.bounds];

    [[NSColor colorWithCalibratedWhite:0.96 alpha:1.0] setStroke];
    for (NSBezierPath *stroke in self.completedStrokes) {
        [stroke stroke];
    }

    [self.currentStroke stroke];
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];

    self.currentStroke = [NSBezierPath bezierPath];
    self.currentStroke.lineWidth = InterSecureWhiteboardStrokeWidth;
    self.currentStroke.lineCapStyle = NSLineCapStyleRound;
    self.currentStroke.lineJoinStyle = NSLineJoinStyleRound;
    [self.currentStroke moveToPoint:point];
    [self.currentStroke lineToPoint:point];
    [self setNeedsDisplay:YES];
}

- (void)mouseDragged:(NSEvent *)event {
    if (!self.currentStroke) {
        return;
    }

    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    [self.currentStroke lineToPoint:point];
    [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent *)event {
#pragma unused(event)
    if (!self.currentStroke) {
        return;
    }

    [self.completedStrokes addObject:self.currentStroke];
    self.currentStroke = nil;
    [self setNeedsDisplay:YES];
}

#pragma mark - Private

- (void)drawGridInRect:(NSRect)rect {
    [[NSColor colorWithCalibratedWhite:1.0 alpha:0.05] setStroke];

    NSBezierPath *gridPath = [NSBezierPath bezierPath];
    gridPath.lineWidth = 1.0;

    CGFloat maxX = NSMaxX(rect);
    CGFloat maxY = NSMaxY(rect);
    for (CGFloat x = 0.0; x <= maxX; x += InterSecureWhiteboardGridSpacing) {
        [gridPath moveToPoint:NSMakePoint(x, 0.0)];
        [gridPath lineToPoint:NSMakePoint(x, maxY)];
    }
    for (CGFloat y = 0.0; y <= maxY; y += InterSecureWhiteboardGridSpacing) {
        [gridPath moveToPoint:NSMakePoint(0.0, y)];
        [gridPath lineToPoint:NSMakePoint(maxX, y)];
    }

    [gridPath stroke];
}

@end
