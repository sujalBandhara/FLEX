//
//  FLEXNetworkRecorder.m
//  Flipboard
//
//  Created by Ryan Olson on 2/4/15.
//  Copyright (c) 2015 Flipboard. All rights reserved.
//

#import "FLEXNetworkRecorder.h"
#import "FLEXNetworkTransaction.h"
#import "FLEXUtility.h"
#import "FLEXResources.h"

NSString *const kFLEXNetworkRecorderNewTransactionNotification = @"kFLEXNetworkRecorderNewTransactionNotification";
NSString *const kFLEXNetworkRecorderTransactionUpdatedNotification = @"kFLEXNetworkRecorderTransactionUpdatedNotification";
NSString *const kFLEXNetworkRecorderUserInfoTransactionKey = @"transaction";
NSString *const kFLEXNetworkRecorderTransactionsClearedNotification = @"kFLEXNetworkRecorderTransactionsClearedNotification";

NSString *const kFLEXNetworkRecorderResponseCacheLimitDefaultsKey = @"com.flex.responseCacheLimit";

@interface FLEXNetworkRecorder ()

@property (nonatomic, strong) NSCache *responseCache;
@property (nonatomic, strong) NSMutableArray *orderedTransactions;
@property (nonatomic, strong) NSMutableDictionary *networkTransactionsForRequestIdentifiers;
@property (nonatomic, strong) dispatch_queue_t queue;

@end

@implementation FLEXNetworkRecorder

- (instancetype)init
{
    self = [super init];
    if (self) {
        self.responseCache = [[NSCache alloc] init];
        NSUInteger responseCacheLimit = [[[NSUserDefaults standardUserDefaults] objectForKey:kFLEXNetworkRecorderResponseCacheLimitDefaultsKey] unsignedIntegerValue];
        if (responseCacheLimit) {
            [self.responseCache setTotalCostLimit:responseCacheLimit];
        } else {
            // Default to 25 MB max. The cache will purge earlier if there is memory pressure.
            [self.responseCache setTotalCostLimit:25 * 1024 * 1024];
        }
        self.orderedTransactions = [NSMutableArray array];
        self.networkTransactionsForRequestIdentifiers = [NSMutableDictionary dictionary];

        // Serial queue used because we use mutable objects that are not thread safe
        self.queue = dispatch_queue_create("com.flex.FLEXNetworkRecorder", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

+ (instancetype)defaultRecorder
{
    static FLEXNetworkRecorder *defaultRecorder = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        defaultRecorder = [[[self class] alloc] init];
    });
    return defaultRecorder;
}

#pragma mark - Public Data Access

- (NSUInteger)responseCacheByteLimit
{
    return [self.responseCache totalCostLimit];
}

- (void)setResponseCacheByteLimit:(NSUInteger)responseCacheByteLimit
{
    [self.responseCache setTotalCostLimit:responseCacheByteLimit];
    [[NSUserDefaults standardUserDefaults] setObject:@(responseCacheByteLimit) forKey:kFLEXNetworkRecorderResponseCacheLimitDefaultsKey];
}

- (NSArray *)networkTransactions
{
    __block NSArray *transactions = nil;
    dispatch_sync(self.queue, ^{
        transactions = [self.orderedTransactions copy];
    });
    return transactions;
}

- (NSData *)cachedResponseBodyForTransaction:(FLEXNetworkTransaction *)transaction
{
    return [self.responseCache objectForKey:transaction.requestId];
}

- (void)clearRecordedActivity
{
    dispatch_async(self.queue, ^{
        [self.responseCache removeAllObjects];
        [self.orderedTransactions removeAllObjects];
        [self.networkTransactionsForRequestIdentifiers removeAllObjects];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:kFLEXNetworkRecorderTransactionsClearedNotification object:self];
        });
    });
}

#pragma mark - Network Events

- (void)recordRequestWillBeSentWithRequestId:(NSString *)requestId request:(NSURLRequest *)request redirectResponse:(NSURLResponse *)redirectResponse requestMechanism:(NSString *)mechanism
{
    if (redirectResponse) {
        [self recordResponseReceivedWithRequestId:requestId request:request response:redirectResponse];
        [self recordLoadingFinishedWithRequestId:requestId request:request responseBody:nil];
    }

    dispatch_async(self.queue, ^{
        FLEXNetworkTransaction *transaction = [self addOrRetrieveTransactionForRequestId:requestId request:request];
        transaction.transactionState = FLEXNetworkTransactionStateAwaitingResponse;
        transaction.requestMechanism = mechanism;

        [self postNewTransactionNotificationWithTransaction:transaction];
    });
}

- (void)recordResponseReceivedWithRequestId:(NSString *)requestId request:(NSURLRequest *)request response:(NSURLResponse *)response
{
    dispatch_async(self.queue, ^{
        FLEXNetworkTransaction *transaction = [self addOrRetrieveTransactionForRequestId:requestId request:request];
        transaction.response = response;
        transaction.transactionState = FLEXNetworkTransactionStateReceivingData;
        transaction.latency = -[transaction.startTime timeIntervalSinceNow];

        [self postUpdateNotificationForTransaction:transaction];
    });
}

