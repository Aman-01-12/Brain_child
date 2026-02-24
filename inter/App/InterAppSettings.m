#import "InterAppSettings.h"

static NSString *const InterRecordingDirectoryBookmarkDefaultsKey = @"secure.inter.settings.recordingDirectoryBookmark";

@implementation InterAppSettings

+ (BOOL)hasConfiguredRecordingDirectory {
    NSData *bookmark = [[NSUserDefaults standardUserDefaults] objectForKey:InterRecordingDirectoryBookmarkDefaultsKey];
    return bookmark.length > 0;
}

+ (BOOL)setRecordingDirectoryURL:(NSURL *)directoryURL error:(NSError **)error {
    if (!directoryURL.isFileURL) {
        if (error) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                         code:NSFileWriteInvalidFileNameError
                                     userInfo:@{NSLocalizedDescriptionKey: @"Recording directory must be a local folder."}];
        }
        return NO;
    }

    NSURL *normalizedURL = directoryURL.URLByStandardizingPath;
    NSData *bookmark = [normalizedURL bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope
                               includingResourceValuesForKeys:nil
                                                relativeToURL:nil
                                                        error:error];
    if (bookmark.length == 0) {
        return NO;
    }

    [[NSUserDefaults standardUserDefaults] setObject:bookmark forKey:InterRecordingDirectoryBookmarkDefaultsKey];
    return YES;
}

+ (nullable NSString *)configuredRecordingDirectoryDisplayPath {
    NSError *error = nil;
    NSURL *url = [self resolvedURLAllowingUI:NO startScope:NO error:&error];
    if (!url || error) {
        return nil;
    }

    return url.path;
}

+ (nullable NSURL *)resolvedRecordingDirectoryURLStartingSecurityScope:(BOOL *)didStartAccessing
                                                                 error:(NSError **)error {
    return [self resolvedURLAllowingUI:NO startScope:YES error:error didStartAccessing:didStartAccessing];
}

+ (nullable NSURL *)resolvedURLAllowingUI:(BOOL)allowUI
                               startScope:(BOOL)startScope
                                    error:(NSError **)error {
    BOOL ignoredDidStart = NO;
    return [self resolvedURLAllowingUI:allowUI
                            startScope:startScope
                                 error:error
                     didStartAccessing:&ignoredDidStart];
}

+ (nullable NSURL *)resolvedURLAllowingUI:(BOOL)allowUI
                               startScope:(BOOL)startScope
                                    error:(NSError **)error
                        didStartAccessing:(BOOL *)didStartAccessing {
    if (didStartAccessing) {
        *didStartAccessing = NO;
    }

    NSData *bookmark = [[NSUserDefaults standardUserDefaults] objectForKey:InterRecordingDirectoryBookmarkDefaultsKey];
    if (bookmark.length == 0) {
        return nil;
    }

    BOOL bookmarkIsStale = NO;
    NSURLBookmarkResolutionOptions options = NSURLBookmarkResolutionWithSecurityScope;
    if (!allowUI) {
        options |= NSURLBookmarkResolutionWithoutUI;
    }

    NSURL *resolvedURL = [NSURL URLByResolvingBookmarkData:bookmark
                                                   options:options
                                             relativeToURL:nil
                                       bookmarkDataIsStale:&bookmarkIsStale
                                                     error:error];
    if (!resolvedURL) {
        return nil;
    }

    if (bookmarkIsStale) {
        NSError *bookmarkError = nil;
        NSData *freshBookmark = [resolvedURL bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope
                                      includingResourceValuesForKeys:nil
                                                       relativeToURL:nil
                                                               error:&bookmarkError];
        if (freshBookmark.length > 0) {
            [[NSUserDefaults standardUserDefaults] setObject:freshBookmark
                                                      forKey:InterRecordingDirectoryBookmarkDefaultsKey];
        } else if (error) {
            *error = bookmarkError;
        }
    }

    if (!startScope) {
        return resolvedURL;
    }

    BOOL didStart = [resolvedURL startAccessingSecurityScopedResource];
    if (didStartAccessing) {
        *didStartAccessing = didStart;
    }
    if (!didStart && error) {
        *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                     code:NSFileReadNoPermissionError
                                 userInfo:@{NSLocalizedDescriptionKey: @"Failed to access configured recording directory."}];
    }
    return resolvedURL;
}

@end

