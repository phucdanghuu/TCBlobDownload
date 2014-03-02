//
//  TCBlobDownload.m
//
//  Created by Thibault Charbonnier on 15/04/13.
//  Copyright (c) 2013 Thibault Charbonnier. All rights reserved.
//

static const double kBufferSize = 1024*1024; // 1 MB
static const NSTimeInterval kDefaultTimeout = 30;
static const NSInteger kNumberOfSamples = 5;
static NSString * const kErrorDomain = @"com.thibaultcha.tcblobdownload";
static NSString * const HTTPErrorCode = @"httpStatus";

#import "TCBlobDownloader.h"
#import "UIDevice-Hardware.h"

@interface TCBlobDownloader ()
// Public
@property (nonatomic, copy, readwrite) NSURL *downloadURL;
@property (nonatomic, copy, readwrite) NSString *pathToFile;
@property (nonatomic, copy, readwrite) NSString *fileName;
// Download
@property (nonatomic, strong) NSURLConnection *connection;
@property (nonatomic, strong) NSMutableData *receivedDataBuffer;
@property (nonatomic, strong) NSFileHandle *file;
// Speed rate and remaining time
@property (nonatomic, strong) NSTimer *speedTimer;
@property (nonatomic, strong) NSMutableArray *samplesOfDownloadedBytes;
@property (nonatomic, assign) uint64_t expectedDataLength;
@property (nonatomic, assign) uint64_t receivedDataLength;
@property (nonatomic, assign, readwrite) NSInteger speedRate;
@property (nonatomic, assign, readwrite) NSInteger remainingTime;
// Blocks
@property (nonatomic, copy) void (^firstResponseBlock)(NSURLResponse *response);
@property (nonatomic, copy) void (^progressBlock)(float receivedLength, float totalLength, NSInteger remainingTime);
@property (nonatomic, copy) void (^errorBlock)(NSError *error);
@property (nonatomic, copy) void (^completionBlock)(BOOL downloadFinished, NSString *pathToFile);
- (void)notifyFromError:(NSError *)error;
- (void)notifyFromCompletionWithSuccess:(BOOL)success pathToFile:(NSString *)pathToFile;
- (void)updateTransferRate;
- (void)finishOperation;
@end

@implementation TCBlobDownloader


#pragma mark - Dealloc


- (void)dealloc
{
    [self.speedTimer invalidate];
}


#pragma mark - Init


- (instancetype)initWithURL:(NSURL *)url
               downloadPath:(NSString *)pathToDL
                   delegate:(id<TCBlobDownloaderDelegate>)delegateOrNil

{
    self = [super init];
    if (self) {
        self.downloadURL = url;
        self.delegate = delegateOrNil;
        self.pathToDownloadDirectory = pathToDL;
    }
    return self;
}

- (instancetype)initWithURL:(NSURL *)url
               downloadPath:(NSString *)pathToDL
              firstResponse:(void (^)(NSURLResponse *response))firstResponseBlock
                   progress:(void (^)(float receivedLength, float totalLength, NSInteger remainingTime))progressBlock
                      error:(void (^)(NSError *error))errorBlock
                   complete:(void (^)(BOOL downloadFinished, NSString *pathToFile))completeBlock
{
    self = [self initWithURL:url downloadPath:pathToDL delegate:nil];
    if (self) {
        self.firstResponseBlock = firstResponseBlock;
        self.progressBlock = progressBlock;
        self.errorBlock = errorBlock;
        self.completionBlock = completeBlock;
    }
    return self;
}


#pragma mark - NSOperation Override


