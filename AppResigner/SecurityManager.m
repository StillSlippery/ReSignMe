//
//  CertificateManager.m
//  AppResigner
//
//  Created by Carpe Lucem Media Group on 2/9/13.
//  Copyright (c) 2013 Carpe Lucem Media Group. All rights reserved.
//

#import "SecurityManager.h"
#import "CertificateModel.h"
#import <Security/Security.h>

#define kCmdCodeSign @"/usr/bin/codesign"
#define kCmdZip @"/usr/bin/zip"
#define kCmdUnzip @"/usr/bin/unzip"
#define kCmdMkTemp @"/usr/bin/mktemp"
#define kCmdCp @"/bin/cp"
#define kCmdRm @"/bin/rm"


#define kSecurityManagerTmpFileTemplate @"/tmp/app-resign-XXXXXXXXXXXXXXXX"
#define kSecurityManagerWorkingSubDir @"dump"
#define kSecurityManagerPayloadDir @"Payload"
#define kSecurityManagerResourcesPlistDir @"ResourceRules.plist"
#define kSecurityManagerRenameStr @"_renamed"

@interface SecurityManager()
- (void)postNotifcation:(SMNotificationType *)type withMessage:(NSString *)message;
@end

@implementation SecurityManager
static SecurityManager *_certManager = nil;
+ (SecurityManager *) defaultManager {
    if (_certManager == nil) {
        _certManager = [[SecurityManager alloc] init];
    }
    return _certManager;
}

- (id)init {
    self = [super init];
    if (self) {
        UInt32 versionNum;
        SecKeychainGetVersion(&versionNum);
        
    }
    return self;
}

- (NSArray *)getDistributionCertificatesList {
    NSMutableArray *certList = [NSMutableArray array];
    CFTypeRef searchResultsRef;
    const char *subjectName = kSecurityManagerSubjectNameUTF8CStr;
    CFStringRef subjectNameRef = CFStringCreateWithCString(NULL, subjectName,CFStringGetSystemEncoding());
    CFIndex valCount = 4;
    
    const void *searchKeys[] = {
        kSecClass, //type of keychain item to search for
        kSecMatchSubjectStartsWith,//search on subject
        kSecReturnAttributes,//return propery
        kSecMatchLimit//search limit
    };
    
    const void *searchVals[] = {
        kSecClassCertificate,
        subjectNameRef,
        kCFBooleanTrue,
        kSecMatchLimitAll
    };
    
    CFDictionaryRef dictRef=
        CFDictionaryCreate(kCFAllocatorDefault,
                           searchKeys,
                           searchVals,
                           valCount,
                           &kCFTypeDictionaryKeyCallBacks,
                           &kCFTypeDictionaryValueCallBacks);
    
    
    //if the status is OK, lets put the results
    //into the NSArray
    OSStatus status = SecItemCopyMatching(dictRef, &searchResultsRef);
    if (status) {
        
        NSLog(@"Failed the query: %@!", SecCopyErrorMessageString(status, NULL));
    } else {
        NSArray *searchResults = [NSMutableArray arrayWithArray: (__bridge NSArray *) searchResultsRef];
        
        CertificateModel *curModel;
        for (NSDictionary *curDict in searchResults) {
            curModel = [[CertificateModel alloc] initWithCertificateData:curDict];
            [certList addObject:curModel];
        }
    }
    
    if (dictRef) CFRelease(dictRef);
    
    return [NSArray arrayWithArray:certList];
}

- (void)postNotifcation:(SMNotificationType *)type withMessage:(NSString *)message {
    [[NSNotificationCenter defaultCenter] postNotificationName:type object:self userInfo:[NSDictionary dictionaryWithObject:message forKey:kSecurityManagerNotificationKey]];
}

