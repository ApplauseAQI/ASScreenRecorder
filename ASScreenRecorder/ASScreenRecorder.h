//
//  ASScreenRecorder.h
//  ScreenRecorder
//
//  Created by Alan Skipp on 23/04/2014.
//  Copyright (c) 2014 Alan Skipp. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

typedef NS_ENUM(NSUInteger, ASSScreenRecorderVideoQuality) {
    ASSScreenRecorderVideoQualityVeryLow = 0,
    ASSScreenRecorderVideoQualityLow = 1,
    ASSScreenRecorderVideoQualityMedium = 2,
    ASSScreenRecorderVideoQualityHigh = 4,
    ASSScreenRecorderVideoQualityVeryHigh = 8,
};

typedef void (^VideoCompletionBlock)(void);

@protocol ASScreenRecorderDataSource;
@protocol ASScreenRecorderDelegate;

@interface ASScreenRecorder : NSObject

@property (nonatomic, readonly) BOOL isRecording;

@property (nonatomic) ASSScreenRecorderVideoQuality videoQuality;

@property (nonatomic, weak) id <ASScreenRecorderDelegate> delegate;
@property (nonatomic, weak) id <ASScreenRecorderDataSource> dataSource;

// this property can not be changed whilst recording is in progress
@property (strong, nonatomic) NSURL *videoURL;

// if saveToAssetsLibrary is YES, video will be saved into camera roll after recording is finished
@property(nonatomic) BOOL saveToAssetsLibrary;

@property(nonatomic, strong) UIApplication *application;
@property(nonatomic, strong) UIScreen *screen;
@property(nonatomic, strong) NSFileManager *fileManager;
@property(nonatomic, strong) UIDevice *device;
@property(nonatomic, strong) NSRunLoop *runLoop;

+ (instancetype)sharedInstance;
- (BOOL)startRecording;
- (BOOL)startRecordingWithQuality:(ASSScreenRecorderVideoQuality)quality;
- (void)stopRecordingWithCompletion:(VideoCompletionBlock)completionBlock;
- (void)storeVideoInAssetsLibraryWithCompletion:(void(^)())completion;
- (void)removeVideoFile;
@end


// If your view contains an AVCaptureVideoPreviewLayer or an openGL view
// you'll need to write that data into the CGContextRef yourself.
// In the viewcontroller responsible for the AVCaptureVideoPreviewLayer / openGL view
// set yourself as the dataSource for ASScreenRecorder.
// [ASScreenRecorder sharedInstance].dataSource = self
// Then implement 'screenRecorder:requestToDrawInContext:'
// use 'CGContextDrawImage' to draw your view into the provided CGContextRef
@protocol ASScreenRecorderDataSource <NSObject>
- (void)screenRecorder:(ASScreenRecorder *)screenRecorder requestToDrawInContext:(CGContextRef*)contextRef;
- (NSString *)screenRecorderTextForBackgroundFrame:(ASScreenRecorder *)screenRecorder;
@end

@protocol ASScreenRecorderDelegate <NSObject>
- (void)screenRecorder:(ASScreenRecorder *)screenRecorder didFailToWriteBufferToVideoWriter:(AVAssetWriter *)assetWriter withError:(NSError *)error;
- (void)screenRecorder:(ASScreenRecorder *)screenRecorder didFailToRemoveFileAtPath:(NSURL *)videoFilePath withError:(NSError *)error;
- (void)screenRecorder:(ASScreenRecorder *)screenRecorder didFailToSaveVideoToCameraRoll:(NSURL *)videoFilePath withError:(NSError *)error;
@end
