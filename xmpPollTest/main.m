//
//  main.m
//  xmpPollTest
//
//  Simple libxmp playback test using the AUGraph API.
// 
//  Created by Douglas Carmichael on 1/2/15.
//  Copyright (c) 2015 Douglas Carmichael. All rights reserved.
//
//  Thanks to Mike Ash (mike@mikeash.com) for his help.

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import "TPCircularBuffer.h"
#import "xmp.h"

static OSStatus renderModuleCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags,
                                     const AudioTimeStamp *inTimeStamp,
                                     UInt32 inBusNumber,
                                     UInt32 inBufferFrames,
                                     AudioBufferList *ioData);

struct our_playback {
    TPCircularBuffer ourBuffer;
    int reached_end;
    int stopped_flag;
};

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        // insert code here...
        NSLog(@"Hello, World!");
        
        // Set up the AUGraph
        __block AUGraph myGraph;
        
        // Set up our status variables
        int status;
        __block xmp_context our_xmp_context;
        __block struct xmp_module_info ourModuleInfo;
        __block struct xmp_frame_info ourFrameInfo;
        struct our_playback ourXmpStruct;
        
        // Note: Have to take a pointer to our structure to make it work in a block.
        struct our_playback *ourXmpPointer = &ourXmpStruct;
        
        // Let's do it
        status = NewAUGraph(&myGraph);
        if (status != noErr)
        {
            NSLog(@"Cannot setup AUGraph.");
            return 0;
        }
        
        // Set up our default output component
        AudioComponentDescription defaultOutputDescription = {};
        defaultOutputDescription.componentType = kAudioUnitType_Output;
        defaultOutputDescription.componentSubType = kAudioUnitSubType_DefaultOutput;
        defaultOutputDescription.componentManufacturer = kAudioUnitManufacturer_Apple;
        defaultOutputDescription.componentFlags = 0;
        defaultOutputDescription.componentFlagsMask = 0;
        
        // Add that component as an output node to the graph
        AUNode outputNode;
        status = AUGraphAddNode(myGraph, &defaultOutputDescription, &outputNode);
        
        // Set up our mixer component (for volume control)
        AudioComponentDescription mixerDescription = {};
        mixerDescription.componentType = kAudioUnitType_Mixer;
        mixerDescription.componentSubType = kAudioUnitSubType_MultiChannelMixer;
        mixerDescription.componentManufacturer = kAudioUnitManufacturer_Apple;
        mixerDescription.componentFlags = 0;
        mixerDescription.componentFlagsMask = 0;
        
        // Add that component as a mixer node to the graph
        AUNode mixerNode;
        status = AUGraphAddNode(myGraph, &mixerDescription, &mixerNode);
        
        // Set up our converter component
        AudioComponentDescription converterDescription = {};
        converterDescription.componentType = kAudioUnitType_FormatConverter;
        converterDescription.componentSubType = kAudioUnitSubType_AUConverter;
        converterDescription.componentManufacturer = kAudioUnitManufacturer_Apple;
        converterDescription.componentFlags = 0;
        converterDescription.componentFlagsMask = 0;
        
        AUNode converterNode;
        status = AUGraphAddNode(myGraph, &converterDescription, &converterNode);
        
        // Connect the converter to the mixer node
        status = AUGraphConnectNodeInput(myGraph, converterNode, 0, mixerNode, 0);
        
        // Connect the mixer to the output node
        status = AUGraphConnectNodeInput(myGraph, mixerNode, 0, outputNode, 0);
        
        // Open the graph (NOTE: Must be done before other setup tasks!)
        status = AUGraphOpen(myGraph);
        
        // Grab the converter and mixer as audio units
        AudioUnit converterUnit, mixerUnit;
        status = AUGraphNodeInfo(myGraph, converterNode, NULL, &converterUnit);
        status = AUGraphNodeInfo(myGraph, mixerNode, NULL, &mixerUnit);
        
        // Set the mixer input bus count to one
        UInt32 numBuses = 1;
        status = AudioUnitSetProperty(mixerUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input,
                                      0, &numBuses, sizeof(numBuses));
        
        // Enable audio I/O on the multichannel mixer
        status = AudioUnitSetParameter(mixerUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, 0, 1, 0);
        status = AudioUnitSetParameter(mixerUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Output, 0, 1, 0);
        status = AudioUnitSetParameter(mixerUnit, kMultiChannelMixerParam_Enable, kAudioUnitScope_Global, 0, 1, 0);
        
        // Create our context
        our_xmp_context = xmp_create_context();
        
        // Load our module
        NSString *modulePath = @"/Users/dcarmich/wild_impressions.mod";
        
        if (xmp_load_module(our_xmp_context, (char *)[modulePath UTF8String]) != 0)
        {
            NSLog(@"Cannot load module!");
            return 0;
        }
        
        // grab the info/duration of the module
        xmp_get_module_info(our_xmp_context, &ourModuleInfo);
        NSString *moduleName = [[NSString alloc] initWithUTF8String:ourModuleInfo.mod->name];
        NSLog(@"Module name: %@", moduleName);
        
        // Add the render-notification callback to the graph
        AURenderCallbackStruct ourRenderCallback;
        ourRenderCallback.inputProc = &renderModuleCallback;
        ourRenderCallback.inputProcRefCon = &ourXmpStruct;
        status = AUGraphSetNodeInputCallback(myGraph, converterNode, 0, &ourRenderCallback);
        
        // Set our input format description
        AudioStreamBasicDescription streamFormat = {};
        streamFormat.mSampleRate = 44100;
        streamFormat.mFormatID = kAudioFormatLinearPCM;
        streamFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
        streamFormat.mChannelsPerFrame = 2;
        streamFormat.mFramesPerPacket = 1;
        streamFormat.mBitsPerChannel = 16;
        streamFormat.mBytesPerFrame = 4;
        streamFormat.mBytesPerPacket = 4;
        
        status = AudioUnitSetProperty(converterUnit,
                                      kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Input,
                                      0,
                                      &streamFormat,
                                      sizeof(streamFormat));
        
        // Calculate our buffer size based on sample rate/bytes per frame
        int ourBufferSize = streamFormat.mSampleRate * streamFormat.mBytesPerFrame;
        // Set up our circular buffer
        if(!TPCircularBufferInit(&ourXmpStruct.ourBuffer, ourBufferSize))
        {
            NSLog(@"Error: Cannot set up circular buffer.");
            return 0;
        }
        
        // Get our output unit information (that's in our GCD block to clean things up)
        __block AudioUnit outputUnit;
        status = AUGraphNodeInfo(myGraph, outputNode, 0, &outputUnit);
        
        // Initialize the graph
        status = AUGraphInitialize(myGraph);
        if (status != noErr)
        {
            NSLog(@"Cannot initialize graph.");
            NSLog(@"Error: %i", status);
            return 0;
        }
        
        // Start the AUGraph
        status = AUGraphStart(myGraph);
        
        // Start XMP playback
        status = xmp_start_player(our_xmp_context, streamFormat.mSampleRate, 0);
        
        CAShow(myGraph);
        NSLog(@"Starting playback loop.");
        
        // NOTE: Should we use dispatch_sync?
        dispatch_sync(dispatch_get_global_queue(0, 0), ^{
            do
            {
                do
                {
                    
                    xmp_get_frame_info(our_xmp_context, &ourFrameInfo);
                    if (ourFrameInfo.loop_count > 0)
                        break;
                    // Check for stopping and break if selected.
                    if (ourXmpPointer->stopped_flag)
                        break;
                    
                    // Declare some variables for us to use within the buffer loop
                    void *bufferDest;
                    int bufferAvailable;
                    
                    // Let's start putting the data out
                    do {
                        bufferDest = TPCircularBufferHead(&ourXmpPointer->ourBuffer, &bufferAvailable);
                        if(bufferAvailable < ourFrameInfo.buffer_size)
                        {
                            usleep(100000);
                        }
                        // Check for stopping and break if selected.
                        if (ourXmpPointer->stopped_flag)
                            break;
                    } while(bufferAvailable < ourFrameInfo.buffer_size);
                    
                    // Check for stopping (pause with an AUGraphStop() call.)
                    if (ourXmpPointer->stopped_flag)
                        break;
                    memcpy(bufferDest, ourFrameInfo.buffer, ourFrameInfo.buffer_size);
                    TPCircularBufferProduce(&ourXmpPointer->ourBuffer, ourFrameInfo.buffer_size);
                } while (xmp_play_frame(our_xmp_context) == 0);
            } while(!ourXmpPointer->reached_end);
        });
        
        
        NSLog(@"Cleaning up.");
        
        // Clean up
        xmp_end_player(our_xmp_context);
        xmp_release_module(our_xmp_context);
        xmp_free_context(our_xmp_context);
        AUGraphStop(myGraph);
        AUGraphClose(myGraph);
        TPCircularBufferCleanup(&ourXmpStruct.ourBuffer);
        AudioOutputUnitStop(outputUnit);
        AudioComponentInstanceDispose(outputUnit);
        AudioUnitUninitialize(outputUnit);
        
    }
    return 0;
}

