// Copyright © Microsoft Open Technologies, Inc.
//
// All Rights Reserved
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// THIS CODE IS PROVIDED *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS
// OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION
// ANY IMPLIED WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A
// PARTICULAR PURPOSE, MERCHANTABILITY OR NON-INFRINGEMENT.
//
// See the Apache License, Version 2.0 for the specific language
// governing permissions and limitations under the License.

#import "ADAL_Internal.h"
#import "ADOAuth2Constants.h"
#import "NSURL+ADExtensions.h"
#import "ADErrorCodes.h"
#import "NSString+ADHelperMethods.h"
#import "ADWebRequest.h"
#import "ADWebResponse.h"
#import "ADAuthenticationSettings.h"
#import "ADHelpers.h"
#import "ADLogger+Internal.h"

NSString *const HTTPGet  = @"GET";
NSString *const HTTPPost = @"POST";

@interface ADWebRequest () <NSURLConnectionDelegate>

- (void)completeWithError:(NSError *)error andResponse:(ADWebResponse *)response;
- (void)send;
- (BOOL)verifyRequestURL:(NSURL *)requestURL;

@end

@implementation ADWebRequest

#pragma mark - Properties

@synthesize URL      = _requestURL;
@synthesize headers  = _requestHeaders;
@synthesize method   = _requestMethod;
@synthesize timeout  = _timeout;

- (NSData *)body
{
    return _requestData;
}

- (void)setBody:(NSData *)body
{
    if ( body != nil )
    {
        SAFE_ARC_RELEASE(_requestMethod);
        _requestMethod = HTTPPost;
        SAFE_ARC_RETAIN(_requestMethod);
        SAFE_ARC_RELEASE(_requestData);
        _requestData   = body;
        SAFE_ARC_RETAIN(_requestData);
        
        // Add default HTTP Headers to the request: Expect
        // Note that we don't bother with Expect because iOS does not support it
        //[_requestHeaders setValue:@"100-continue" forKey:@"Expect"];
    }
}

#pragma mark - Initialization

- (id)initWithURL:(NSURL *)requestURL
    correlationId:(NSUUID *)correlationId
{
    if (!(self = [super init]))
    {
        return nil;
    }
    
    _requestURL        = [requestURL copy];
    _requestMethod     = HTTPGet;
    SAFE_ARC_RETAIN(_requestMethod);
    _requestHeaders    = [[NSMutableDictionary alloc] init];
    
    // Default timeout for ADWebRequest is 30 seconds
    _timeout           = [[ADAuthenticationSettings sharedInstance] requestTimeOut];
    
    _correlationId     = correlationId;
    SAFE_ARC_RETAIN(_correlationId);
    
    _operationQueue = [[NSOperationQueue alloc] init];
    [_operationQueue setMaxConcurrentOperationCount:1];
    
    return self;
}


- (void)dealloc
{
    SAFE_ARC_RELEASE(_connection);
    
    SAFE_ARC_RELEASE(_requestURL);
    SAFE_ARC_RELEASE(_requestMethod);
    SAFE_ARC_RELEASE(_requestHeaders);
    SAFE_ARC_RELEASE(_requestData);
    
    SAFE_ARC_RELEASE(_response);
    SAFE_ARC_RELEASE(_responseData);
    
    SAFE_ARC_RELEASE(_correlationId);
    
    SAFE_ARC_RELEASE(_operationQueue);
    
    SAFE_ARC_RELEASE(_completionHandler);
    
    SAFE_ARC_SUPER_DEALLOC();
}

// Cleans up and then calls the completion handler
- (void)completeWithError:(NSError *)error andResponse:(ADWebResponse *)response
{
    // Cleanup
    SAFE_ARC_RELEASE(_requestURL);
    _requestURL     = nil;
    SAFE_ARC_RELEASE(_requestMethod);
    _requestMethod  = nil;
    SAFE_ARC_RELEASE(_requestHeaders);
    _requestHeaders = nil;
    SAFE_ARC_RELEASE(_requestData);
    _requestData    = nil;
    
    SAFE_ARC_RELEASE(_response);
    _response       = nil;
    SAFE_ARC_RELEASE(_responseData);
    _responseData   = nil;
    
    SAFE_ARC_RELEASE(_connection);
    _connection     = nil;
    
    if ( _completionHandler != nil )
    {
        _completionHandler( error, response );
        SAFE_ARC_RELEASE(_completionHandler);
        _completionHandler = nil;
    }
}

