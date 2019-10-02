#import <Foundation/Foundation.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <React/RCTEventEmitter.h>
#import <React/RCTBridgeModule.h>
#import <Photos/Photos.h>

@interface VydiaRNFileUploader : RCTEventEmitter <RCTBridgeModule, NSURLSessionTaskDelegate>
{
  NSMutableDictionary *_responsesData;
}
@end

@implementation VydiaRNFileUploader

RCT_EXPORT_MODULE();

@synthesize bridge = _bridge;
static int uploadId = 0;
static RCTEventEmitter* staticEventEmitter = nil;
static NSString *BACKGROUND_SESSION_ID = @"ReactNativeBackgroundUpload";
NSURLSession *_urlSession = nil;
NSMutableDictionary *_fileURIs = nil;
NSMutableDictionary *_tmpURIs = nil;

+ (BOOL)requiresMainQueueSetup {
    return NO;
}

-(id) init {
  self = [super init];
  [[NSNotificationCenter defaultCenter] addObserver:self
  selector:@selector(resumeTasks)
      name:UIApplicationDidBecomeActiveNotification object:nil];
  if (self) {
    staticEventEmitter = self;
    _responsesData = [NSMutableDictionary dictionary];
    _fileURIs = [NSMutableDictionary dictionary];
    _tmpURIs = [NSMutableDictionary dictionary];
  }
  return self;
}

- (void)_sendEventWithName:(NSString *)eventName body:(id)body {
  if (staticEventEmitter == nil)
    return;
  [staticEventEmitter sendEventWithName:eventName body:body];
}

- (NSArray<NSString *> *)supportedEvents {
    return @[
        @"RNFileUploader-progress",
        @"RNFileUploader-error",
        @"RNFileUploader-cancelled",
        @"RNFileUploader-completed",
        @"RNFileUploader-info"
    ];
}

// work around to get delegates firing again after app becomes active again
- (void)resumeTasks {
    #if DEBUG
        NSLog(@"%@", @"Resuming upload tasks");
    #endif
    NSURLSession* session = [self urlSession];
    [session getTasksWithCompletionHandler:^(NSArray<NSURLSessionDataTask *> * _Nonnull dataTasks, NSArray<NSURLSessionUploadTask *> * _Nonnull uploadTasks, NSArray<NSURLSessionDownloadTask *> * _Nonnull downloadTasks) {
        for (id task in uploadTasks) {
            [task resume];
        }
    }];
};


/*
 Gets file information for the path specified.  Example valid path is: file:///var/mobile/Containers/Data/Application/3C8A0EFB-A316-45C0-A30A-761BF8CCF2F8/tmp/trim.A5F76017-14E9-4890-907E-36A045AF9436.MOV
 Returns an object such as: {mimeType: "video/quicktime", size: 2569900, exists: true, name: "trim.AF9A9225-FC37-416B-A25B-4EDB8275A625.MOV", extension: "MOV"}
 */
RCT_EXPORT_METHOD(getFileInfo:(NSString *)path resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject)
{
    @try {
        NSString *filePath = [self filePath:path];
        NSString *name = [filePath lastPathComponent];
        NSString *extension = [name pathExtension];
        bool exists = [[NSFileManager defaultManager] fileExistsAtPath:filePath];
        NSMutableDictionary *params = [NSMutableDictionary dictionaryWithObjectsAndKeys: name, @"name", nil];
        [params setObject:extension forKey:@"extension"];
        [params setObject:[NSNumber numberWithBool:exists] forKey:@"exists"];

        if (exists)
        {
            [params setObject:[self guessMIMETypeFromFileName:name] forKey:@"mimeType"];
            NSError* error;
            NSDictionary<NSFileAttributeKey, id> *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:&error];
            if (error == nil)
            {
                unsigned long long fileSize = [attributes fileSize];
                [params setObject:[NSNumber numberWithLong:fileSize] forKey:@"size"];
            }
        }
        resolve(params);
    }
    @catch (NSException *exception) {
        reject(@"RN Uploader", exception.name, nil);
    }
}

/*
 Borrowed from http://stackoverflow.com/questions/2439020/wheres-the-iphone-mime-type-database
*/
- (NSString *)guessMIMETypeFromFileName: (NSString *)fileName {
    CFStringRef UTI = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, (__bridge CFStringRef)[fileName pathExtension], NULL);
    CFStringRef MIMEType = UTTypeCopyPreferredTagWithClass(UTI, kUTTagClassMIMEType);
    CFRelease(UTI);
    if (!MIMEType) {
        return @"application/octet-stream";
    }
    return (__bridge NSString *)(MIMEType);
}

/*
 Utility method to copy a PHAsset file into a local temp file, which can then be uploaded.
 */
