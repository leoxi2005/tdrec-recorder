//
//  SyphonBridge.h
//  Cầu nối Objective-C giữa Syphon.framework và Swift.
//
//  Syphon là framework Objective-C thuần; SPM không import trực tiếp một
//  .framework vào target Swift được, nên ta bọc lại phần API cần dùng ở đây
//  rồi Swift import module `SyphonBridge`.
//

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

/// Mô tả một Syphon server đang phát trên máy.
@interface TDSyphonServer : NSObject
@property (nonatomic, copy) NSString *serverName;   // tên sender, vd "wall"
@property (nonatomic, copy) NSString *appName;      // vd "TouchDesigner"
@property (nonatomic, copy) NSString *uuid;
/// Chuỗi hiển thị "appName — serverName"
@property (nonatomic, readonly) NSString *displayName;
@end


/// Client nhận texture từ một Syphon server bằng Metal (zero-copy qua IOSurface).
@interface TDSyphonClient : NSObject

/// Liệt kê mọi server Syphon đang chạy.
+ (NSArray<TDSyphonServer *> *)availableServers;

/// Đăng ký callback khi danh sách server thay đổi (server mới xuất hiện / biến mất).
+ (void)observeServerChanges:(void (^)(void))handler;

/// Tạo client. `handler` được gọi trên thread của Syphon mỗi khi server publish
/// một frame mới — KHÔNG block trong handler này.
///
/// @param uuid   UUID của server (lấy từ +availableServers)
/// @param device Metal device dùng để tạo texture
/// @param handler nhận MTLTexture của frame mới (chỉ hợp lệ trong phạm vi callback)
- (nullable instancetype)initWithServerUUID:(NSString *)uuid
                                     device:(id<MTLDevice>)device
                                    handler:(void (^)(id<MTLTexture> texture))handler;

/// Ngắt kết nối và giải phóng tài nguyên. An toàn khi gọi nhiều lần.
- (void)stop;

@property (nonatomic, readonly, getter=isValid) BOOL valid;

@end


/// Server Syphon — chỉ dùng cho bộ tự kiểm tra, để giả lập TouchDesigner
/// publish frame mà không cần mở TD thật.
@interface TDSyphonPublisher : NSObject
- (nullable instancetype)initWithName:(NSString *)name device:(id<MTLDevice>)device;
- (void)publishTexture:(id<MTLTexture>)texture;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
