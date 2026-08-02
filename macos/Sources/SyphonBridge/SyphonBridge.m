//
//  SyphonBridge.m
//

#import "SyphonBridge.h"
#import <Syphon/Syphon.h>

#pragma mark - TDSyphonServer

@implementation TDSyphonServer
- (NSString *)displayName {
    NSString *app = self.appName.length ? self.appName : @"?";
    NSString *srv = self.serverName.length ? self.serverName : @"(default)";
    return [NSString stringWithFormat:@"%@ — %@", app, srv];
}
@end


#pragma mark - TDSyphonClient

@implementation TDSyphonClient {
    SyphonMetalClient *_client;
}

+ (NSArray<TDSyphonServer *> *)availableServers {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *d in [[SyphonServerDirectory sharedDirectory] servers]) {
        TDSyphonServer *s = [TDSyphonServer new];
        s.serverName = d[SyphonServerDescriptionNameKey]    ?: @"";
        s.appName    = d[SyphonServerDescriptionAppNameKey] ?: @"";
        s.uuid       = d[SyphonServerDescriptionUUIDKey]    ?: @"";
        [out addObject:s];
    }
    return out;
}

+ (void)observeServerChanges:(void (^)(void))handler {
    void (^fire)(NSNotification *) = ^(NSNotification *n) { handler(); };
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserverForName:SyphonServerAnnounceNotification object:nil
                     queue:[NSOperationQueue mainQueue] usingBlock:fire];
    [nc addObserverForName:SyphonServerRetireNotification object:nil
                     queue:[NSOperationQueue mainQueue] usingBlock:fire];
    [nc addObserverForName:SyphonServerUpdateNotification object:nil
                     queue:[NSOperationQueue mainQueue] usingBlock:fire];
}

- (nullable instancetype)initWithServerUUID:(NSString *)uuid
                                     device:(id<MTLDevice>)device
                                    handler:(void (^)(id<MTLTexture>))handler {
    self = [super init];
    if (!self) return nil;

    // Tìm lại description đầy đủ theo UUID — SyphonMetalClient cần nguyên dict này.
    NSDictionary *desc = nil;
    for (NSDictionary *d in [[SyphonServerDirectory sharedDirectory] servers]) {
        if ([d[SyphonServerDescriptionUUIDKey] isEqualToString:uuid]) { desc = d; break; }
    }
    if (!desc) return nil;

    __weak typeof(self) weakSelf = self;
    _client = [[SyphonMetalClient alloc] initWithServerDescription:desc
                                                            device:device
                                                           options:nil
                                                   newFrameHandler:^(SyphonMetalClient *c) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        // newFrameImage trả về texture của frame hiện tại. Texture này thuộc
        // pool nội bộ của Syphon và sẽ bị ghi đè bởi frame kế tiếp, nên phía
        // Swift phải blit sang buffer riêng NGAY trong callback.
        id<MTLTexture> tex = [c newFrameImage];
        if (tex) handler(tex);
    }];

    return _client ? self : nil;
}

- (BOOL)isValid { return _client != nil && _client.isValid; }

- (void)stop {
    [_client stop];
    _client = nil;
}

- (void)dealloc { [_client stop]; }

@end


#pragma mark - TDSyphonPublisher

@implementation TDSyphonPublisher {
    SyphonMetalServer *_server;
    id<MTLCommandQueue> _queue;
}

- (nullable instancetype)initWithName:(NSString *)name device:(id<MTLDevice>)device {
    self = [super init];
    if (!self) return nil;
    _queue = [device newCommandQueue];
    _server = [[SyphonMetalServer alloc] initWithName:name device:device options:nil];
    return _server ? self : nil;
}

- (void)publishTexture:(id<MTLTexture>)texture {
    id<MTLCommandBuffer> cmd = [_queue commandBuffer];
    [_server publishFrameTexture:texture
                   onCommandBuffer:cmd
                         imageRegion:NSMakeRect(0, 0, texture.width, texture.height)
                              flipped:NO];
    [cmd commit];
}

- (void)stop { [_server stop]; _server = nil; }
- (void)dealloc { [_server stop]; }

@end