- (void)copyAssetToFile: (NSString *)assetUrl completionHandler: (void(^)(NSString *__nullable tempFileUrl, NSError *__nullable error))completionHandler {
    if ([assetUrl hasPrefix:@"assets-library"]) {
        NSURL *url = [NSURL URLWithString:assetUrl];
        PHAsset *asset = [PHAsset fetchAssetsWithALAssetURLs:@[url] options:nil].lastObject;
        if (!asset) {
            NSMutableDictionary* details = [NSMutableDictionary dictionary];
            [details setValue:@"Asset could not be fetched.  Are you missing permissions?" forKey:NSLocalizedDescriptionKey];
            completionHandler(nil,  [NSError errorWithDomain:@"RNUploader" code:5 userInfo:details]);
            return;
        }
        PHAssetResource *assetResource = [[PHAssetResource assetResourcesForAsset:asset] firstObject];
        NSString *pathToWrite = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
        NSURL *pathUrl = [NSURL fileURLWithPath:pathToWrite];
        NSString *fileURI = pathUrl.absoluteString;

        PHAssetResourceRequestOptions *options = [PHAssetResourceRequestOptions new];
        options.networkAccessAllowed = YES;

        [[PHAssetResourceManager defaultManager] writeDataForAssetResource:assetResource toFile:pathUrl options:options completionHandler:^(NSError * _Nullable e) {
            if (e == nil) {
                completionHandler(fileURI, nil);
            }
            else {
                completionHandler(nil, e);
            }
        }];
    } else {
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSString *tmpUrl = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
        NSError *error;
        // call self:filePath to get the file path without protocol prefix file://
        if([fileManager copyItemAtPath:[self filePath:assetUrl] toPath:tmpUrl error:&error]) {
            // call self:fileURI to prefix the tmpUrl with file:// as the rest of the code expects a fileURI
            completionHandler([self fileURI:tmpUrl], nil);
        } else {
            completionHandler(nil, error);
        }
    }
}

/*
 * Starts a file upload.
 * Options are passed in as the first argument as a js hash:
 * {
 *   url: string.  url to post to.
 *   path: string.  path to the file on the device
 *   headers: hash of name/value header pairs
 * }
 *
 * Returns a promise with the string ID of the upload.
 */
RCT_EXPORT_METHOD(startUpload:(NSDictionary *)options resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject)
{
    int thisUploadId;
    @synchronized(self.class)
    {
        thisUploadId = uploadId++;
    }

    NSString *uploadUrl = options[@"url"];
    __block NSString *fileURI = options[@"path"];
    NSString *method = options[@"method"] ?: @"POST";
    // NSString *uploadType = options[@"type"] ?: @"raw";
    // NSString *fieldName = options[@"field"];
    NSString *customUploadId = options[@"customUploadId"];
    NSDictionary *headers = options[@"headers"];
    // NSDictionary *parameters = options[@"parameters"];

    @try {
        NSURL *requestUrl = [NSURL URLWithString: uploadUrl];
        if (requestUrl == nil) {
            @throw @"Request cannot be nil";
        }

        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:requestUrl];
        [request setHTTPMethod: method];

        [headers enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull val, BOOL * _Nonnull stop) {
            if ([val respondsToSelector:@selector(stringValue)]) {
                val = [val stringValue];
            }
            if ([val isKindOfClass:[NSString class]]) {
                [request setValue:val forHTTPHeaderField:key];
            }
        }];
        
        dispatch_group_t group = dispatch_group_create();
        dispatch_group_enter(group);
        [self copyAssetToFile:fileURI completionHandler:^(NSString * _Nullable tempFileURI, NSError * _Nullable error) {
            if (error) {
                dispatch_group_leave(group);
                reject(@"RN Uploader", @"Asset could not be copied to temp file.", nil);
                return;
            }
            [_tmpURIs setValue:tempFileURI forKey:uploadUrl];
            fileURI = tempFileURI;
            dispatch_group_leave(group);
        }];
        dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

        NSURLSessionUploadTask *uploadTask;
        
        uploadTask = [[self urlSession] uploadTaskWithRequest:request fromFile:[NSURL URLWithString:fileURI]];

        uploadTask.taskDescription = customUploadId ? customUploadId : [NSString stringWithFormat:@"%i", thisUploadId];

        [uploadTask resume];
        resolve(uploadTask.taskDescription);
    }
    @catch (NSException *exception) {
        reject(@"RN Uploader", exception.name, nil);
    }
}

/*
 * Cancels file upload
 * Accepts upload ID as a first argument, this upload will be cancelled
 * Event "cancelled" will be fired when upload is cancelled.
 */
RCT_EXPORT_METHOD(cancelUpload: (NSString *)cancelUploadId resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject) {
    [_urlSession getTasksWithCompletionHandler:^(NSArray *dataTasks, NSArray *uploadTasks, NSArray *downloadTasks) {
        for (NSURLSessionTask *uploadTask in uploadTasks) {
            if ([uploadTask.taskDescription isEqualToString:cancelUploadId]){
                // == checks if references are equal, while isEqualToString checks the string value
                [uploadTask cancel];
            }
        }
    }];
    resolve([NSNumber numberWithBool:YES]);
}

- (NSURLSession *)urlSession {
    if (_urlSession == nil) {
        NSURLSessionConfiguration *sessionConfiguration = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:BACKGROUND_SESSION_ID];
        _urlSession = [NSURLSession sessionWithConfiguration:sessionConfiguration delegate:self delegateQueue:nil];
    }

    return _urlSession;
}

