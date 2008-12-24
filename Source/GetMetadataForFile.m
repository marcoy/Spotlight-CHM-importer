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
static NSString *TagsStripXSLTString = @"\
<?xml version='1.0' encoding='utf-8'?> \
<xsl:stylesheet version='1.0' xmlns:xsl='http://www.w3.org/1999/XSL/Transform' xmlns:xhtml='http://www.w3.org/1999/xhtml'> \
<xsl:output method='text'/> \
<xsl:template match='xhtml:head'></xsl:template> \
<xsl:template match='xhtml:script'></xsl:template> \
</xsl:stylesheet>";

// 100MB
static const size_t MAX_FILE_SIZE = 104857600;

int 
extractMetaData(struct chmFile *chmHandle,
                struct chmUnitInfo *ui,
                void *context)
{
    static unsigned char buf[BUFSIZ+1];
    bzero(buf, BUFSIZ);
    if (NULL == context) return CHM_ENUMERATOR_FAILURE;
    NSMutableDictionary *ctxDict = (NSMutableDictionary *)context;
    LONGUINT64 totalFileLen, offset = 0;
    LONGINT64  readLen = 0;
    NSMutableData *chmObjData = [[NSMutableData alloc] init];
    NSMutableString *chmObjStr = [[NSMutableString alloc] init];
    int retEnumVal = CHM_ENUMERATOR_CONTINUE;
    NSError *theError = nil;
    NSString *strippedDataStr = nil;
    
    // Only handle normal file objects within the CHM
    if ( ui->flags & CHM_ENUMERATE_FILES && ui->flags & CHM_ENUMERATE_NORMAL ) {
        
        // Extract meta data from HTML files.
        if (strcasestr(ui->path, ".htm")) { // TODO: Do maximum chm object size check.
            totalFileLen = ui->length;
            
            while (offset != totalFileLen) {
                readLen = chm_retrieve_object(chmHandle, ui, buf, offset, BUFSIZ);
                if (readLen > 0) {
                    offset += readLen;
                    buf[readLen+1] = '\0';
                    [chmObjStr appendString: [NSString stringWithCString: (char *)buf encoding: NSMacOSRomanStringEncoding]];
                }
                else {
                    retEnumVal = CHM_ENUMERATOR_FAILURE;
                    goto metadata_cleanup;
                }
                bzero(buf, BUFSIZ);
            }
            [chmObjData setData: [NSData dataWithBytes:[chmObjStr cStringUsingEncoding: NSMacOSRomanStringEncoding] length: [chmObjStr length]]];
            
            // Strip HTML tags using NSXMLDocument and XSLT.
            // printf("=======================================> Raw Data (%s):\n%s\n", ui->path, [chmObjData bytes]);
            NSXMLDocument *htmlFile = [[[NSXMLDocument alloc] initWithData:chmObjData options: NSXMLDocumentTidyHTML error:&theError] autorelease];
            // printf("==========================> Data HTML (%s):\n%s\n", ui->path, [[htmlFile XMLData] bytes]);
            NSData *strippedData = [htmlFile objectByApplyingXSLTString:TagsStripXSLTString arguments:nil error:&theError];
            //printf("======================> Finally (%s):\n%s\n", ui->path, [strippedData bytes]);
            
            // Set attributes
            NSMutableString * textContentAttr = [ctxDict objectForKey: (NSString *)kMDItemTextContent];
            strippedDataStr = [[NSString alloc] initWithData:strippedData encoding: NSMacOSRomanStringEncoding];
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
        
        // Parsing the .hhc file
        if (strcasestr(ui->path, ".hhc")) {
            totalFileLen = ui->length;
        }
    }
        
metadata_cleanup:
    if (strippedDataStr != nil) [strippedDataStr release];
    [chmObjData release];
    [chmObjStr release];
    return retEnumVal;
}

Boolean 
GetMetadataForFile(void* thisInterface, 
                           CFMutableDictionaryRef attributes, 
                           CFStringRef contentTypeUTI,
                           CFStringRef pathToFile)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    char fileNameBuf[[(NSString *)pathToFile length] + 1];
    struct chmFile *chmHandle = NULL;
    Boolean retBool = TRUE;
    NSMutableDictionary *ctxDict = [[NSMutableDictionary alloc] init];
    
    // Convert the CFString into a C string.
    [(NSString *)pathToFile getCString: fileNameBuf maxLength: [(NSString *) pathToFile length] + 1 encoding: NSUTF8StringEncoding];
    
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
    printf("Setting stuff....\n");
    [(NSMutableDictionary *)attributes setObject: [ctxDict objectForKey:(NSString*) kMDItemTextContent] 
                                          forKey: (NSString *)kMDItemTextContent];
    
cleanup:
    if (NULL != chmHandle) chm_close(chmHandle);
    [ctxDict release];
    [pool release];
    return retBool;
}
