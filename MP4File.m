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

#import "ABLog.h"
#import "MP4Atom.h"
#import "MP4File.h"

// 4M seems to be reasonable buffer
#define TMP_BUFFER_SIZE 16*1024*1024

@implementation MP4File

-(id) initWithFileName: (NSString*)fileName
{
    [super init];
    
    _fh = [NSFileHandle fileHandleForUpdatingAtPath:fileName];
    _artist = nil;
    _title = nil;

    UInt64 pos = 0;
    NSData *buffer;
    UInt64 end = [_fh seekToEndOfFile];
    [_fh seekToFileOffset:0]; 
    
    while (pos < end) {
        // load atoms
        buffer = [_fh readDataOfLength:8];
        MP4Atom *atom = [[MP4Atom alloc] initWithHeaderData:buffer 
                                                  andOffset:pos];
        pos += [atom length];
        [_fh seekToFileOffset:pos];
    }

    return self;
}

-(void) setArtist:(NSString*)artist
{
    [_artist release];
    _artist = [[NSString alloc] initWithString:artist];
}

-(void) setTitle:(NSString*)title
{
    [_title release];
    _title = [[NSString alloc] initWithString:title];
}

-(id) findAtom: (NSString*)atomName
{
    UInt64 pos = 0;
    UInt64 end = 0;
    NSData *buffer;
    id result = nil;
    
    NSMutableArray *chunks = [[NSMutableArray alloc] 
        initWithArray:[atomName componentsSeparatedByString: @"."]];

    end = [_fh seekToEndOfFile];
    [_fh seekToFileOffset:0]; 
    
    while (pos < end) {
        // load atoms
        buffer = [_fh readDataOfLength:8];
        MP4Atom *atom = [[MP4Atom alloc] initWithHeaderData:buffer 
                                                  andOffset:pos];
        if ([[atom name] isEqualToString: [chunks objectAtIndex:0]])
        {
            end = pos + [atom length];
            // meta header has 4 bytes of data after header
            if ([[atom name] isEqualToString: @"meta"])
                pos += 12;
            else
                // skip only atom header and start with content
                pos += 8;
            [chunks removeObjectAtIndex:0];
            if ([chunks count] == 0)
            {
                result = atom;
                break;
            }
        }
        else
            pos += [atom length];

        [_fh seekToFileOffset:pos];
    }

    return result;
}



/*
 * This function assumes that we work with fresh, newly-created file,
 * there should be no "meta" atom 
 */
-(BOOL) updateFile
{
    UInt32 metaSize, udtaSize, ilstSize;
    MP4Atom *freeAtom = [self findAtom:@"free"];

    NSAssert([self findAtom:@"moov.udta"] == nil, 
            @"File contains moov.udta atom");

    MP4Atom *moovAtom = [self findAtom:@"moov"];
    NSAssert(moovAtom != nil, 
            @"File contains no moov atom");

    NSMutableData *ilstContent = [[NSMutableData alloc] init];
    if (_title != nil)
    {
        [ilstContent appendData:[self encodeMetaDataAtom:@"©nam" 
                                                value:_title 
                                                 type:ITUNES_METADATA_STRING_CLASS]];

        [ilstContent appendData:[self encodeMetaDataAtom:@"©alb" 
                                                value:_title 
                                                 type:ITUNES_METADATA_STRING_CLASS]];
        
    }   
    
    if (_artist != nil)
        [ilstContent appendData:[self encodeMetaDataAtom:@"©ART" 
                                                value:_artist 
                                                 type:ITUNES_METADATA_STRING_CLASS]];

    [ilstContent appendData:[self encodeMetaDataAtom:@"©gen" 
                                            value:@"Audiobooks" 
                                             type:ITUNES_METADATA_STRING_CLASS]];
    ilstSize = [ilstContent length] + 4 + 4; // length and name
    MP4Atom *ilstAtom = [[MP4Atom alloc] initWithName:@"ilst" 
                                            andLength:ilstSize];
    NSMutableData *hdlrContent = [NSMutableData dataWithData:[self encodeHDLRAtom]];
    // length, name and misterious junk
    metaSize = [ilstAtom length] + [hdlrContent length] + 4 + 4 + 4;
    MP4Atom *metaAtom = [[MP4Atom alloc] initWithName:@"meta" andLength:metaSize];
    udtaSize = [metaAtom length] + 4 + 4; // length and name
    MP4Atom *udtaAtom = [[MP4Atom alloc] initWithName:@"udta" andLength:udtaSize];
    NSMutableData *atomData = [NSMutableData dataWithData:[udtaAtom encode]];
    [atomData appendData:[metaAtom encode]];
    UInt32 flags = 0;
    // append 
    [atomData appendBytes:&flags length:4];
    [atomData appendData:hdlrContent];
    [atomData appendData:[ilstAtom encode]];
    [atomData appendData:ilstContent];

    // reserve space  at the end of moov by copying data to new position
    UInt64 startOffset = [moovAtom offset] + [moovAtom length];

    // is there enough free space for udta tag?
    if ((freeAtom == nil) || ([freeAtom length] < udtaSize))
    {
        MP4Atom *mdatAtom = [self findAtom:@"mdat"];
        NSAssert(mdatAtom != nil, @"Failed to find mdat atom");
        [self reserveSpace:udtaSize at:startOffset];
        // Make sure mdat atom comes after moov atom
        if ([mdatAtom offset] > [moovAtom offset])
                [self fixSTCOAtomBy:udtaSize];
    }
    else
    {
        [_fh seekToFileOffset:startOffset + udtaSize];

        // update free atom
        [freeAtom setLength:[freeAtom length] - udtaSize];
        [_fh writeData:[freeAtom encode]];
    }
            
    // write udta adn children
    [_fh seekToFileOffset:startOffset];
    [_fh writeData:atomData];

    
    // update moov atom
    [moovAtom setLength:[moovAtom length] + udtaSize];    
    [_fh seekToFileOffset:[moovAtom offset]];
    [_fh writeData:[moovAtom encode]];

    return TRUE;
}

