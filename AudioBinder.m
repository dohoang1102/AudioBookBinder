//
//  Copyright (c) 2009, Oleksandr Tymoshenko <gonzo@bluezbox.com>
//  All rights reserved.
// 
//  Redistribution and use in source and binary forms, with or without
//  modification, are permitted provided that the following conditions
//  are met:
//  1. Redistributions of source code must retain the above copyright
//     notice unmodified, this list of conditions, and the following
//     disclaimer.
//  2. Redistributions in binary form must reproduce the above copyright
//     notice, this list of conditions and the following disclaimer in the
//     documentation and/or other materials provided with the distribution.
// 
//  THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
//  ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
//  IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
//  ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
//  FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
//  DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
//  OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
//  HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
//  LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
//  OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
//  SUCH DAMAGE.
//

#import <AudioToolbox/AudioConverter.h>
#import "AudioBinder.h"

#include "ABLog.h"

// 1M seems to be sane buffer size nowadays
#define AUDIO_BUFFER_SIZE 1*1024*1024
#define DEFAULT_SAMPLE_RATE 44100.f

// Helper function
static NSString * 
stringForOSStatus(OSStatus err)
{
    // TODO: add proper description
    NSString * descString;
    BOOL isOSType = YES;
    char osTypeRepr[5];
    
    // Check if err is OSType and convert it to 4 chars representation
    osTypeRepr[4] = 0;
    for (int i = 0; i < 4; i++)
    {
        unsigned char c = (err >> 8*i) & 0xff;
        if (isprint(c))
            osTypeRepr[3-i] = c;
        else
        {
            isOSType = NO;
            break;
        }
    }

    descString = [[NSString alloc] 
        initWithFormat:@"err#%08x (%s)", err, 
                  isOSType ? osTypeRepr : GetMacOSStatusCommentString(err)];
    [descString autorelease];
    
    return descString;
}

@implementation AudioBinder

-(id)init
{
    [super init];
    
    _inFiles = [[NSMutableArray alloc] init];
    _outFileName = nil;
    _outAudioFile = nil;
    _outFileLength = 0;
    return self;
}

-(void)setDelegate: (id<AudioBinderDelegate>)delegate
{
    _delegate = delegate;
}

-(void)addInputFile: (NSString*)fileName
{
    [_inFiles addObject: fileName];
}

-(void)setOutputFile: (NSString*)outFileName
{
    [_outFileName release];
    _outFileName = [[NSString alloc] initWithString:outFileName];
}

-(BOOL)convert
{
    BOOL failed = NO;
    NSFileManager *fm;
    int filesConverted = 0;
    
    if ([_inFiles count] == 0)
    {
        ABLog(@"No input file");
        return NO;
    }
    
    if ([self openOutFile] == NO)
    {
        ABLog(@"Failed to open output file");
        return NO;
    }
    
    for (NSString* inFile in _inFiles) 
    {
        NSString *reason;
        if ([self convertOneFile:inFile reason:&reason] == NO)
        {
            // We failed 
            if (![_delegate continueFailedConversion:inFile reason:reason])
            {
                failed = YES;
                break;
            }
        }
        else
            filesConverted++;
    }
    
    [self closeOutFile];
    if (failed)
    {
        fm = [NSFileManager defaultManager];
        [fm removeFileAtPath:_outFileName handler:nil];
    }
        
    // Did we fail? Were there any files successfully converted? 
    if (failed || (filesConverted == 0))
        return NO;
    
    
    [_delegate audiobookReady:_outFileName 
                     duration:(UInt32)(_outFileLength/DEFAULT_SAMPLE_RATE)];
    return YES;
}

