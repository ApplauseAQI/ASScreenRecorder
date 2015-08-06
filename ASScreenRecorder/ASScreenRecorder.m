//
//  ASScreenRecorder.m
//  ScreenRecorder
//
//  Created by Alan Skipp on 23/04/2014.
//  Copyright (c) 2014 Alan Skipp. All rights reserved.
//

#import "ASScreenRecorder.h"
#import <QuartzCore/QuartzCore.h>
#import <AssetsLibrary/AssetsLibrary.h>

@interface ASScreenRecorder()

@property(strong, nonatomic) AVAssetWriter *videoWriter;
@property(strong, nonatomic) AVAssetWriterInput *videoWriterInput;
@property(strong, nonatomic) AVAssetWriterInputPixelBufferAdaptor *avAdaptor;
@property(strong, nonatomic) CADisplayLink *displayLink;
@property(strong, nonatomic) NSDictionary *outputBufferPoolAuxAttributes;
@property(nonatomic) CFTimeInterval firstTimeStamp;
@property(nonatomic, readwrite) BOOL isRecording;
@property(nonatomic) CGSize bufferSize;
@property(nonatomic) dispatch_queue_t render_queue;
@property(nonatomic) dispatch_queue_t append_pixelBuffer_queue;
@property(nonatomic) dispatch_semaphore_t frameRenderingSemaphore;
@property(nonatomic) dispatch_semaphore_t pixelAppendSemaphore;
@property(nonatomic) CGColorSpaceRef rgbColorSpace;
@property(nonatomic) CVPixelBufferPoolRef outputBufferPool;

@end

@implementation ASScreenRecorder

#pragma mark - initializers

+ (instancetype)sharedInstance {
    static dispatch_once_t once;
    static ASScreenRecorder *sharedInstance;
    dispatch_once(&once, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _videoQuality = ASSScreenRecorderVideoQualityMedium;
        
        _application = [UIApplication sharedApplication];
        _screen = [UIScreen mainScreen];
        _fileManager = [NSFileManager defaultManager];
        _device = [UIDevice currentDevice];
        _runLoop = [NSRunLoop mainRunLoop];
        
        CGSize viewSize = self.application.delegate.window.bounds.size;
        CGFloat scale = self.screen.scale;
        _bufferSize = CGSizeMake(viewSize.width * scale, viewSize.height * scale);
        _isRecording = NO;
        
        _append_pixelBuffer_queue = dispatch_queue_create("ASScreenRecorder.append_queue", DISPATCH_QUEUE_SERIAL);
        _render_queue = dispatch_queue_create("ASScreenRecorder.render_queue", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_render_queue, dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_HIGH, 0));
        _frameRenderingSemaphore = dispatch_semaphore_create(1);
        _pixelAppendSemaphore = dispatch_semaphore_create(1);
    }
    return self;
}

#pragma mark - public

- (void)setVideoURL:(NSURL *)videoURL
{
    NSAssert(!_isRecording, @"videoURL can not be changed whilst recording is in progress");
    _videoURL = videoURL;
}

- (BOOL)startRecording
{
    if (!self.isRecording) {
        [self setUpWriter];
        self.isRecording = (self.videoWriter.status == AVAssetWriterStatusWriting);
        self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(writeVideoFrame)];
        [self.displayLink addToRunLoop:self.runLoop forMode:NSRunLoopCommonModes];
    }
    return self.isRecording;
}

- (BOOL)startRecordingWithQuality:(ASSScreenRecorderVideoQuality)quality {
    self.videoQuality = quality;
    return [self startRecording];
}

- (void)stopRecordingWithCompletion:(VideoCompletionBlock)completionBlock;
{
    if (self.isRecording) {
        self.isRecording = NO;
        [self.displayLink removeFromRunLoop:self.runLoop forMode:NSRunLoopCommonModes];
        [self completeRecordingSession:completionBlock];
    }
}

#pragma mark - private

-(void)setUpWriter
{
    self.rgbColorSpace = CGColorSpaceCreateDeviceRGB();
    
    [self createPixelBufferPool];
    [self prepareAssetsWriter];
    [self createVideoWrighterInput];
    
    self.avAdaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:self.videoWriterInput sourcePixelBufferAttributes:nil];
    
    [self.videoWriter addInput:self.videoWriterInput];
    
    [self.videoWriter startWriting];
    [self.videoWriter startSessionAtSourceTime:CMTimeMake(0, 1000)];
}

