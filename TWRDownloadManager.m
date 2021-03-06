//
//  TWRDownloadManager.m
//  DownloadManager
//
//  Created by Michelangelo Chasseur on 25/07/14.
//  Copyright (c) 2014 Touchware. All rights reserved.
//

#import "TWRDownloadManager.h"
#import "TWRDownloadObject.h"

@interface TWRDownloadManager () <NSURLSessionDelegate, NSURLSessionDownloadDelegate>

@property (strong, nonatomic) NSURLSession *session;
@property (strong, nonatomic) NSMutableDictionary *downloads;

@end

@implementation TWRDownloadManager

+ (instancetype)sharedManager {
    static TWRDownloadManager *_sharedManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _sharedManager = [[TWRDownloadManager alloc] init];
    });
    
    return _sharedManager;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        self.session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
        self.downloads = [NSMutableDictionary new];
    }
    return self;
}

- (void)downloadFileForURL:(NSString *)urlString
                  withName:(NSString *)fileName
          inDirectoryNamed:(NSString *)directory
             progressBlock:(void(^)(CGFloat progress))progressBlock
           completionBlock:(void(^)(BOOL completed))completionBlock {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!fileName) {
        fileName = [urlString lastPathComponent];
    }
    
    if (![self fileDownloadCompletedForUrl:urlString]) {
        NSLog(@"File is downloading!");
    } else if (![self fileExistsWithName:fileName inDirectory:directory]) {
        NSURLRequest *request = [NSURLRequest requestWithURL:url];
        NSURLSessionDownloadTask *downloadTask = [self.session downloadTaskWithRequest:request];
        TWRDownloadObject *downloadObject = [[TWRDownloadObject alloc] initWithDownloadTask:downloadTask progressBlock:progressBlock completionBlock:completionBlock];
        downloadObject.fileName = fileName;
        downloadObject.directoryName = directory;
        [self.downloads addEntriesFromDictionary:@{urlString:downloadObject}];
        [downloadTask resume];
    } else {
        NSLog(@"File already exists!");
    }
}

- (void)downloadFileForURL:(NSString *)urlString
          inDirectoryNamed:(NSString *)directory
             progressBlock:(void(^)(CGFloat progress))progressBlock
           completionBlock:(void(^)(BOOL completed))completionBlock {
    // if no file name was provided, use the last path component of the URL as its name
    [self downloadFileForURL:urlString
                    withName:[urlString lastPathComponent]
            inDirectoryNamed:directory
               progressBlock:progressBlock
             completionBlock:completionBlock];
}

- (void)downloadFileForURL:(NSString *)urlString
             progressBlock:(void(^)(CGFloat progress))progressBlock
           completionBlock:(void(^)(BOOL completed))completionBlock {
    [self downloadFileForURL:urlString
            inDirectoryNamed:nil
               progressBlock:progressBlock
             completionBlock:completionBlock];
}

- (void)cancelDownloadForUrl:(NSString *)fileIdentifier {
    TWRDownloadObject *download = [self.downloads objectForKey:fileIdentifier];
    if (download) {
        [download.downloadTask cancel];
        [self.downloads removeObjectForKey:fileIdentifier];
        if (download.completionBlock) {
            download.completionBlock(NO);
        }
    }
    if (self.downloads.count == 0) {
        [self cleanTmpDirectory];
        
    }
}

- (void)cancelAllDownloads {
    [self.downloads enumerateKeysAndObjectsUsingBlock:^(id key, TWRDownloadObject *download, BOOL *stop) {
        if (download.completionBlock) {
            download.completionBlock(NO);
        }
        [download.downloadTask cancel];
        [self.downloads removeObjectForKey:key];
    }];
    [self cleanTmpDirectory];
}

- (NSArray *)currentDownloads {
    NSMutableArray *currentDownloads = [NSMutableArray new];
    [self.downloads enumerateKeysAndObjectsUsingBlock:^(id key, TWRDownloadObject *download, BOOL *stop) {
        [currentDownloads addObject:download.downloadTask.originalRequest.URL.absoluteString];
    }];
    return currentDownloads;
}

#pragma mark - NSURLSession Delegate

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    NSString *fileIdentifier = downloadTask.originalRequest.URL.absoluteString;
    TWRDownloadObject *download = [self.downloads objectForKey:fileIdentifier];
    if (download.progressBlock) {
        CGFloat progress = (CGFloat)totalBytesWritten / (CGFloat)totalBytesExpectedToWrite;
        download.progressBlock(progress);
    }
}

