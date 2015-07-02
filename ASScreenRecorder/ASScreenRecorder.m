//
//  ASScreenRecorder.m
//  ScreenRecorder
//
//  Created by Alan Skipp on 23/04/2014.
//  Copyright (c) 2014 Alan Skipp. All rights reserved.
//

#import "ASScreenRecorder.h"
#import <AVFoundation/AVFoundation.h>
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
    if (!_isRecording) {
        [self setUpWriter];
        _isRecording = (_videoWriter.status == AVAssetWriterStatusWriting);
        _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(writeVideoFrame)];
        [_displayLink addToRunLoop:self.runLoop forMode:NSRunLoopCommonModes];
    }
    return _isRecording;
}

- (BOOL)startRecordingWithQuality:(ASSScreenRecorderVideoQuality)quality {
    self.videoQuality = quality;
    return [self startRecording];
}

- (void)stopRecordingWithCompletion:(VideoCompletionBlock)completionBlock;
{
    if (_isRecording) {
        _isRecording = NO;
        [_displayLink removeFromRunLoop:self.runLoop forMode:NSRunLoopCommonModes];
        [self completeRecordingSession:completionBlock];
    }
}

#pragma mark - private

-(void)setUpWriter
{
    _rgbColorSpace = CGColorSpaceCreateDeviceRGB();
    
    NSDictionary *bufferAttributes = @{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
                                       (id)kCVPixelBufferCGBitmapContextCompatibilityKey : @YES,
                                       (id)kCVPixelBufferWidthKey : @(self.bufferSize.width),
                                       (id)kCVPixelBufferHeightKey : @(self.bufferSize.height),
                                       (id)kCVPixelBufferBytesPerRowAlignmentKey : @(self.bufferSize.width * 4)
                                       };
    
    _outputBufferPool = NULL;
    CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)(bufferAttributes), &_outputBufferPool);
    
    
    NSError* error = nil;
    NSURL *fileURL = self.videoURL ?: [self tempFileURL];
    _videoWriter = [[AVAssetWriter alloc] initWithURL:fileURL
                                             fileType:AVFileTypeQuickTimeMovie
                                                error:&error];
    NSParameterAssert(_videoWriter);
    error = nil;
    NSDictionary *fileProtectionAttribute = @{
        NSFileProtectionKey: NSFileProtectionNone,
    };
    [self.fileManager setAttributes:fileProtectionAttribute ofItemAtPath:fileURL.path error:&error];
    
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
    NSDictionary* videoCompression = @{
                                       AVVideoAverageBitRateKey: @(pixelNumber * videoQualityBitrateFactor),
                                       AVVideoMaxKeyFrameIntervalKey: @(300),
                                       AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel,
                                       AVVideoExpectedSourceFrameRateKey: @(30),
                                       AVVideoAverageNonDroppableFrameRateKey: @(30),
                                       };
    
    NSDictionary* videoSettings = @{
                                    AVVideoCodecKey: AVVideoCodecH264,
                                    AVVideoWidthKey: @(self.bufferSize.width),
                                    AVVideoHeightKey: @(self.bufferSize.height),
                                    AVVideoCompressionPropertiesKey: videoCompression,
                                    };
    
    _videoWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
    NSParameterAssert(_videoWriterInput);
    
    _videoWriterInput.expectsMediaDataInRealTime = YES;
    _videoWriterInput.transform = [self videoTransformForDeviceOrientation];
    
    _avAdaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:_videoWriterInput sourcePixelBufferAttributes:nil];
    
    [_videoWriter addInput:_videoWriterInput];
    
    [_videoWriter startWriting];
    [_videoWriter startSessionAtSourceTime:CMTimeMake(0, 1000)];
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

- (NSURL*)tempFileURL
{
    NSString *outputPath = [NSHomeDirectory() stringByAppendingPathComponent:@"tmp/screenCapture.mp4"];
    [self removeTempFilePath:outputPath];
    return [NSURL fileURLWithPath:outputPath];
}

- (void)removeVideoFile {
    [self removeTempFilePath:_videoWriter.outputURL.path];
    self.videoURL = nil;
}

- (void)removeTempFilePath:(NSString*)filePath
{
    if ([self.fileManager fileExistsAtPath:filePath]) {
        NSError* error;
        if ([self.fileManager removeItemAtPath:filePath error:&error] == NO) {
            NSLog(@"Could not delete old recording:%@", [error localizedDescription]);
        }
    }
}

- (void)completeRecordingSession:(VideoCompletionBlock)completionBlock;
{
    dispatch_async(_render_queue, ^{
        dispatch_sync(_append_pixelBuffer_queue, ^{
            
            [_videoWriterInput markAsFinished];
            [_videoWriter finishWritingWithCompletionHandler:^{
                
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
    [library writeVideoAtPathToSavedPhotosAlbum:_videoWriter.outputURL completionBlock:^(NSURL *assetURL, NSError *error) {
        if (error) {
            NSLog(@"Error copying video to camera roll:%@", [error localizedDescription]);
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
    CGColorSpaceRelease(_rgbColorSpace);
    CVPixelBufferPoolRelease(_outputBufferPool);
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
        if (self.delegate) {
            [self.delegate writeBackgroundFrameInContext:&bitmapContext];
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
            for (UIWindow *window in [self.application windows]) {
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

- (UILabel *)prepareBackgroundLabel {
    CGRect labelRect = self.application.delegate.window.bounds;
    UILabel *backgroundLabel = [[UILabel alloc] initWithFrame:labelRect];
    backgroundLabel.backgroundColor = [UIColor blackColor];
    backgroundLabel.textColor = [UIColor whiteColor];
    backgroundLabel.textAlignment = NSTextAlignmentCenter;
    backgroundLabel.numberOfLines = 0;
    backgroundLabel.text = @"Application did enter background";
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
    if (!success) {
        NSLog(@"Warning: Unable to write buffer to video");
    }
}

- (void)cleanupBitmapContext:(CGContextRef)bitmapContext andPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    CGContextRelease(bitmapContext);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    CVPixelBufferRelease(pixelBuffer);
}

@end