-(BOOL)openOutFile
{
    FSRef dirFSRef;
    OSStatus status;
    NSString *parentDir;
    AudioStreamBasicDescription outputFormat;
    
    // open out file
    parentDir = [_outFileName stringByDeletingLastPathComponent];
    if ([parentDir isEqualToString:@""]) {
        status = FSPathMakeRef((UInt8 *)
                               [@"." UTF8String], &dirFSRef, NULL);
    } else {
        status = FSPathMakeRef((UInt8 *)
                               [parentDir UTF8String], 
                               &dirFSRef, NULL);
    }
    if (status != noErr)
    {
        ABLog(@"FSPathMakeRef failed for %@: %@", 
              _outFileName, stringForOSStatus(status));        
        return NO;
    }
    
    if([[NSFileManager defaultManager] fileExistsAtPath:_outFileName]) 
    {
        if (![[NSFileManager defaultManager] removeFileAtPath:_outFileName 
                                                      handler:nil])
        {
            ABLog(@"Failed to remove file %@", _outFileName);
            return NO;
        }
    }    
    
    memset(&outputFormat, 0, sizeof(AudioStreamBasicDescription));
    outputFormat.mSampleRate = DEFAULT_SAMPLE_RATE;
    outputFormat.mFormatID = kAudioFormatMPEG4AAC;
    outputFormat.mChannelsPerFrame = 2;
   
    status = ExtAudioFileCreateNew(&dirFSRef, 
                                   (CFStringRef)[_outFileName lastPathComponent], 
                                   kAudioFileM4AType, &outputFormat, 
                                   NULL, &_outAudioFile);
    
    if (status != noErr)
    {
        ABLog(@"Failed to create output file %@: %@", 
              _outFileName, stringForOSStatus(status));
        return NO;
    }

    return YES;
}

-(void)closeOutFile
{
    if (_outAudioFile != nil)
        ExtAudioFileDispose(_outAudioFile);
    _outAudioFile = nil;
}