- (void)send:(void (^)(NSError *, ADWebResponse *))completionHandler
{
    SAFE_ARC_RELEASE(_completionHandler);
    _completionHandler = [completionHandler copy];
    
    SAFE_ARC_RELEASE(_response);
    _response          = nil;
    SAFE_ARC_RELEASE(_responseData);
    _responseData      = [[NSMutableData alloc] init];
    
    [self send];
}

- (void)send
{
    [_requestHeaders addEntriesFromDictionary:[ADLogger adalId]];
    //Correlation id:
    if (_correlationId)
    {
        [_requestHeaders addEntriesFromDictionary:
         @{
           OAUTH2_CORRELATION_ID_REQUEST:@"true",
           OAUTH2_CORRELATION_ID_REQUEST_VALUE:[_correlationId UUIDString]
           }];
    }
    // If there is request data, then set the Content-Length header
    if ( _requestData != nil )
    {
        [_requestHeaders setValue:[NSString stringWithFormat:@"%ld", (unsigned long)_requestData.length] forKey:@"Content-Length"];
    }
    
    NSURL* requestURL = [ADHelpers addClientVersionToURL:_requestURL];
    
    NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:requestURL
                                                                cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                            timeoutInterval:_timeout];
    
    request.HTTPMethod          = _requestMethod;
    request.allHTTPHeaderFields = _requestHeaders;
    request.HTTPBody            = _requestData;
    
    SAFE_ARC_RELEASE(_connection);
    _connection = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:NO];
    SAFE_ARC_RELEASE(request);
    [_connection setDelegateQueue:_operationQueue];
    [_connection start];
}

- (BOOL)verifyRequestURL:(NSURL *)requestURL
{
    if ( requestURL == nil )
        return NO;
    
    if ( ![requestURL.scheme isEqualToString:@"http"] && ![requestURL.scheme isEqualToString:@"https"] )
        return NO;
    
    return YES;
}

#pragma mark - NSURLConnectionDelegate

// Connection Authentication

// Discussion
// This method allows the delegate to make an informed decision about connection authentication at once.
// If the delegate implements this method, it has no need to implement connection:canAuthenticateAgainstProtectionSpace:, connection:didReceiveAuthenticationChallenge:, connectionShouldUseCredentialStorage:.
// In fact, these other methods are not invoked.
- (void)connection:(NSURLConnection *)connection willSendRequestForAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
{
#pragma unused(connection)
    // Do default handling
    [challenge.sender performDefaultHandlingForAuthenticationChallenge:challenge];
}

// Connection Completion

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
#pragma unused(connection)
    
    [self completeWithError:error andResponse:nil];
}

// Method Group
- (NSCachedURLResponse *)connection:(NSURLConnection *)connection willCacheResponse:(NSCachedURLResponse *)cachedResponse
{
#pragma unused(connection)
#pragma unused(cachedResponse)
    
    return nil;
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
#pragma unused(connection)
    
    SAFE_ARC_RELEASE(_response);
    _response = (NSHTTPURLResponse *)response;
    SAFE_ARC_RETAIN(_response);
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
#pragma unused(connection)
    
    [_responseData appendData:data];
}

- (NSURLRequest *)connection:(NSURLConnection *)connection willSendRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)redirectResponse
{
#pragma unused(connection)
#pragma unused(redirectResponse)
    NSURL* requestURL = [request URL];
    NSURL* modifiedURL = [ADHelpers addClientVersionToURL:requestURL];
    if (modifiedURL == requestURL)
        return request;
    
    return [NSURLRequest requestWithURL:modifiedURL];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
#pragma unused(connection)
    
    //
    // NOTE: There is a race condition between this method and the challenge handling methods
    //       dependent on the the challenge processing that the application performs.
    //
    NSAssert( _response != nil, @"No HTTP Response available" );
    
    ADWebResponse* response = [[ADWebResponse alloc] initWithResponse:_response data:_responseData];
    SAFE_ARC_AUTORELEASE(response);
    [self completeWithError:nil andResponse:response];
}

//required method Available in OS X v10.6 through OS X v10.7, then deprecated
-(void)connection:(NSURLConnection *)connection didSendBodyData:(NSInteger)bytesWritten totalBytesWritten:(NSInteger)totalBytesWritten totalBytesExpectedToWrite:(NSInteger)totalBytesExpectedToWrite
{
#pragma unused(connection)
#pragma unused(bytesWritten)
#pragma unused(totalBytesWritten)
#pragma unused(totalBytesExpectedToWrite)
    
}

@end