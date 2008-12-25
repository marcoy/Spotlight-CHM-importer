//
//  GetMetadataForFile.m
//  CHMTestImporter
//
//  Created by Marco Yuen on 24/12/08.
//  Copyright 2008 University of Victoria. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <strings.h>
#import <string.h>
#import "chm_lib.h"

// XSLT responsible for stripping out all the tags.
static NSString * const TagsStripXSLTString = @"\
<?xml version='1.0' encoding='utf-8'?> \
<xsl:stylesheet version='1.0' xmlns:xsl='http://www.w3.org/1999/XSL/Transform' xmlns:xhtml='http://www.w3.org/1999/xhtml'> \
<xsl:output method='text'/> \
<xsl:template match='xhtml:head'></xsl:template> \
<xsl:template match='xhtml:script'></xsl:template> \
</xsl:stylesheet>";

// 100MB
static const size_t MAX_FILE_SIZE = 104857600;
static const NSStringEncoding DEFAULT_ENCODING = NSUTF8StringEncoding;

#pragma mark -
#pragma mark Custom Attribute
NSString * const com_marcoyuen_chmImporter_SectionTitles = @"com_marcoyuen_chm_SectionTitles";

#pragma mark -
#pragma mark Converter
@interface ChmObjectConverter : NSObject
{ }
+ (NSMutableString *) toStringFromCHMHandle:(struct chmFile * const) chmHandle
                                   unitInfo:(struct chmUnitInfo * const) ui
                                     retVal:(int *)retVal;
+ (NSMutableData *) toDataFromCHMHandle:(struct chmFile * const) chmHandle
                                 unitInfo:(struct chmUnitInfo * const) ui
                                   retVal:(int *)retVal;
@end

@implementation ChmObjectConverter
+ (NSMutableString *) toStringFromCHMHandle:(struct chmFile * const) chmHandle
                                   unitInfo:(struct chmUnitInfo * const) ui
                                     retVal:(int *)retVal;
{
    static unsigned char buf[BUFSIZ + 1];
    bzero(buf, BUFSIZ+1);
    LONGUINT64 totalFileLen = ui->length, offset = 0;
    LONGINT64  readLen = 0;
    NSMutableString *stringData = [[NSMutableString alloc] init];
    
    while (totalFileLen != offset) {
        readLen = chm_retrieve_object(chmHandle, ui, buf, offset, BUFSIZ);
        if (readLen > 0) {
            offset += readLen;
            buf[readLen + 1] = '\0';
            [stringData appendString:[NSString stringWithCString:(const char *)buf encoding:DEFAULT_ENCODING]];
        } else {
            *retVal = CHM_ENUMERATOR_FAILURE;
            break;
        }
    }
    
    return [stringData autorelease];
}

+ (NSMutableData *) toDataFromCHMHandle:(struct chmFile * const) chmHandle
                                 unitInfo:(struct chmUnitInfo * const) ui
                                   retVal:(int *)retVal
{
    static unsigned char buf[BUFSIZ + 1];
    bzero(buf, BUFSIZ+1);
    LONGUINT64 totalFileLen = ui->length, offset = 0;
    LONGINT64  readLen = 0;
    NSMutableData *chmData = [[NSMutableData alloc] init];
    
    while (totalFileLen != offset) {
        readLen = chm_retrieve_object(chmHandle, ui, buf, offset, BUFSIZ);
        if (readLen > 0) {
            offset += readLen;
            buf[readLen + 1] = '\0';
            [chmData appendBytes:buf 
                          length:readLen];
        } else {
            *retVal = CHM_ENUMERATOR_FAILURE;
            break;
        }
    }
    return [chmData autorelease];
}
@end