- (void)start
{
    NSMutableURLRequest *fileRequest = [NSMutableURLRequest requestWithURL:self.downloadURL
                                                               cachePolicy:NSURLRequestUseProtocolCachePolicy
                                                           timeoutInterval:kDefaultTimeout];
    
    // If we can't handle the request, better cancelling the operation right now
    if (![NSURLConnection canHandleRequest:fileRequest]) {
        NSError *error = [NSError errorWithDomain:kErrorDomain
                                             code:1
                                         userInfo:@{ NSLocalizedDescriptionKey:
                                        [NSString stringWithFormat:@"Invalid URL provided: %@", fileRequest.URL] }];
        
        [self notifyFromError:error];
        [self cancelDownloadAndRemoveFile:NO];
        
        return;
    }
    
    // Test if file already exists (partly downloaded) to set HTTP `bytes` header or not
    NSFileManager *fm = [NSFileManager defaultManager];

    if (![fm fileExistsAtPath:self.pathToFile]) {
        [fm createFileAtPath:self.pathToFile
                    contents:nil
                  attributes:nil];
    }
    else {
        uint64_t fileSize = [[fm attributesOfItemAtPath:self.pathToFile error:nil] fileSize];
        NSString *range = [NSString stringWithFormat:@"bytes=%lld-", fileSize];
        [fileRequest setValue:range forHTTPHeaderField:@"Range"];
    }
    
    // Initialization of everything we'll need to download the file
    _file = [NSFileHandle fileHandleForWritingAtPath:self.pathToFile];
    [self.file seekToEndOfFile];
    _receivedDataBuffer = [[NSMutableData alloc] init];
    _samplesOfDownloadedBytes = [[NSMutableArray alloc] init];
    _connection = [[NSURLConnection alloc] initWithRequest:fileRequest
                                                  delegate:self
                                          startImmediately:NO];
    if (self.connection) {
        // Start the download
        NSRunLoop* runLoop = [NSRunLoop currentRunLoop];
        [self.connection scheduleInRunLoop:runLoop
                                   forMode:NSDefaultRunLoopMode];
        
        [self willChangeValueForKey:@"isExecuting"];
        [self.connection start];
        // Start the speed timer to schedule speed download on a periodic basis
        self.speedTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                           target:self
                                                         selector:@selector(updateTransferRate)
                                                         userInfo:nil
                                                          repeats:YES];
        [runLoop addTimer:self.speedTimer forMode:NSRunLoopCommonModes];
        [runLoop run];
        [self didChangeValueForKey:@"isExecuting"];
    }
}

- (BOOL)isExecuting
{
    return self.connection != nil;
}

- (BOOL)isFinished
{
    return self.connection == nil;
}


#pragma mark - NSURLConnection Delegate


- (void)connection:(NSURLConnection*)connection didFailWithError:(NSError *)error
{
    NSError *downloadError = [NSError errorWithDomain:kErrorDomain
                                                 code:4
                                             userInfo:@{ NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Download failed for file: %@. Reason: %@",
                                                                                    self.fileName,
                                                                                    error.localizedDescription] }];
    [self notifyFromError:downloadError];
    [self cancelDownloadAndRemoveFile:NO];
}

- (void)connection:(NSURLConnection*)connection didReceiveResponse:(NSURLResponse *)response
{
    self.expectedDataLength = [response expectedContentLength];
    NSHTTPURLResponse *httpUrlResponse = (NSHTTPURLResponse *)response;
    
    NSError *error;
    
    if (httpUrlResponse.statusCode >= 400) {
        error = [NSError errorWithDomain:kErrorDomain
                                    code:2
                                userInfo:@{ NSLocalizedDescriptionKey:[NSString stringWithFormat:
                                                                       NSLocalizedString(@"HTTP error code %d (%@) ", @"HTTP error code {satus code} ({status code description})"),
                                                                       httpUrlResponse.statusCode,
                                                                       [NSHTTPURLResponse localizedStringForStatusCode:httpUrlResponse.statusCode]],
                                            HTTPErrorCode: @(httpUrlResponse.statusCode) }];
    }
    
    if ([[UIDevice currentDevice] freeDiskSpace].longLongValue < self.expectedDataLength && self.expectedDataLength != -1) {
        error = [NSError errorWithDomain:kErrorDomain
                                    code:3
                                userInfo:@{ NSLocalizedDescriptionKey:NSLocalizedString(@"Not enough free disk space", @"") }];
    }
    
    if (!error) {
        [self.receivedDataBuffer setData:nil];
        
        if (self.firstResponseBlock) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.firstResponseBlock(response);
            });
        }
        if ([self.delegate respondsToSelector:@selector(download:didReceiveFirstResponse:)]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate download:self didReceiveFirstResponse:response];
            });
        }
    }
    else {
        [self notifyFromError:error];
        [self cancelDownloadAndRemoveFile:NO];
    }
}