- (NSString *)filePath:(NSString *)fileURI {
    if (![fileURI hasPrefix:@"file://"]) {
        return fileURI;
    }
    NSURL *url = [NSURL URLWithString: fileURI];
    NSString *path = [url path];
    return path;
}

- (NSString *)fileURI:(NSString *)filePath {
    if ([filePath hasPrefix:@"file://"]) {
        return filePath;
    }
    return [NSString stringWithFormat:@"file://%@", filePath];
}

#pragma NSURLSessionTaskDelegate

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    NSMutableDictionary *data = [NSMutableDictionary dictionaryWithObjectsAndKeys:task.taskDescription, @"id", nil];
    NSURLSessionDataTask *uploadTask = (NSURLSessionDataTask *)task;
    NSHTTPURLResponse *response = (NSHTTPURLResponse *)uploadTask.response;
    if (response != nil)
    {
        [data setObject:[NSNumber numberWithInteger:response.statusCode] forKey:@"responseCode"];
    }
    //Add data that was collected earlier by the didReceiveData method
    NSMutableData *responseData = _responsesData[@(task.taskIdentifier)];
    if (responseData) {
        [_responsesData removeObjectForKey:@(task.taskIdentifier)];
        NSString *response = [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding];
        [data setObject:response forKey:@"responseBody"];
    } else {
        [data setObject:[NSNull null] forKey:@"responseBody"];
    }

    if (error == nil)
    {
        [self _sendEventWithName:@"RNFileUploader-completed" body:data];
    }
    else
    {
        [data setObject:error.localizedDescription forKey:@"error"];
        if (error.code == NSURLErrorCancelled) {
            [self _sendEventWithName:@"RNFileUploader-cancelled" body:data];
        } else {
            [self _sendEventWithName:@"RNFileUploader-error" body:data];
        }
    }
    // clean up
    NSURLRequest *request = [task originalRequest];
    NSString *requestUrl = [[request URL] absoluteString];
    [_fileURIs removeObjectForKey:requestUrl];
    
    NSString *tmpURI = [_tmpURIs valueForKey:requestUrl];
    if (tmpURI) {
        [[NSFileManager defaultManager] removeItemAtPath:[self filePath:tmpURI] error:nil];
        [_tmpURIs removeObjectForKey:requestUrl];
    }
    #if DEBUG
        NSLog(@"%@", data);
    #endif
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
   didSendBodyData:(int64_t)bytesSent
    totalBytesSent:(int64_t)totalBytesSent
totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend {
    float progress = -1;
    if (totalBytesExpectedToSend > 0) //see documentation.  For unknown size it's -1 (NSURLSessionTransferSizeUnknown)
    {
        progress = 100.0 * (float)totalBytesSent / (float)totalBytesExpectedToSend;
    }
    [self _sendEventWithName:@"RNFileUploader-progress" body:@{ @"id": task.taskDescription, @"progress": [NSNumber numberWithFloat:progress] }];
    #if DEBUG
        NSLog(@"%f", progress);
    #endif
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    if (!data.length) {
        return;
    }
    //Hold returned data so it can be picked up by the didCompleteWithError method later
    NSMutableData *responseData = _responsesData[@(dataTask.taskIdentifier)];
    if (!responseData) {
        responseData = [NSMutableData dataWithData:data];
        _responsesData[@(dataTask.taskIdentifier)] = responseData;
    } else {
        [responseData appendData:data];
    }
}

- (void)URLSession:(NSURLSession *)session didBecomeInvalidWithError:(NSError *)error {
    NSMutableDictionary *data = [NSMutableDictionary dictionaryWithObjectsAndKeys:error.localizedDescription, @"error", nil];
    [data setObject:@"didBecomeInvalidWithError" forKey:@"info"];
    [self _sendEventWithName:@"RNFileUploader-info" body:data];
    #if DEBUG
        NSLog(@"%@", data);
    #endif
}

- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session {
    NSMutableDictionary *data = [NSMutableDictionary dictionaryWithObjectsAndKeys:@"URLSessionDidFinishEventsForBackgroundURLSession", @"info", nil];
    [self _sendEventWithName:@"RNFileUploader-info" body:data];
    #if DEBUG
        NSLog(@"%@", data);
    #endif
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
willBeginDelayedRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLSessionDelayedRequestDisposition disposition, NSURLRequest *newRequest))completionHandler  API_AVAILABLE(ios(11.0)) {
     NSMutableDictionary *data = [NSMutableDictionary dictionaryWithObjectsAndKeys:task.taskDescription, @"id", nil];
     [data setObject:@"willBeginDelayedRequest" forKey:@"info"];
     [data setObject:completionHandler forKey:@"completionHandler"];
     [self _sendEventWithName:@"RNFileUploader-info" body:data];
     completionHandler(NSURLSessionDelayedRequestContinueLoading, nil);
     #if DEBUG
        NSLog(@"%@", data);
     #endif
 }

@end
