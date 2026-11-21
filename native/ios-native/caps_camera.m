// camera: take one picture with the system camera, or scan a QR/barcode with a
// live camera preview. Both write only inside the engine's own filesystem view;
// neither adds anything to the user's photo library.
#import "dsh_ios_native.h"
#import "DshNativeBridge.h"
#import "root.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

static NSString *const kCameraDirectory = @"/home/dsh/.ios/camera";

static dispatch_queue_t camera_queue(void) {
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    queue = dispatch_queue_create("com.wsw.dsh-ios.camera",
                                  dispatch_queue_attr_make_with_qos_class(
                                    DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
  });
  return queue;
}

static void ensure_camera(void (^next)(BOOL granted, NSString *error)) {
  AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
  if (status == AVAuthorizationStatusAuthorized) {
    next(YES, nil);
    return;
  }
  if (status == AVAuthorizationStatusNotDetermined) {
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
      dsh_native_on_main(^{
        next(granted, granted ? nil : @"camera access was refused. The user can allow it in Settings > Privacy & Security > Camera.");
      });
    }];
    return;
  }
  next(NO, @"camera access is off for this app. The user can turn it on in Settings > Privacy & Security > Camera.");
}

/// The engine path for a file the native side just wrote, round-tripped so the
/// caller never receives a path it cannot open.
static NSString *engine_path(NSString *realFile) {
  char virtual[4096], back[4096];
  const char *real = realFile.fileSystemRepresentation;
  if (dsh_root_virtual(real, virtual, sizeof virtual) != 0) return nil;
  if (dsh_root_real(virtual, back, sizeof back) != 0) return nil;
  if (strcmp(back, real) != 0) return nil;
  return @(virtual);
}

static BOOL prepare_camera_directory(NSString **realDirectory, NSString **error) {
  char real[4096];
  if (dsh_root_real(kCameraDirectory.fileSystemRepresentation, real, sizeof real) != 0) {
    *error = @"the engine's workspace is not available, so the picture has nowhere to go";
    return NO;
  }
  NSError *createError = nil;
  if (![NSFileManager.defaultManager createDirectoryAtPath:@(real)
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&createError]) {
    *error = createError.localizedDescription ?: @"the camera directory could not be created";
    return NO;
  }
  *realDirectory = @(real);
  return YES;
}

static NSString *timestamp_name(void) {
  static NSDateFormatter *formatter;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";
  });
  return [NSString stringWithFormat:@"camera-%@.jpg", [formatter stringFromDate:NSDate.date]];
}

#pragma mark - One still picture

@interface DshCameraCaptureSession : NSObject <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@property (nonatomic, copy) DshNativeReply reply;
@property (nonatomic) BOOL answered;
@end

@implementation DshCameraCaptureSession

- (void)imagePickerController:(UIImagePickerController *)picker
    didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
  if (self.answered) return;
  self.answered = YES;
  UIImage *image = info[UIImagePickerControllerOriginalImage];
  DshNativeReply reply = self.reply;
  self.reply = nil;
  [picker dismissViewControllerAnimated:YES completion:nil];
  if (![image isKindOfClass:UIImage.class]) {
    reply(nil, @"the camera returned no picture");
    return;
  }
  dispatch_async(camera_queue(), ^{
    NSString *directory = nil, *prepareError = nil;
    if (!prepare_camera_directory(&directory, &prepareError)) {
      reply(nil, prepareError);
      return;
    }
    NSData *jpeg = UIImageJPEGRepresentation(image, 0.9);
    if (jpeg == nil) {
      reply(nil, @"the picture could not be encoded as JPEG");
      return;
    }
    NSString *real = [directory stringByAppendingPathComponent:timestamp_name()];
    NSError *writeError = nil;
    if (![jpeg writeToFile:real options:NSDataWritingAtomic error:&writeError]) {
      reply(nil, writeError.localizedDescription ?: @"the picture could not be written");
      return;
    }
    NSString *path = engine_path(real);
    if (path == nil) {
      reply(nil, @"the picture did not land at a path the engine can open");
      return;
    }
    reply(@{
      @"path": path,
      @"bytes": @(jpeg.length),
      @"width": @((NSInteger) (image.size.width * image.scale)),
      @"height": @((NSInteger) (image.size.height * image.scale)),
      @"cancelled": @NO,
    }, nil);
  });
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
  if (self.answered) return;
  self.answered = YES;
  DshNativeReply reply = self.reply;
  self.reply = nil;
  [picker dismissViewControllerAnimated:YES completion:nil];
  if (reply) reply(@{@"cancelled": @YES}, nil);
}