- (void)createPixelBufferPool {
    NSDictionary *bufferAttributes = @{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
                                       (id)kCVPixelBufferCGBitmapContextCompatibilityKey : @YES,
                                       (id)kCVPixelBufferWidthKey : @(self.bufferSize.width),
                                       (id)kCVPixelBufferHeightKey : @(self.bufferSize.height),
                                       (id)kCVPixelBufferBytesPerRowAlignmentKey : @(self.bufferSize.width * 4)
                                       };
    
    self.outputBufferPool = NULL;
    CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)(bufferAttributes), &_outputBufferPool);
}

- (void)prepareAssetsWriter {
    NSError* error = nil;
    NSURL *fileURL = self.videoURL ?: [self tempFileURL];
    self.videoWriter = [[AVAssetWriter alloc] initWithURL:fileURL
                                                 fileType:AVFileTypeQuickTimeMovie
                                                    error:&error];
    NSParameterAssert(self.videoWriter);
    [self removeProtectionFromFile:fileURL];
}

- (void)removeProtectionFromFile:(NSURL *)fileURL {
    NSError *error = nil;
    NSDictionary *fileProtectionAttribute = @{
        NSFileProtectionKey: NSFileProtectionNone,
    };
    [self.fileManager setAttributes:fileProtectionAttribute ofItemAtPath:fileURL.path error:&error];
}

- (void)createVideoWrighterInput {
    self.videoWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:[self videoSettings]];
    NSParameterAssert(self.videoWriterInput);
    
    self.videoWriterInput.expectsMediaDataInRealTime = YES;
    if ([[[UIDevice currentDevice] systemVersion] floatValue] < 8.0) {
        self.videoWriterInput.transform = [self videoTransformForDeviceOrientation];
    }
}

- (NSDictionary *)videoSettings {
    static NSDictionary* videoSettings;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CGFloat videoQualityBitrateFactor;
        switch (self.videoQuality) {
            case ASSScreenRecorderVideoQualityVeryLow: {
                videoQualityBitrateFactor = 0.5;
                break;
            }
            default: {
                videoQualityBitrateFactor = (CGFloat)self.videoQuality;
                break;
            }
        }
        NSInteger pixelNumber = self.bufferSize.width * self.bufferSize.height;
        NSDictionary *videoCompression = @{
            AVVideoAverageBitRateKey: @(pixelNumber * videoQualityBitrateFactor),
            AVVideoMaxKeyFrameIntervalKey: @(300),
            AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel,
            AVVideoExpectedSourceFrameRateKey: @(30),
#if !(TARGET_IPHONE_SIMULATOR)
            AVVideoAverageNonDroppableFrameRateKey: @(30),
#endif
        };
        
        videoSettings = @{
            AVVideoCodecKey: AVVideoCodecH264,
            AVVideoWidthKey: @(self.bufferSize.width),
            AVVideoHeightKey: @(self.bufferSize.height),
            AVVideoCompressionPropertiesKey: videoCompression,
        };
    });
    return videoSettings;
}

- (CGAffineTransform)videoTransformForDeviceOrientation
{
    CGAffineTransform videoTransform;
    switch (self.device.orientation) {
        case UIDeviceOrientationLandscapeLeft:
            videoTransform = CGAffineTransformMakeRotation(-M_PI_2);
            break;
        case UIDeviceOrientationLandscapeRight:
            videoTransform = CGAffineTransformMakeRotation(M_PI_2);
            break;
        case UIDeviceOrientationPortraitUpsideDown:
            videoTransform = CGAffineTransformMakeRotation(M_PI);
            break;
        default:
            videoTransform = CGAffineTransformIdentity;
    }
    return videoTransform;
}

- (NSURL *)tempFileURL
{
    NSURL *outputURL = [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"tmp/screenCapture.mp4"]];
    [self removeTempFilePath:outputURL];
    return outputURL;
}

- (void)removeVideoFile {
    [self removeTempFilePath:self.videoWriter.outputURL];
    self.videoURL = nil;
}

- (void)removeTempFilePath:(NSURL *)fileURL
{
    NSString *filePath = fileURL.path;
    if ([self.fileManager fileExistsAtPath:filePath]) {
        NSError* error;
        if ([self.fileManager removeItemAtPath:filePath error:&error] == NO &&
            [self.delegate respondsToSelector:@selector(screenRecorder:didFailToRemoveFileAtPath:withError:)]) {
            [self.delegate screenRecorder:self didFailToRemoveFileAtPath:fileURL withError:error];
        }
    }
}

