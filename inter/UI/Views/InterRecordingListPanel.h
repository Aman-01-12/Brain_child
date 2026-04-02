#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class InterRecordingListPanel;

/// A single recording entry displayed in the list panel.
@interface InterRecordingListEntry : NSObject
@property (nonatomic, copy) NSString *recordingId;
@property (nonatomic, copy) NSString *roomName;
@property (nonatomic, copy) NSString *roomCode;
@property (nonatomic, copy) NSString *recordingMode;   // "local_composed" | "cloud_composed" | "multi_track"
@property (nonatomic, copy, nullable) NSString *status; // "completed" | "failed"
@property (nonatomic, strong, nullable) NSDate *startedAt;
@property (nonatomic, strong, nullable) NSDate *endedAt;
@property (nonatomic, assign) NSInteger durationSeconds;
@property (nonatomic, assign) long long fileSizeBytes;
@property (nonatomic, assign) BOOL watermarked;
@end

/// Delegate protocol for recording list panel actions.
@protocol InterRecordingListPanelDelegate <NSObject>
@optional
/// User wants to download a recording.
- (void)recordingListPanel:(InterRecordingListPanel *)panel didRequestDownload:(NSString *)recordingId;
/// User wants to delete a recording.
- (void)recordingListPanel:(InterRecordingListPanel *)panel didRequestDelete:(NSString *)recordingId;
/// User wants to open the local recording file.
- (void)recordingListPanel:(InterRecordingListPanel *)panel didRequestOpenLocal:(NSURL *)fileURL;
@end

/// Panel displaying the user's recording history.
/// Fetches recordings from the token server and shows them in a table view.
@interface InterRecordingListPanel : NSView

@property (nonatomic, weak, nullable) id<InterRecordingListPanelDelegate> delegate;

/// Reload the recording list from the server.
- (void)reloadRecordings;

/// Set the base URL for the token server (e.g. "http://localhost:3000").
@property (nonatomic, copy, nullable) NSString *serverBaseURL;

/// Set recordings from a fetched array (called by the coordinator/AppDelegate).
- (void)setRecordings:(NSArray<InterRecordingListEntry *> *)recordings;

/// Add local recordings from the filesystem.
- (void)addLocalRecordings:(NSArray<NSURL *> *)fileURLs;

/// Total number of recordings displayed.
@property (nonatomic, readonly) NSUInteger recordingCount;

@end

NS_ASSUME_NONNULL_END