- (void)recordDataReceivedWithRequestId:(NSString *)requestId request:(NSURLRequest *)request dataLength:(int64_t)dataLength
{
    dispatch_async(self.queue, ^{
        FLEXNetworkTransaction *transaction = [self addOrRetrieveTransactionForRequestId:requestId request:request];
        transaction.receivedDataLength += dataLength;

        [self postUpdateNotificationForTransaction:transaction];
    });
}

- (void)recordLoadingFinishedWithRequestId:(NSString *)requestId request:(NSURLRequest *)request responseBody:(NSData *)responseBody
{
    dispatch_async(self.queue, ^{
        FLEXNetworkTransaction *transaction = [self addOrRetrieveTransactionForRequestId:requestId request:request];
        transaction.transactionState = FLEXNetworkTransactionStateFinished;
        transaction.duration = -[transaction.startTime timeIntervalSinceNow];

        BOOL shouldCache = [responseBody length] > 0;
        if (!self.shouldCacheMediaResponses) {
            NSArray *ignoredMIMETypePrefixes = @[ @"audio", @"image", @"video" ];
            for (NSString *ignoredPrefix in ignoredMIMETypePrefixes) {
                shouldCache = shouldCache && ![transaction.response.MIMEType hasPrefix:ignoredPrefix];
            }
        }
        
        if (shouldCache) {
            [self.responseCache setObject:responseBody forKey:requestId cost:[responseBody length]];
        }

        NSString *mimeType = transaction.response.MIMEType;
        if ([mimeType hasPrefix:@"image/"]) {
            // Thumbnail image previews on a separate background queue
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                NSInteger maxPixelDimension = [[UIScreen mainScreen] scale] * 32.0;
                transaction.responseThumbnail = [FLEXUtility thumbnailedImageWithMaxPixelDimension:maxPixelDimension fromImageData:responseBody];
                [self postUpdateNotificationForTransaction:transaction];
            });
        } else if ([mimeType isEqual:@"application/json"]) {
            transaction.responseThumbnail = [FLEXResources jsonIcon];
        } else if ([mimeType isEqual:@"text/plain"]){
            transaction.responseThumbnail = [FLEXResources textPlainIcon];
        } else if ([mimeType isEqual:@"text/html"]) {
            transaction.responseThumbnail = [FLEXResources htmlIcon];
        } else if ([mimeType isEqual:@"application/x-plist"]) {
            transaction.responseThumbnail = [FLEXResources plistIcon];
        } else if ([mimeType isEqual:@"application/octet-stream"] || [mimeType isEqual:@"application/binary"]) {
            transaction.responseThumbnail = [FLEXResources binaryIcon];
        } else if ([mimeType rangeOfString:@"javascript"].length > 0) {
            transaction.responseThumbnail = [FLEXResources jsIcon];
        } else if ([mimeType rangeOfString:@"xml"].length > 0) {
            transaction.responseThumbnail = [FLEXResources xmlIcon];
        } else if ([mimeType hasPrefix:@"audio"]) {
            transaction.responseThumbnail = [FLEXResources audioIcon];
        } else if ([mimeType hasPrefix:@"video"]) {
            transaction.responseThumbnail = [FLEXResources videoIcon];
        } else if ([mimeType hasPrefix:@"text"]) {
            transaction.responseThumbnail = [FLEXResources textIcon];
        }
        
        [self postUpdateNotificationForTransaction:transaction];
    });
}

- (void)recordLoadingFailedWithRequestId:(NSString *)requestId request:(NSURLRequest *)request error:(NSError *)error
{
    dispatch_async(self.queue, ^{
        FLEXNetworkTransaction *transaction = [self addOrRetrieveTransactionForRequestId:requestId request:request];
        transaction.transactionState = FLEXNetworkTransactionStateFailed;
        transaction.duration = [transaction.startTime timeIntervalSinceNow];
        transaction.error = error;

        [self postUpdateNotificationForTransaction:transaction];
    });
}

/// Should only be called on the serial queue used in this class
- (FLEXNetworkTransaction *)addOrRetrieveTransactionForRequestId:(NSString *)requestId request:(NSURLRequest *)request
{
    FLEXNetworkTransaction *transaction = [self.networkTransactionsForRequestIdentifiers objectForKey:requestId];
    if (!transaction) {
        transaction = [[FLEXNetworkTransaction alloc] init];
        transaction.requestId = requestId;
        transaction.request = request;
        transaction.startTime = [NSDate date];

        [self.orderedTransactions insertObject:transaction atIndex:0];
        [self.networkTransactionsForRequestIdentifiers setObject:transaction forKey:requestId];
    }
    if (request) {
        transaction.request = request;
    }
    return transaction;
}

#pragma mark Notification Posting

- (void)postNewTransactionNotificationWithTransaction:(FLEXNetworkTransaction *)transaction
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *userInfo = @{ kFLEXNetworkRecorderUserInfoTransactionKey : transaction };
        [[NSNotificationCenter defaultCenter] postNotificationName:kFLEXNetworkRecorderNewTransactionNotification object:self userInfo:userInfo];
    });
}

- (void)postUpdateNotificationForTransaction:(FLEXNetworkTransaction *)transaction
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *userInfo = @{ kFLEXNetworkRecorderUserInfoTransactionKey : transaction };
        [[NSNotificationCenter defaultCenter] postNotificationName:kFLEXNetworkRecorderTransactionUpdatedNotification object:self userInfo:userInfo];
    });
}

@end