-(BOOL) convertOneFile: (NSString *)inFileName reason: (NSString**)reason
{
    // Get description
    NSString *fileFormat;
    UInt32 specSize;
    OSStatus status;
    FSRef ref;
    Boolean isDirectory;
    ExtAudioFileRef inAudioFile = nil;
    AudioStreamBasicDescription format;    
    AudioStreamBasicDescription pcmFormat;      
    UInt32 size;
    AudioConverterRef conv = NULL;
    UInt64 framesTotal = 0, framesConverted = 0;
    UInt32 framesToRead = 0;
    AudioBufferList bufferList;
    void *audioBuffer = NULL;
        
    @try {
        // open audio file
        status = FSPathMakeRef(
                               (const UInt8 *)[inFileName fileSystemRepresentation], 
                               &ref, &isDirectory);
        if (status != noErr)
            [NSException raise:@"ConvertExcetion" 
                format:@"Failed to make reference for file %@: %@", 
                inFileName, stringForOSStatus(status)];
        
        if (isDirectory)
            [NSException raise:@"ConvertExcetion" 
                format:@"Error: %@ is directory", inFileName];
        
        status = ExtAudioFileOpen(&ref, &inAudioFile);
        if (status != noErr)
            [NSException raise:@"ConvertExcetion" 
                format:@"ExtAudioFileWrapAudioFileID failed: %@", 
                stringForOSStatus(status)];
        
        // Query file type
        size = sizeof(AudioStreamBasicDescription);
        status = ExtAudioFileGetProperty(inAudioFile, 
                                         kExtAudioFileProperty_FileDataFormat,
                                         &size, &format);
        if(status != noErr)
            [NSException raise:@"ConvertExcetion" 
                format:@"AudioFileGetProperty failed: %@", 
             stringForOSStatus(status)];
        
        size = sizeof(framesTotal);
        status = ExtAudioFileGetProperty(inAudioFile, 
                                         kExtAudioFileProperty_FileLengthFrames,
                                         &size, &framesTotal);
        if(status != noErr)
            [NSException raise:@"ConvertExcetion" 
                        format:@"failed to get input file length: %@", 
                        stringForOSStatus(status)];        
  
        
        specSize = sizeof(fileFormat);
        size = sizeof(AudioStreamBasicDescription);
        status = AudioFormatGetProperty(kAudioFormatProperty_FormatName, 
                                        size, &format, &specSize, &fileFormat);
        
        if(status != noErr) 
            [NSException raise:@"ConvertExcetion" 
                format:@"AudioFormatGetProperty failed: %@", 
                stringForOSStatus(status)];        
        
        size = sizeof(framesTotal);
        status = ExtAudioFileGetProperty(inAudioFile, 
                                         kExtAudioFileProperty_FileLengthFrames,
                                         &size, &framesTotal);
        
        if(status != noErr)
            [NSException raise:@"ConvertExcetion" 
                format:@"ExtAudioFileGetProperty failed: %@", 
                stringForOSStatus(status)];

        
        [_delegate conversionStart: inFileName 
                            format: &format
                 formatDescription: fileFormat
                            length: framesTotal];
        
        // Setup input format descriptor, preserve mSampleRate
        bzero(&pcmFormat, sizeof(pcmFormat));
        pcmFormat.mSampleRate = format.mSampleRate;
        pcmFormat.mFormatID = kAudioFormatLinearPCM;
        pcmFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger 
            | kAudioFormatFlagIsBigEndian 
            | kAudioFormatFlagIsPacked;

        pcmFormat.mBitsPerChannel = 16;
        pcmFormat.mChannelsPerFrame = 2;
        pcmFormat.mFramesPerPacket = 1;
        pcmFormat.mBytesPerPacket = 
            (pcmFormat.mBitsPerChannel / 8) * pcmFormat.mChannelsPerFrame;
        pcmFormat.mBytesPerFrame = 
            pcmFormat.mBytesPerPacket * pcmFormat.mFramesPerPacket;

        status = ExtAudioFileSetProperty(inAudioFile, 
                                         kExtAudioFileProperty_ClientDataFormat, 
                                         sizeof(pcmFormat), &pcmFormat);
        if(status != noErr)
            [NSException raise:@"ConvertExcetion" 
                format:@"ExtAudioFileSetProperty(ClientDataFormat) failed: %@", 
                stringForOSStatus(status)];

        // Get the underlying AudioConverterRef
        size = sizeof(AudioConverterRef);

        status = ExtAudioFileGetProperty(inAudioFile, 
                                         kExtAudioFileProperty_AudioConverter, 
                                         &size, &conv);
        if(status != noErr)
            [NSException raise:@"ConvertExcetion" 
                        format:@"failed to get AudioConverter: %@", 
                        stringForOSStatus(status)]; 
        
        // Convert mono files to stereo by duplicating channel
        if (format.mChannelsPerFrame == 1)
        {
            if (conv)
            {
                SInt32 channelMap[] = { 0, 0 };
                status = AudioConverterSetProperty(conv, 
                                                   kAudioConverterChannelMap, 
                                                   2*sizeof(SInt32), 
                                                   channelMap);
                if(status != noErr)
                    [NSException raise:@"ConvertExcetion" 
                                format:@"failed to set ChannelMap: %@", 
                                stringForOSStatus(status)];             
            }
            else
            {
                [NSException raise:@"ConvertExcetion" 
                            format:@"Failed to get AudioConverter ref"];             
                
            }
        }

        status = ExtAudioFileSetProperty(_outAudioFile, 
                                         kExtAudioFileProperty_ClientDataFormat, 
                                         sizeof(pcmFormat), &pcmFormat);
        if(status != noErr)
            [NSException raise:@"ConvertExcetion" 
                format:@"failed to set ClientDataFormat: %@", 
                stringForOSStatus(status)];
        
        audioBuffer = malloc(AUDIO_BUFFER_SIZE);
        NSAssert(audioBuffer != NULL, @"malloc failed");
        audioBuffer = malloc(AUDIO_BUFFER_SIZE);
        bufferList.mNumberBuffers = 1;
        bufferList.mBuffers[0].mNumberChannels = 
        pcmFormat.mChannelsPerFrame;
        bufferList.mBuffers[0].mData = audioBuffer;
        bufferList.mBuffers[0].mDataByteSize = AUDIO_BUFFER_SIZE;
                
        do {
            
            framesToRead = 
                bufferList.mBuffers[0].mDataByteSize / pcmFormat.mBytesPerFrame;
            status = ExtAudioFileRead(inAudioFile, &framesToRead, &bufferList);
            if(status != noErr)
                [NSException raise:@"ConvertExcetion" 
                            format:@"ExtAudioFileRead failed: %@", 
                            stringForOSStatus(status)];
            
            if (framesToRead > 0) 
            {
                status = ExtAudioFileWrite(_outAudioFile, 
                                           framesToRead, &bufferList);
                if(status != noErr)
                    [NSException raise:@"ConvertExcetion" 
                        format:@"ExtAudioFileWrite failed: %@", 
                        stringForOSStatus(status)];
            }

            framesConverted += framesToRead;
            _outFileLength += framesToRead;
            [_delegate updateStatus:inFileName 
                            handled:framesConverted 
                              total:framesTotal];


        } while(framesToRead > 0);

        [_delegate conversionFinished:inFileName];
    }  
    @catch (NSException *e) {
        *reason = [e reason];
        if (inAudioFile != nil)
            ExtAudioFileDispose(inAudioFile);
        if (audioBuffer)
            free(audioBuffer);
        return NO;
    }

    if (inAudioFile != nil)
        ExtAudioFileDispose(inAudioFile);
    if (audioBuffer)
        free(audioBuffer);

    return YES;
}

@end