-(void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didResumeAtOffset:(int64_t)fileOffset expectedTotalBytes:(int64_t)expectedTotalBytes {
    //
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)location {
    NSLog(@"Download finisehd!");
    
    NSError *error;
    NSURL *destinationLocation;
    
    NSString *fileIdentifier = downloadTask.originalRequest.URL.absoluteString;
    TWRDownloadObject *download = [self.downloads objectForKey:fileIdentifier];
    
    if (download.directoryName) {
        destinationLocation = [[[self cachesDirectoryUrlPath] URLByAppendingPathComponent:download.directoryName] URLByAppendingPathComponent:download.fileName];
    } else {
        destinationLocation = [[self cachesDirectoryUrlPath] URLByAppendingPathComponent:download.fileName];
    }
    
    // Move downloaded item from tmp directory to te caches directory
    // (not synced with user's iCloud documents)
    [[NSFileManager defaultManager] moveItemAtURL:location
                                            toURL:destinationLocation
                                            error:&error];
    if (error) {
        NSLog(@"ERROR: %@", error);
    }
    
    if (download.completionBlock) {
        download.completionBlock(YES);
    }
    
    // remove object from the download
    [self.downloads removeObjectForKey:fileIdentifier];
}

#pragma mark - File Management

- (NSURL *)cachesDirectoryUrlPath {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *cachesDirectory = [paths objectAtIndex:0];
    NSURL *cachesDirectoryUrl = [NSURL fileURLWithPath:cachesDirectory];
    return cachesDirectoryUrl;
}

- (BOOL)fileDownloadCompletedForUrl:(NSString *)fileIdentifier {
    BOOL retValue = YES;
    TWRDownloadObject *download = [self.downloads objectForKey:fileIdentifier];
    if (download) {
        // downloads are removed once they finish
        retValue = NO;
    }
    return retValue;
}

- (BOOL)isFileDownloadingForUrl:(NSString *)fileIdentifier
              withProgressBlock:(void(^)(CGFloat progress))block {
    return [self isFileDownloadingForUrl:fileIdentifier
                       withProgressBlock:block
                         completionBlock:nil];
}

- (BOOL)isFileDownloadingForUrl:(NSString *)fileIdentifier
              withProgressBlock:(void(^)(CGFloat progress))block
                completionBlock:(void(^)(BOOL completed))completionBlock {
    BOOL retValue = NO;
    TWRDownloadObject *download = [self.downloads objectForKey:fileIdentifier];
    if (download) {
        download.progressBlock = block;
        download.completionBlock = completionBlock;
        retValue = YES;
    }
    return retValue;
}

#pragma mark File existance

- (NSString *)localPathForFile:(NSString *)fileIdentifier {
    return [self localPathForFile:fileIdentifier inDirectory:nil];
}

- (NSString *)localPathForFile:(NSString *)fileIdentifier inDirectory:(NSString *)directoryName {
    NSString *fileName = [fileIdentifier lastPathComponent];
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *cachesDirectory = [paths objectAtIndex:0];
    return [[cachesDirectory stringByAppendingPathComponent:directoryName] stringByAppendingPathComponent:fileName];
}

- (BOOL)fileExistsForUrl:(NSString *)urlString {
    return [self fileExistsForUrl:urlString inDirectory:nil];
}

- (BOOL)fileExistsForUrl:(NSString *)urlString inDirectory:(NSString *)directoryName {
    return [self fileExistsWithName:[urlString lastPathComponent] inDirectory:directoryName];
}

- (BOOL)fileExistsWithName:(NSString *)fileName
               inDirectory:(NSString *)directoryName {
    BOOL exists = NO;
    
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *cachesDirectory = [paths objectAtIndex:0];
    
    // if no directory was provided, we look by default in the base cached dir
    if ([[NSFileManager defaultManager] fileExistsAtPath:[[cachesDirectory stringByAppendingPathComponent:directoryName] stringByAppendingPathComponent:fileName]]) {
        exists = YES;
    }
    
    return exists;
}

- (BOOL)fileExistsWithName:(NSString *)fileName {
    return [self fileExistsWithName:fileName inDirectory:nil];
}

#pragma mark File deletion

- (BOOL)deleteFileForUrl:(NSString *)urlString {
    return [self deleteFileForUrl:urlString inDirectory:nil];
}

- (BOOL)deleteFileForUrl:(NSString *)urlString inDirectory:(NSString *)directoryName {
    return [self deleteFileWithName:[urlString lastPathComponent] inDirectory:directoryName];
}

- (BOOL)deleteFileWithName:(NSString *)fileName {
    return [self deleteFileWithName:fileName inDirectory:nil];
}

- (BOOL)deleteFileWithName:(NSString *)fileName
               inDirectory:(NSString *)directoryName {
    BOOL deleted = NO;
    
    NSError *error;
    NSURL *fileLocation;
    if (directoryName) {
        fileLocation = [[[self cachesDirectoryUrlPath] URLByAppendingPathComponent:directoryName] URLByAppendingPathComponent:fileName];
    } else {
        fileLocation = [[self cachesDirectoryUrlPath] URLByAppendingPathComponent:fileName];
    }
    
    
    // Move downloaded item from tmp directory to te caches directory
    // (not synced with user's iCloud documents)
    [[NSFileManager defaultManager] removeItemAtURL:fileLocation error:&error];
    
    if (error) {
        deleted = NO;
        NSLog(@"Error deleting file: %@", error);
    } else {
        deleted = YES;
    }
    return deleted;
}

#pragma mark - Clean tmp directory

- (void)cleanTmpDirectory {
    NSArray* tmpDirectory = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:NSTemporaryDirectory() error:NULL];
    for (NSString *file in tmpDirectory) {
        [[NSFileManager defaultManager] removeItemAtPath:[NSString stringWithFormat:@"%@%@", NSTemporaryDirectory(), file] error:NULL];
    }
}

@end