- (void)completeRecordingSession:(VideoCompletionBlock)completionBlock;
{
    dispatch_async(self.render_queue, ^{
        dispatch_sync(self.append_pixelBuffer_queue, ^{
            
            [self.videoWriterInput markAsFinished];
            [self.videoWriter finishWritingWithCompletionHandler:^{
                
                void (^completion)(void) = ^() {
                    [self cleanup];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (completionBlock) completionBlock();
                    });
                };
                
                if (!self.saveToAssetsLibrary) {
                    completion();
                } else {
                    [self storeVideoInAssetsLibraryWithCompletion:completion];
                }
            }];
        });
    });
}

- (void)storeVideoInAssetsLibraryWithCompletion:(void(^)())completion {
    ALAssetsLibrary *library = [[ALAssetsLibrary alloc] init];
    [library writeVideoAtPathToSavedPhotosAlbum:self.videoWriter.outputURL completionBlock:^(NSURL *assetURL, NSError *error) {
        if (error && [self.delegate respondsToSelector:@selector(screenRecorder:didFailToSaveVideoToCameraRoll:withError:)]) {
            [self.delegate screenRecorder:self didFailToSaveVideoToCameraRoll:self.videoWriter.outputURL withError:error];
        } else {
            if (completion) {
                completion();
            }
        }
    }];
}

- (void)cleanup
{
    self.avAdaptor = nil;
    self.videoWriterInput = nil;
    self.videoWriter = nil;
    self.firstTimeStamp = 0;
    self.outputBufferPoolAuxAttributes = nil;
    CGColorSpaceRelease(self.rgbColorSpace);
    CVPixelBufferPoolRelease(self.outputBufferPool);
}

#pragma mark - Recording

- (void)writeVideoFrame
{
    // throttle the number of frames to prevent meltdown
    // technique gleaned from Brad Larson's answer here: http://stackoverflow.com/a/5956119
    if (dispatch_semaphore_wait(self.frameRenderingSemaphore, DISPATCH_TIME_NOW) != 0) {
        return;
    }
    
    dispatch_async(self.render_queue, ^{
        if (![self.videoWriterInput isReadyForMoreMediaData]) {
            return;
        }
        
        CMTime time = [self currentFrameTime];
        
        CVPixelBufferRef pixelBuffer = NULL;
        CGContextRef bitmapContext = [self createPixelBufferAndBitmapContext:&pixelBuffer];
        
        [self drawInBitmapContext:bitmapContext];
        
        // append pixelBuffer on a async dispatch_queue, the next frame is rendered whilst this one appends
        // must not overwhelm the queue with pixelBuffers, therefore:
        // check if _append_pixelBuffer_queue is ready
        // if it’s not ready, release pixelBuffer and bitmapContext
        if (dispatch_semaphore_wait(self.pixelAppendSemaphore, DISPATCH_TIME_NOW) == 0 && pixelBuffer != NULL) {
            dispatch_async(self.append_pixelBuffer_queue, ^{
                [self handlePixelBuffer:pixelBuffer withPresentationTime:time];
                [self cleanupBitmapContext:bitmapContext andPixelBuffer:pixelBuffer];
                dispatch_semaphore_signal(self.pixelAppendSemaphore);
            });
        } else {
            [self cleanupBitmapContext:bitmapContext andPixelBuffer:pixelBuffer];
        }
        
        
        dispatch_semaphore_signal(_frameRenderingSemaphore);
    });
}

#pragma mark - Recording helpers

- (CMTime)currentFrameTime {
    if (!self.firstTimeStamp) {
        self.firstTimeStamp = self.displayLink.timestamp;
    }
    CFTimeInterval elapsed = (self.displayLink.timestamp - self.firstTimeStamp);
    return CMTimeMakeWithSeconds(elapsed, 1000);
}