- (void)signAppWithIdenity:(NSString *)identity appPath:(NSURL *)appPathURL outputPath:(NSURL *)outputPathURL {
    NSFileHandle *file;
    NSPipe *pipe = [NSPipe pipe];
    
    //retrieve the ipa name
    NSString *ipaName = [appPathURL lastPathComponent];
    
    //create temp folder to perform work
    [self postNotifcation:kSecurityManagerNotificationEvent
              withMessage:@"Initializing re-signing process ..."];
    
    NSTask *mktmpTask = [[NSTask alloc] init];
    [mktmpTask setLaunchPath:kCmdMkTemp];
    [mktmpTask setArguments:@[@"-d", kSecurityManagerTmpFileTemplate]];

    [mktmpTask setStandardOutput:pipe];
    file = [pipe fileHandleForReading];
    
    [mktmpTask launch];
    [mktmpTask waitUntilExit];
    
    NSString *tmpPath = [[[NSString alloc] initWithData: [file readDataToEndOfFile] encoding: NSUTF8StringEncoding] stringByReplacingOccurrencesOfString:@"\n"  withString:@""];
    NSURL *tmpPathURL = [NSURL URLWithString:tmpPath];
    
    [self postNotifcation:kSecurityManagerNotificationEvent
              withMessage:[NSString stringWithFormat:@"Created temp directory: %@", [tmpPathURL path]]];
    
    //copy the ipa over to the temp folder
    [self postNotifcation:kSecurityManagerNotificationEvent
              withMessage:[NSString stringWithFormat:@"Copying %@ to %@", ipaName, [tmpPathURL path]]];
    
    NSTask *cpAppTask = [[NSTask alloc] init];
    [cpAppTask setLaunchPath:kCmdCp];
    NSString *cleanAppPath = [NSString stringWithFormat:@"%@", [appPathURL path]];
    NSString *cleanTmpPath = [NSString stringWithFormat:@"%@", [tmpPathURL path]];
    [cpAppTask setArguments:@[cleanAppPath, cleanTmpPath]];
    
    [cpAppTask launch];
    [cpAppTask waitUntilExit];
    
    //NSLog (@"%@ %@ %@",kCmdCp,cleanAppPath, cleanTmpPath  );
    int status;
    if ( (status = [cpAppTask terminationStatus]) != 0) {
        //TODO:HANDLE BETTER
        NSLog(@"Could not copy ipa over!");
        return;
    }
    
    //set location of the copied IPA so we can unzip it
    NSURL *tempIpaSrcPath = [tmpPathURL URLByAppendingPathComponent:ipaName];
    NSURL *tempIpaDstPath = [tmpPathURL URLByAppendingPathComponent:kSecurityManagerWorkingSubDir];
    
    [self postNotifcation:kSecurityManagerNotificationEvent
              withMessage:[NSString stringWithFormat:@"Unziping %@ to %@ ...", ipaName, [tmpPathURL path]]];
    //now unzip the contents of the ipa to prepare for resigning
    NSTask *unzipTask = [[NSTask alloc] init];
    pipe = [NSPipe pipe];
    file = [pipe fileHandleForReading];
    
    [unzipTask setStandardOutput:pipe];
    [unzipTask setStandardError:pipe];
    [unzipTask setLaunchPath:kCmdUnzip];
    [unzipTask setArguments:@[[tempIpaSrcPath path], @"-d", [tempIpaDstPath path]]];
    [unzipTask launch];
    [unzipTask waitUntilExit];
    
    //TODO: read this in asynchononusly
    NSString *unzipOutput = [[NSString alloc] initWithData: [file readDataToEndOfFile] encoding: NSUTF8StringEncoding];
    
    [self postNotifcation:kSecurityManagerNotificationEventOutput withMessage:unzipOutput];
    
    NSError *payloadError;
    
    NSURL *payloadPathURL = [tempIpaDstPath URLByAppendingPathComponent:kSecurityManagerPayloadDir];
    NSArray *payloadPathContents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[payloadPathURL path] error:&payloadError];
    
    if (payloadError) {
        NSLog(@"Could not open: %@", [payloadPathURL path]);
        //TODO: Handle errors
        return;
    } else if (payloadPathContents.count != 1) {
        NSLog(@"Unexpected output in Payloads directory of the IPA!");
        //TODO: handle errors
        return;
    }
    
    //setup paths for codesign
    NSURL *appContentsURL = [payloadPathURL URLByAppendingPathComponent:[payloadPathContents objectAtIndex:0]];
    NSURL *resourcesPathURL = [appContentsURL URLByAppendingPathComponent:kSecurityManagerResourcesPlistDir];
    
    NSArray *codesignArgs = @[ @"--force",
                               @"--sign",
                               identity,
                               @"--resource-rules",
                               [resourcesPathURL path],
                               [appContentsURL path]];
    
    //TODO:check into codesign_allocate
    //TODO:do we need to insert the mobile provisioning profile?
    //sign the app
    [self postNotifcation:kSecurityManagerNotificationEvent
              withMessage:[NSString stringWithFormat:@"Re-signing %@", ipaName]];
    NSTask *codeSignTask = [[NSTask alloc] init];
    [codeSignTask setLaunchPath:kCmdCodeSign];
    [codeSignTask setArguments:codesignArgs];
    
    pipe = [NSPipe pipe];
    file = [pipe fileHandleForReading];
    
    [codeSignTask setStandardOutput:pipe];
    [codeSignTask setStandardError:pipe];
    [codeSignTask launch];
    [codeSignTask waitUntilExit];
    
    NSString *codesignOutput = [[NSString alloc] initWithData:[file readDataToEndOfFile] encoding:NSUTF8StringEncoding];
    [self postNotifcation:kSecurityManagerNotificationEventOutput
              withMessage:codesignOutput];
    
    //Repackage app
    NSString *resignedAppName = [[ipaName stringByDeletingPathExtension] stringByAppendingFormat:@"%@.ipa",kSecurityManagerRenameStr];
    NSString *zipOutputPath = [[outputPathURL URLByAppendingPathComponent:resignedAppName] path];
    
    [self postNotifcation:kSecurityManagerNotificationEvent
              withMessage:[NSString stringWithFormat:@"Saving re-signed app '%@' to output directory: %@ ...", resignedAppName, [outputPathURL path]]];
    NSTask *zipTask = [[NSTask alloc] init];
    [zipTask setLaunchPath:kCmdZip];
    [zipTask setArguments:@[@"-q", @"-r", zipOutputPath, [payloadPathURL path]]];
    
    [zipTask launch];
    [zipTask waitUntilExit];
    
    
    
}

@end