@end

static DshCameraCaptureSession *sCaptureSession;

static void capture_picture(DshNativeReply reply) {
  if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera]) {
    reply(nil, @"this device has no camera available to the app");
    return;
  }
  ensure_camera(^(BOOL granted, NSString *error) {
    if (!granted) {
      reply(nil, error);
      return;
    }
    dsh_native_on_main(^{
      id<DshNativeBridging> bridge = DshNativeCurrentBridge();
      if (bridge == nil) {
        reply(nil, @"the app cannot show the camera right now");
        return;
      }
      if (sCaptureSession != nil) {
        reply(nil, @"the camera is already open and waiting for the user");
        return;
      }
      DshCameraCaptureSession *session = [DshCameraCaptureSession new];
      session.reply = reply;
      UIImagePickerController *picker = [UIImagePickerController new];
      picker.sourceType = UIImagePickerControllerSourceTypeCamera;
      picker.mediaTypes = @[@"public.image"];
      picker.allowsEditing = NO;
      picker.delegate = session;
      sCaptureSession = session;
      [bridge presentSystemController:picker failure:^(NSString *message) {
        sCaptureSession = nil;
        reply(nil, message);
      } gone:^{
        if (!session.answered) {
          session.answered = YES;
          reply(@{@"cancelled": @YES}, nil);
        }
        sCaptureSession = nil;
      }];
    });
  });
}

#pragma mark - Live scanner

@interface DshCameraScanController : UIViewController <AVCaptureMetadataOutputObjectsDelegate>
@property (nonatomic) AVCaptureSession *session;
@property (nonatomic) AVCaptureVideoPreviewLayer *preview;
@property (nonatomic) UILabel *hint;
@property (nonatomic, copy) void (^completion)(NSDictionary *result, NSString *error);
@property (nonatomic) BOOL answered;
@property (nonatomic) BOOL started;
@end

@implementation DshCameraScanController

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = UIColor.blackColor;
  self.modalPresentationStyle = UIModalPresentationFullScreen;

  self.hint = [UILabel new];
  self.hint.text = @"对准二维码或条形码";
  self.hint.textColor = UIColor.whiteColor;
  self.hint.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
  self.hint.textAlignment = NSTextAlignmentCenter;
  self.hint.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:self.hint];

  UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
  [cancel setTitle:@"取消" forState:UIControlStateNormal];
  cancel.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
  cancel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
  cancel.layer.cornerRadius = 22;
  cancel.translatesAutoresizingMaskIntoConstraints = NO;
  [cancel addTarget:self action:@selector(cancel:) forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:cancel];

  [NSLayoutConstraint activateConstraints:@[
    [self.hint.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
    [self.hint.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
    [self.hint.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:24],
    [cancel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
    [cancel.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-28],
    [cancel.widthAnchor constraintEqualToConstant:120],
    [cancel.heightAnchor constraintEqualToConstant:44],
  ]];

  AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
  if (device == nil) return;
  NSError *error = nil;
  AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
  if (input == nil) return;
  AVCaptureSession *session = [AVCaptureSession new];
  AVCaptureMetadataOutput *output = [AVCaptureMetadataOutput new];
  [session beginConfiguration];
  if ([session canAddInput:input]) [session addInput:input];
  if ([session canAddOutput:output]) [session addOutput:output];
  [session commitConfiguration];
  [output setMetadataObjectsDelegate:self queue:dispatch_get_main_queue()];

  NSArray<NSString *> *wanted = @[
    AVMetadataObjectTypeQRCode,
    AVMetadataObjectTypeEAN13Code,
    AVMetadataObjectTypeEAN8Code,
    AVMetadataObjectTypeCode128Code,
    AVMetadataObjectTypeCode39Code,
    AVMetadataObjectTypeCode93Code,
    AVMetadataObjectTypeUPCECode,
    AVMetadataObjectTypePDF417Code,
    AVMetadataObjectTypeAztecCode,
    AVMetadataObjectTypeDataMatrixCode,
    AVMetadataObjectTypeInterleaved2of5Code,
    AVMetadataObjectTypeITF14Code,
  ];
  NSMutableArray<NSString *> *supported = [NSMutableArray array];
  for (NSString *type in wanted) {
    if ([output.availableMetadataObjectTypes containsObject:type]) [supported addObject:type];
  }
  output.metadataObjectTypes = supported.count > 0 ? supported : @[AVMetadataObjectTypeQRCode];

  self.session = session;
  self.preview = [AVCaptureVideoPreviewLayer layerWithSession:session];
  self.preview.videoGravity = AVLayerVideoGravityResizeAspectFill;
  [self.view.layer insertSublayer:self.preview atIndex:0];
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  self.preview.frame = self.view.bounds;
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  if (self.started || self.session == nil) return;
  self.started = YES;
  AVCaptureSession *session = self.session;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    [session startRunning];
  });
}