- (CGContextRef)createPixelBufferAndBitmapContext:(CVPixelBufferRef *)pixelBuffer
{
    CVPixelBufferPoolCreatePixelBuffer(NULL, self.outputBufferPool, pixelBuffer);
    CVPixelBufferLockBaseAddress(*pixelBuffer, 0);
    
    CGContextRef bitmapContext = NULL;
    bitmapContext = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(*pixelBuffer),
                                          CVPixelBufferGetWidth(*pixelBuffer),
                                          CVPixelBufferGetHeight(*pixelBuffer),
                                          8, CVPixelBufferGetBytesPerRow(*pixelBuffer), self.rgbColorSpace,
                                          kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst
                                          );
    CGFloat scale = self.screen.scale;
    CGSize viewSize = self.application.delegate.window.bounds.size;
    CGContextScaleCTM(bitmapContext, scale, scale);
    CGAffineTransform flipVertical = CGAffineTransformMake(1, 0, 0, -1, 0, viewSize.height);
    CGContextConcatCTM(bitmapContext, flipVertical);
    
    return bitmapContext;
}

- (void)drawInBitmapContext:(CGContextRef)bitmapContext {
    if (self.application.applicationState == UIApplicationStateActive) {
		if ([self.dataSource respondsToSelector:@selector(screenRecorder:requestToDrawInContext:)]) {
            [self.dataSource screenRecorder:self requestToDrawInContext:&bitmapContext];
        }
        [self drawCurrentScreenInBitmapContext:bitmapContext];
    } else {
        [self drawBackgroundLayerInBitmapContext:bitmapContext];
    }
}

- (void)drawCurrentScreenInBitmapContext:(CGContextRef)bitmapContext {
    // draw each window into the context (other windows include UIKeyboard, UIAlert)
    // FIX: UIKeyboard is currently only rendered correctly in portrait orientation
    dispatch_sync(dispatch_get_main_queue(), ^{
        UIGraphicsPushContext(bitmapContext); {
            for (UIWindow *window in [self windowsToRender]) {
                if ([window isHidden]) {
                    continue;
                }
                if ([window respondsToSelector:@selector(drawViewHierarchyInRect:afterScreenUpdates:)]) {
                    [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:NO];
                } else {
                    CALayer *rootLayer = window.rootViewController.view.layer;
                    [rootLayer renderInContext:bitmapContext];
                }
            }
        } UIGraphicsPopContext();
    });
}

- (NSArray *)windowsToRender {
    return [self appendKeyWindowIfNeeded:[self.application windows]];
}

- (NSArray *)appendKeyWindowIfNeeded:(NSArray *)visibleWindows {
    UIWindow *keyWindow = [self.application keyWindow];
    if (keyWindow != nil && ![visibleWindows containsObject:keyWindow]) {
        NSMutableArray *tempWindowsArray = [NSMutableArray arrayWithArray:visibleWindows];
        [tempWindowsArray addObject:keyWindow];
        visibleWindows = tempWindowsArray;
    }
    return visibleWindows;
}

- (UILabel *)prepareBackgroundLabel {
    CGRect labelRect = self.application.delegate.window.bounds;
    UILabel *backgroundLabel = [[UILabel alloc] initWithFrame:labelRect];
    backgroundLabel.backgroundColor = [UIColor blackColor];
    backgroundLabel.textColor = [UIColor whiteColor];
    backgroundLabel.textAlignment = NSTextAlignmentCenter;
    backgroundLabel.numberOfLines = 0;
    
    NSString *labelText;
    if ([self.dataSource respondsToSelector:@selector(screenRecorderTextForBackgroundFrame:)]) {
        labelText = [self.dataSource screenRecorderTextForBackgroundFrame:self];
    }
    if (labelText == nil) {
        labelText = @"Application did enter background";
    }
    
    backgroundLabel.text = labelText;
    return backgroundLabel;
}

- (void)drawBackgroundLayerInBitmapContext:(CGContextRef)bitmapContext {
    static UILabel *backgroundLabel;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        backgroundLabel = [self prepareBackgroundLabel];
    });
    [backgroundLabel.layer renderInContext:bitmapContext];
}

- (void)handlePixelBuffer:(CVPixelBufferRef)pixelBuffer withPresentationTime:(CMTime)time {
    BOOL success = [self.avAdaptor appendPixelBuffer:pixelBuffer withPresentationTime:time];
	if (!success && [self.delegate respondsToSelector:@selector(screenRecorder:didFailToWriteBufferToVideoWriter:withError:)]) {
		[self.delegate screenRecorder:self didFailToWriteBufferToVideoWriter:self.videoWriter withError:self.videoWriter.error];
	}
}

- (void)cleanupBitmapContext:(CGContextRef)bitmapContext andPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    CGContextRelease(bitmapContext);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    CVPixelBufferRelease(pixelBuffer);
}

@end