- (void)connection:(NSURLConnection*)connection didReceiveData:(NSData *)data
{
    [self.receivedDataBuffer appendData:data];
    self.receivedDataLength += [data length];

    TCLog(@"%@ | %.2f%% - Received: %ld - Total: %ld",
          self.fileName,
          (float) _receivedDataLength / self.expectedDataLength * 100
          (long)self.receivedDataLength, (long)self.expectedDataLength);
    
    if (self.receivedDataBuffer.length > kBufferSize && self.file) {
        [self.file writeData:self.receivedDataBuffer];
        [self.receivedDataBuffer setData:nil];
    }
    
    if (self.progressBlock) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.progressBlock(self.receivedDataLength, self.expectedDataLength, self.remainingTime);
        });
    }
    if ([self.delegate respondsToSelector:@selector(download:didReceiveData:onTotal:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate download:self
                     didReceiveData:self.receivedDataLength
                            onTotal:self.expectedDataLength];
        });
    }
}

- (void)connectionDidFinishLoading:(NSURLConnection*)connection
{
    [self.file writeData:self.receivedDataBuffer];
    [self.receivedDataBuffer setData:nil];
    
    [self notifyFromCompletionWithSuccess:YES pathToFile:self.pathToFile];
    
    [self finishOperation];
}


#pragma mark - Public Methods


- (void)cancelDownloadAndRemoveFile:(BOOL)remove
{
    [self finishOperation];
    
    NSFileManager *fm = [NSFileManager defaultManager];
    
    if (remove && [fm fileExistsAtPath:self.pathToFile]) {
        NSError *fileError;
        [fm removeItemAtPath:self.pathToFile error:&fileError];
        if (fileError) {
            TCLog(@"An error occured while removing file - %@", fileError);
            
            [self notifyFromError:fileError];
        }
    }
    
    NSString *pathToFile = remove ? nil : self.fileName;
    
    [self notifyFromCompletionWithSuccess:NO pathToFile:pathToFile];
}

- (void)addDependentDownload:(TCBlobDownloader *)blobDownload
{
    [self addDependency:blobDownload];
}


#pragma mark - Internal Methods


- (void)notifyFromError:(NSError *)error
{
    if (self.errorBlock) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.errorBlock(error);
        });
    }
    if ([self.delegate respondsToSelector:@selector(download:didStopWithError:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate download:self didStopWithError:error];
        });
    }
}

- (void)notifyFromCompletionWithSuccess:(BOOL)success pathToFile:(NSString *)pathToFile
{
    if (self.completionBlock) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.completionBlock(NO, nil);
        });
    }
    if ([self.delegate respondsToSelector:@selector(download:didFinishWithSucces:atPath:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate download:self didFinishWithSucces:NO atPath:nil];
        });
    }
}

- (void)updateTransferRate
{
    if (self.samplesOfDownloadedBytes.count > kNumberOfSamples) {
        [self.samplesOfDownloadedBytes removeObjectAtIndex:0];
    }
    
    static NSInteger totalReceived;
    [self.samplesOfDownloadedBytes addObject:[NSNumber numberWithLong:self.receivedDataLength - totalReceived]];
    totalReceived = self.receivedDataLength;
    // Compute the speed rate on the average of the last seconds samples
    self.speedRate = [[self.samplesOfDownloadedBytes valueForKeyPath:@"@avg.longValue"] longValue];
}

- (void)finishOperation
{
    [self willChangeValueForKey:@"isExecuting"];
    [self willChangeValueForKey:@"isFinished"];
    [self.speedTimer invalidate];
    [self.connection cancel];
    [self setConnection:nil];
    [self.file closeFile];
    [self didChangeValueForKey:@"isFinished"];
    [self didChangeValueForKey:@"isExecuting"];
}


#pragma mark - Custom Getters


- (NSString *)fileName
{
    return [[NSURL URLWithString:[self.downloadURL absoluteString]] lastPathComponent];
}

- (NSString *)pathToFile
{
    return [self.pathToDownloadDirectory stringByAppendingPathComponent:self.fileName];
}

- (NSInteger)remainingTime
{
    return self.speedRate > 0 ? (self.expectedDataLength - self.receivedDataLength) / self.speedRate : -1;
}

@end