- (void)viewWillDisappear:(BOOL)animated {
  [super viewWillDisappear:animated];
  AVCaptureSession *session = self.session;
  if (session != nil && session.isRunning) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      [session stopRunning];
    });
  }
}

- (void)cancel:(UIButton *)sender {
  [self finish:@{@"cancelled": @YES} error:nil];
}

- (void)captureOutput:(AVCaptureOutput *)output
    didOutputMetadataObjects:(NSArray<AVMetadataObject *> *)metadataObjects
              fromConnection:(AVCaptureConnection *)connection {
  if (self.answered) return;
  for (AVMetadataObject *object in metadataObjects) {
    if (![object isKindOfClass:AVMetadataMachineReadableCodeObject.class]) continue;
    AVMetadataMachineReadableCodeObject *code = (AVMetadataMachineReadableCodeObject *) object;
    if (code.stringValue.length == 0) continue;
    [self finish:@{@"value": code.stringValue, @"type": code.type, @"cancelled": @NO} error:nil];
    return;
  }
}

- (void)finish:(NSDictionary *)result error:(NSString *)error {
  if (self.answered) return;
  self.answered = YES;
  AVCaptureSession *session = self.session;
  if (session != nil && session.isRunning) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      [session stopRunning];
    });
  }
  void (^done)(NSDictionary *, NSString *) = self.completion;
  self.completion = nil;
  [self dismissViewControllerAnimated:YES completion:^{
    if (done) done(result, error);
  }];
}

@end

static DshCameraScanController *sScanController;

static void scan_codes(DshNativeReply reply) {
  if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera]) {
    reply(nil, @"this device has no camera available to the app");
    return;
  }
  ensure_camera(^(BOOL granted, NSString *error) {
    if (!granted) {
      reply(nil, error);
      return;
    }
    dsh_native_on_main(^{
      id<DshNativeBridging> bridge = DshNativeCurrentBridge();
      if (bridge == nil) {
        reply(nil, @"the app cannot show the camera right now");
        return;
      }
      if (sScanController != nil) {
        reply(nil, @"the camera is already open and waiting for the user");
        return;
      }
      DshCameraScanController *controller = [DshCameraScanController new];
      controller.completion = reply;
      sScanController = controller;
      [bridge presentSystemController:controller failure:^(NSString *message) {
        sScanController = nil;
        reply(nil, message);
      } gone:^{
        if (!controller.answered) {
          controller.answered = YES;
          reply(@{@"cancelled": @YES}, nil);
        }
        sScanController = nil;
      }];
    });
  });
}

void DshCameraGrantAccess(void (^done)(BOOL granted, NSString *error)) {
  ensure_camera(done);
}

void dsh_native_camera(NSString *op, NSDictionary *args, DshNativeReply reply) {
  if ([op isEqualToString:@"capture"]) { capture_picture(reply); return; }
  if ([op isEqualToString:@"scan"]) { scan_codes(reply); return; }
  reply(nil, [NSString stringWithFormat:@"camera has no operation '%@'", op]);
}