/*
 * Encode iTunes metadata atoms
 */
-(NSData*) encodeMetaDataAtom: (NSString*)name value:(NSString*)value 
    type:(UInt32) type;
{
    UInt32 dataAtomSize = 
            [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding] + 
            4 + 4 + 4 + 4;
    UInt32 atomSize = dataAtomSize + 4 + 4;
    MP4Atom *atom = [[MP4Atom alloc] initWithName:name andLength:atomSize];
    NSMutableData *data = [NSMutableData dataWithData:[atom encode]];
    MP4Atom *dataAtom = [[MP4Atom alloc] initWithName:@"data" 
                                            andLength:dataAtomSize];
    [data appendData:[dataAtom encode]];
    // version and flags
    UInt32 flags = htonl(type);
    [data appendBytes:&flags length:4];
    // null data
    UInt32 zeroData = 0;
    [data appendBytes:&zeroData length:4];
    [data appendBytes:[value UTF8String] 
               length:[value lengthOfBytesUsingEncoding:NSUTF8StringEncoding]];
    return [NSData dataWithData: data];
}

/*
 * Create hdlr atom. Without this atom iTunes refuses to accept file metadata 
 */
-(NSData*) encodeHDLRAtom  
{
    MP4Atom *hdlrAtom = [[MP4Atom alloc] initWithName:@"hdlr" andLength:34];
    UInt32 zeroData = 0;
    const char *tmp = "mdir";
    const char *tmp2 = "appl";
    NSMutableData *data = [NSMutableData dataWithData:[hdlrAtom encode]];

    [data appendBytes:&zeroData length:4];    
    [data appendBytes:&zeroData length:4];
    [data appendBytes:tmp length:4];
    [data appendBytes:tmp2 length:4];
    [data appendBytes:&zeroData length:4];
    [data appendBytes:&zeroData length:4];
    [data appendBytes:&zeroData length:2];
    
    return [NSData dataWithData: data];
}


/*
 * Inserts size bytes at offset in file 
 */
-(void) reserveSpace:(UInt64)size at:(UInt64)offset
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    UInt64 end = [_fh seekToEndOfFile];

    NSLog(@"size: %lld, start offset: %lld, file size: %lld", 
            size, offset, end);
    do {
        UInt64 bufferSize = MIN(end - offset, TMP_BUFFER_SIZE);
        [_fh seekToFileOffset:(end - bufferSize)];
        NSData *buffer = [_fh readDataOfLength:bufferSize];
        if ([buffer length] == 0)
            break;
        [_fh seekToFileOffset:(end - [buffer length]) + size];
        [_fh writeData:buffer];
        end -= [buffer length];
        [pool drain];
    } while(end > offset);

    [pool release];
}

/*
 * stco atom is an index table that contains offsets of 
 * mdata "chunks" from the files start. Formar:
 * [length] [atom] [version/flags] [nentries] [offs1] ...
 */
-(void) fixSTCOAtomBy:(UInt64)shift
{
    UInt32 entries, i, offset;
    NSRange r;
    MP4Atom *stcoAtom = [self findAtom:@"moov.trak.mdia.minf.stbl.stco"];
    NSAssert(stcoAtom != nil, 
                    @"Failed to find moov.trak.mdia.minf.stbl.stco atom");

    NSData *origTable;
    [_fh seekToFileOffset:[stcoAtom offset]+12]; // size, tag and vesrion/flags
    origTable = [_fh readDataOfLength:[stcoAtom length] - 12];
    NSMutableData *fixedTable = [[NSMutableData alloc] initWithData:origTable];
    [fixedTable getBytes:&entries length:4];

    entries = ntohl(entries);
    r.location = 4;
    r.length = 4;
    NSLog(@"stco has %d entrie", entries);
    for (i = 0 ; i < entries; i++)
    {
        [fixedTable getBytes:&offset range:r];
        offset = htonl(ntohl(offset) + shift);
        [fixedTable replaceBytesInRange:r withBytes:&offset];
        r.location += 4;
    }

    [_fh seekToFileOffset:[stcoAtom offset]+12]; // size, tag and vesrion/flags
    [_fh writeData:fixedTable];
    [fixedTable release];
}

@end
