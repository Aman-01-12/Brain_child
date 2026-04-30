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
/// Shows two distinct sections: Local Recordings and Cloud Recordings.
@interface InterRecordingListPanel : NSView

@property (nonatomic, weak, nullable) id<InterRecordingListPanelDelegate> delegate;

/// Reload the recording list (local filesystem scan + cloud fetch from server).
- (void)reloadRecordings;

/// Set the base URL for the token server (e.g. "http://localhost:3000").
@property (nonatomic, copy, nullable) NSString *serverBaseURL;

/// Set the access token for cloud recording API calls.
@property (nonatomic, copy, nullable) NSString *accessToken;

/// Set cloud recordings fetched from the server (replaces cloud section only).
- (void)setCloudRecordings:(NSArray<InterRecordingListEntry *> *)recordings;

/// Set recordings from a fetched array (called by the coordinator/AppDelegate).
- (void)setRecordings:(NSArray<InterRecordingListEntry *> *)recordings;

/// Add local recordings from the filesystem.
- (void)addLocalRecordings:(NSArray<NSURL *> *)fileURLs;

/// Total number of recordings displayed (local + cloud).
@property (nonatomic, readonly) NSUInteger recordingCount;

@end

NS_ASSUME_NONNULL_END