#pragma mark -
#pragma mark CHMLib callback
int 
extractMetaData(struct chmFile *chmHandle,
                struct chmUnitInfo *ui,
                void *context)
{
    if (NULL == context) return CHM_ENUMERATOR_FAILURE;
    NSMutableDictionary *ctxDict = (NSMutableDictionary *)context;
    int retEnumVal = CHM_ENUMERATOR_CONTINUE;
    NSError *theError = nil;
    NSString *strippedDataStr = nil;
    
    // Only handle normal file objects within the CHM
    if ( ui->flags & CHM_ENUMERATE_FILES && ui->flags & CHM_ENUMERATE_NORMAL ) {
        
        // Extract metadata from HTML files.
        if (strcasestr(ui->path, ".htm")) {
            // Retrieve the chm object as a NSData object.
            NSData * chmData = [ChmObjectConverter toDataFromCHMHandle:chmHandle unitInfo:ui retVal:&retEnumVal];
            if (retEnumVal == CHM_ENUMERATOR_FAILURE) goto metadata_cleanup;
            
            // Strip HTML tags using NSXMLDocument and XSLT.
            NSXMLDocument *htmlFile = [[[NSXMLDocument alloc] initWithData:chmData options: NSXMLDocumentTidyHTML error:&theError] autorelease];
            NSData *strippedData = [htmlFile objectByApplyingXSLTString:TagsStripXSLTString arguments:nil error:&theError];
            
            // Debugging
            // printf("==========================> Data HTML (%s):\n%s\n", ui->path, [[htmlFile XMLData] bytes]);
            // printf("======================> Finally (%s):\n%s\n", ui->path, [strippedData bytes]);
            
            // Set attributes
            NSMutableString * textContentAttr = [ctxDict objectForKey: (NSString *)kMDItemTextContent];
            strippedDataStr = [[NSString alloc] initWithData:strippedData encoding: DEFAULT_ENCODING];
            if (nil == textContentAttr) {
                textContentAttr = [NSMutableString stringWithString:strippedDataStr];
                [ctxDict setObject:textContentAttr forKey: (NSString *)kMDItemTextContent];
            } else {
                // If the combine size is greater than MAX_FILE_SIZE. Stop enumerating and return.
                if ([textContentAttr length] + [strippedDataStr length] >= MAX_FILE_SIZE) {
                    retEnumVal = CHM_ENUMERATOR_SUCCESS;
                    goto metadata_cleanup;
                } else {
                    [textContentAttr appendString:strippedDataStr];
                }
            }
        }
        
        // Extract metadata from HHC file.
        if (strcasestr(ui->path, ".hhc")) {
            NSMutableData  *hhcData = [ChmObjectConverter toDataFromCHMHandle:chmHandle unitInfo:ui retVal:&retEnumVal];
            NSXMLDocument *hhcDoc = [[[NSXMLDocument alloc] initWithData:hhcData options:NSXMLDocumentTidyHTML error:&theError] autorelease];
            if (nil == hhcDoc) {
                retEnumVal = CHM_ENUMERATOR_CONTINUE;
                goto metadata_cleanup;
            }
            
            // Usng XPath to get a list of headings. Only top level headings are being traversed.
            NSXMLNode *rootNode = [hhcDoc rootElement];
            theError = nil;
            NSArray *ulNodes = [rootNode nodesForXPath:@"./body/ul/li/object/param[@name=\"Name\"]" error:&theError];
            if (nil != theError) {
                // Malform!?
                NSLog(@"Cannot get the <ul> element from %s", ui->path);
                retEnumVal = CHM_ENUMERATOR_FAILURE;
                goto metadata_cleanup;
            } else if ([ulNodes count] <= 0) {
                retEnumVal = CHM_ENUMERATOR_CONTINUE;
                goto metadata_cleanup;
            }
            
            // Start parsing based on heuristics:
            // 1. The first element is _usually_ the title of the book.
            // 2. Everything else---title heading.
            NSXMLElement *curElement = nil;
            int i = 1;
            curElement = [ulNodes objectAtIndex:0];
            NSString *chmTitle = [[curElement attributeForName:@"value"] stringValue];
            [ctxDict setObject:chmTitle forKey:(NSString *)kMDItemTitle];
            
            NSMutableArray * sectionTitles = [NSMutableArray array];
            for (i = 1; i < [ulNodes count]; ++i) {
                curElement = [ulNodes objectAtIndex:i];
                [sectionTitles addObject: [[curElement attributeForName:@"value"] stringValue]];
            }
            [ctxDict setObject:sectionTitles forKey:com_marcoyuen_chmImporter_SectionTitles];
            // NSLog(@"The title:\n%@", sectionTitles);
        }
    }
        
metadata_cleanup:
    if (strippedDataStr != nil) [strippedDataStr release];
    return retEnumVal;
}

#pragma mark -
#pragma mark Importer entrance function
Boolean 
GetMetadataForFile(void* thisInterface, 
                           CFMutableDictionaryRef attributes, 
                           CFStringRef contentTypeUTI,
                           CFStringRef pathToFile)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    char fileNameBuf[[(NSString *)pathToFile length] + 1];
    struct chmFile *chmHandle = NULL;
    Boolean retBool = FALSE;
    NSMutableDictionary *ctxDict = [[NSMutableDictionary alloc] init];
    
    // Convert the CFString into a C string.
    [(NSString *)pathToFile getCString: fileNameBuf maxLength: [(NSString *) pathToFile length] + 1 encoding: DEFAULT_ENCODING];
    
    // Open the chm file then enumerate the objects within it.
    chmHandle = chm_open(fileNameBuf);
    if (NULL == chmHandle) {
        fprintf(stderr, "Cannot open '%s'\n", fileNameBuf);
        retBool = FALSE;
        goto cleanup;
    }
    
    if (!chm_enumerate(chmHandle, CHM_ENUMERATE_ALL, extractMetaData, (void *)ctxDict)) {
        fprintf(stderr, "Enumeration failed\n");
        retBool = FALSE;
        goto cleanup;
    }
    
    // Set the attributes.
    [(NSMutableDictionary *)attributes setObject: [ctxDict objectForKey:(NSString*) kMDItemTextContent] 
                                          forKey: (NSString *)kMDItemTextContent];
    NSString *title = nil;
    if ( (title = [ctxDict objectForKey:(NSString *)kMDItemTitle]) != nil ) {
        [(NSMutableDictionary *)attributes setObject:title forKey:(NSString *)kMDItemTitle];
    }
    NSArray *sectionTitles = nil;
    if ( (sectionTitles = [ctxDict objectForKey:com_marcoyuen_chmImporter_SectionTitles]) != nil ) {
        [(NSMutableDictionary *)attributes setObject:sectionTitles forKey:com_marcoyuen_chmImporter_SectionTitles];
    }
    
    // Finished setting all the attributes
    retBool = TRUE;
    
cleanup:
    if (NULL != chmHandle) chm_close(chmHandle);
    [ctxDict release];
    [pool release];
    return retBool;
}