static OSStatus renderModuleCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags,
                                     const AudioTimeStamp *inTimeStamp,
                                     UInt32 inBusNumber,
                                     UInt32 inBufferFrames,
                                     AudioBufferList *ioData)
{
    /* This code is taken from the Tasty Pixel example:
     http://atastypixel.com/blog/a-simple-fast-circular-buffer-implementation-for-audio-processing/ */
    
    struct our_playback *our_xmp_instance = inRefCon;
    
    int bytesAvailable = 0;
    
    /* Grab the data from the circular buffer into the temporary buffer */
    SInt16 *tempBuffer = TPCircularBufferTail(&our_xmp_instance->ourBuffer, &bytesAvailable);
    
    // Pass struct down here and if bytesAvailable == 0
    // Use a do/while to poll
    // Set reached_end == true if bytesAvailable == 0
    if (bytesAvailable == 0)
    {
        // Fill the buffer with zeroes to prevent pops/noise
        memset(ioData->mBuffers[0].mData, 0, ioData->mBuffers[0].mDataByteSize);
        our_xmp_instance->reached_end = true;
    }
    
    int toCopy = MIN(bytesAvailable, ioData->mBuffers[0].mDataByteSize);
    
    /* memcpy() the data to the audio output */
    memcpy(ioData->mBuffers[0].mData, tempBuffer, toCopy);
    
    /* Clear that section of the buffer */
    TPCircularBufferConsume(&our_xmp_instance->ourBuffer, toCopy);
    
    return noErr;
}

