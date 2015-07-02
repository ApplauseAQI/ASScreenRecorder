//
//  UIViewController+ScreenRecorder.m
//  ExampleRecorder
//
//  Created by Alan Skipp on 23/04/2014.
//  Copyright (c) 2014 Alan Skipp. All rights reserved.
//

#import "UIViewController+ScreenRecorder.h"
#import "ASScreenRecorder.h"
#import <AudioToolbox/AudioToolbox.h>

@implementation UIViewController (ScreenRecorder)

- (void)prepareScreenRecorder;
{
    UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(recorderGesture:)];
    tapGesture.numberOfTapsRequired = 2;
    tapGesture.delaysTouchesBegan = YES;
    [self.view addGestureRecognizer:tapGesture];
    ASScreenRecorder *recorder = [ASScreenRecorder sharedInstance];
    recorder.saveToAssetsLibrary = YES;
}

- (void)recorderGesture:(UIGestureRecognizer *)recognizer
{
    ASScreenRecorder *recorder = [ASScreenRecorder sharedInstance];
    static UIBackgroundTaskIdentifier task;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        task = UIBackgroundTaskInvalid;
    });
    
    void(^endBackgroundTask)() = ^{
        if (task != UIBackgroundTaskInvalid) {
            [[UIApplication sharedApplication] endBackgroundTask:task];
            task = UIBackgroundTaskInvalid;
        }
    };
    
    if (recorder.isRecording) {
        [recorder stopRecordingWithCompletion:^{
            NSLog(@"Finished recording");
            [self playEndSound];
            endBackgroundTask();
        }];
    } else {
        [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
            [recorder stopRecordingWithCompletion:^{
                endBackgroundTask();
            }];
        }];
        [recorder startRecording];
        NSLog(@"Start recording");
        [self playStartSound];
    }
}

- (void)playStartSound
{
    NSURL *url = [NSURL URLWithString:@"/System/Library/Audio/UISounds/begin_record.caf"];
    SystemSoundID soundID;
    AudioServicesCreateSystemSoundID((__bridge CFURLRef)url, &soundID);
    AudioServicesPlaySystemSound(soundID);
}

- (void)playEndSound
{
    NSURL *url = [NSURL URLWithString:@"/System/Library/Audio/UISounds/end_record.caf"];
    SystemSoundID soundID;
    AudioServicesCreateSystemSoundID((__bridge CFURLRef)url, &soundID);
    AudioServicesPlaySystemSound(soundID);
}

@end
