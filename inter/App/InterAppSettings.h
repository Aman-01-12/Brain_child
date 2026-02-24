#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface InterAppSettings : NSObject

+ (BOOL)hasConfiguredRecordingDirectory;
+ (BOOL)setRecordingDirectoryURL:(NSURL *)directoryURL error:(NSError * _Nullable * _Nullable)error;
+ (nullable NSString *)configuredRecordingDirectoryDisplayPath;
+ (nullable NSURL *)resolvedRecordingDirectoryURLStartingSecurityScope:(BOOL *)didStartAccessing
                                                                 error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END

