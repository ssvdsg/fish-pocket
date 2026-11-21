// bluetooth: scan for nearby BLE peripherals, connect, list characteristics,
// read and write. One central manager is kept for the app's lifetime so a
// connection survives between tool calls.
//
// iOS asks for Bluetooth permission the first time a central manager is used;
// there is no separate "request" API. Every call therefore goes through the
// same manager, and a call made while Bluetooth is off says so instead of
// waiting forever.
#import "dsh_ios_native.h"
#import <CoreBluetooth/CoreBluetooth.h>

static NSString *const kTimeoutKey = @"timeout";

@interface DshBluetooth : NSObject <CBCentralManagerDelegate, CBPeripheralDelegate>
@property (nonatomic) CBCentralManager *central;
@property (nonatomic) NSMutableDictionary<NSUUID *, CBPeripheral *> *peripherals;
@property (nonatomic) NSMutableDictionary<NSUUID *, NSDictionary *> *advertisements;
@property (nonatomic) NSMutableArray *ready;
@property (nonatomic, copy) void (^scanReply)(NSDictionary *, NSString *);
@property (nonatomic) NSMutableDictionary<NSUUID *, NSDictionary *> *found;
@property (nonatomic) NSMutableDictionary *connects;
@property (nonatomic) NSMutableDictionary *characteristics;
@property (nonatomic) NSMutableDictionary *reads;
@property (nonatomic) NSMutableDictionary *writes;
@property (nonatomic) NSMutableDictionary *notifies;
@end

@implementation DshBluetooth

@synthesize central = _central;

+ (instancetype)shared {
  static DshBluetooth *shared;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    shared = [DshBluetooth new];
    shared.peripherals = [NSMutableDictionary dictionary];
    shared.advertisements = [NSMutableDictionary dictionary];
    shared.ready = [NSMutableArray array];
    shared.found = [NSMutableDictionary dictionary];
    shared.connects = [NSMutableDictionary dictionary];
    shared.characteristics = [NSMutableDictionary dictionary];
    shared.reads = [NSMutableDictionary dictionary];
    shared.writes = [NSMutableDictionary dictionary];
    shared.notifies = [NSMutableDictionary dictionary];
  });
  return shared;
}

- (CBCentralManager *)central {
  if (_central == nil) {
    _central = [[CBCentralManager alloc] initWithDelegate:self
                                                   queue:dispatch_get_main_queue()
                                                 options:@{CBCentralManagerOptionShowPowerAlertKey: @YES}];
  }
  return _central;
}

- (NSString *)stateError {
  switch (self.central.state) {
    case CBManagerStateUnsupported:
      return @"Bluetooth LE is not supported on this device";
    case CBManagerStateUnauthorized:
      return @"Bluetooth access is off for this app. The user can allow it in Settings > Privacy & Security > Bluetooth.";
    case CBManagerStatePoweredOff:
      return @"Bluetooth is off. Ask the user to turn it on in Control Center or Settings.";
    default:
      return @"Bluetooth is not ready yet; try again in a moment";
  }
}

- (void)ensureReady:(void (^)(NSString *error))next {
  CBCentralManager *central = self.central;
  if (central.state == CBManagerStatePoweredOn) {
    next(nil);
    return;
  }
  if (central.state == CBManagerStateUnknown || central.state == CBManagerStateResetting) {
    [self.ready addObject:[next copy]];
    return;
  }
  next([self stateError]);
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
  NSArray<void (^)(NSString *)> *waiting = [self.ready copy];
  [self.ready removeAllObjects];
  NSString *error = central.state == CBManagerStatePoweredOn ? nil : [self stateError];
  for (void (^next)(NSString *) in waiting) next(error);
}

- (CBPeripheral *)peripheral:(NSString *)identifier error:(NSString **)error {
  NSUUID *uuid = identifier.length > 0 ? [[NSUUID alloc] initWithUUIDString:identifier] : nil;
  if (uuid == nil) {
    *error = [NSString stringWithFormat:@"'%@' is not a peripheral identifier", identifier];
    return nil;
  }
  CBPeripheral *peripheral = self.peripherals[uuid];
  if (peripheral == nil) {
    NSArray<CBPeripheral *> *known = [self.central retrievePeripheralsWithIdentifiers:@[uuid]];
    peripheral = known.firstObject;
    if (peripheral != nil) self.peripherals[uuid] = peripheral;
  }
  if (peripheral == nil) *error = @"that peripheral is not known any more; scan again";
  return peripheral;
}

- (CBService *)service:(NSString *)wanted on:(CBPeripheral *)peripheral error:(NSString **)error {
  for (CBService *service in peripheral.services) {
    if ([service.UUID.UUIDString caseInsensitiveCompare:wanted] == NSOrderedSame) return service;
  }
  *error = [NSString stringWithFormat:@"service %@ is not on this peripheral; connect first or discover its services", wanted];
  return nil;
}

- (CBCharacteristic *)characteristic:(NSString *)wanted in:(CBService *)service error:(NSString **)error {
  for (CBCharacteristic *characteristic in service.characteristics) {
    if ([characteristic.UUID.UUIDString caseInsensitiveCompare:wanted] == NSOrderedSame) return characteristic;
  }
  *error = [NSString stringWithFormat:@"characteristic %@ is not on service %@; call characteristics first", wanted, service.UUID.UUIDString];
  return nil;
}

- (NSString *)key:(CBPeripheral *)peripheral characteristic:(CBCharacteristic *)characteristic {
  return [NSString stringWithFormat:@"%@|%@", peripheral.identifier.UUIDString, characteristic.UUID.UUIDString];
}

- (void)timeout:(NSTimeInterval)seconds block:(dispatch_block_t)block {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) (seconds * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), block);
}

@end

#pragma mark - JSON helpers

static NSDictionary *service_summary(CBService *service) {
  NSMutableArray *characteristics = [NSMutableArray array];
  for (CBCharacteristic *characteristic in service.characteristics) {
    NSMutableDictionary *entry = [@{
      @"uuid": characteristic.UUID.UUIDString,
      @"read": @((characteristic.properties & CBCharacteristicPropertyRead) != 0),
      @"write": @((characteristic.properties & CBCharacteristicPropertyWrite) != 0),
      @"writeWithoutResponse": @((characteristic.properties & CBCharacteristicPropertyWriteWithoutResponse) != 0),
      @"notify": @((characteristic.properties & CBCharacteristicPropertyNotify) != 0),
      @"indicate": @((characteristic.properties & CBCharacteristicPropertyIndicate) != 0),
    } mutableCopy];
    if (characteristic.value != nil) entry[@"value"] = characteristic.value.description;
    [characteristics addObject:entry];
  }
  return @{@"uuid": service.UUID.UUIDString, @"characteristics": characteristics};
}

static NSDictionary *data_summary(NSData *data) {
  if (data == nil) return @{};
  NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];
  const uint8_t *bytes = data.bytes;
  for (NSUInteger i = 0; i < data.length; i++) [hex appendFormat:@"%02x", bytes[i]];
  return @{
    @"hex": hex,
    @"base64": [data base64EncodedStringWithOptions:0],
    @"length": @(data.length),
  };
}

static NSData *data_from_args(NSDictionary *args, NSString **error) {
  NSString *hex = args[@"hex"];
  NSString *base64 = args[@"base64"];
  NSString *text = args[@"text"];
  int given = (hex.length > 0 ? 1 : 0) + (base64.length > 0 ? 1 : 0) + (text.length > 0 ? 1 : 0);
  if (given != 1) {
    *error = @"write needs exactly one of 'hex', 'base64' or 'text'";
    return nil;
  }
  if (text.length > 0) return [text dataUsingEncoding:NSUTF8StringEncoding];
  if (base64.length > 0) {
    NSData *data = [[NSData alloc] initWithBase64EncodedString:base64 options:0];
    if (data == nil) *error = @"'base64' is not valid base64";
    return data;
  }
  if (hex.length % 2 != 0) {
    *error = @"'hex' must have an even number of digits";
    return nil;
  }
  NSMutableData *data = [NSMutableData dataWithCapacity:hex.length / 2];
  for (NSUInteger i = 0; i < hex.length; i += 2) {
    NSString *pair = [hex substringWithRange:NSMakeRange(i, 2)];
    unsigned int value = 0;
    if (![[NSScanner scannerWithString:pair] scanHexInt:&value]) {
      *error = [NSString stringWithFormat:@"'%@' is not hexadecimal", pair];
      return nil;
    }
    uint8_t byte = (uint8_t) value;
    [data appendBytes:&byte length:1];
  }
  return data;
}

#pragma mark - Operations

static void bluetooth_state(DshNativeReply reply) {
  DshBluetooth *bluetooth = DshBluetooth.shared;
  [bluetooth ensureReady:^(NSString *error) {
    if (error != nil) {
      reply(nil, error);
      return;
    }
    reply(@{@"state": @"poweredOn", @"authorized": @YES}, nil);
  }];
}

static void bluetooth_scan(NSDictionary *args, DshNativeReply reply) {
  DshBluetooth *bluetooth = DshBluetooth.shared;
  [bluetooth ensureReady:^(NSString *error) {
    if (error != nil) {
      reply(nil, error);
      return;
    }
    if (bluetooth.scanReply != nil) {
      reply(nil, @"a Bluetooth scan is already running");
      return;
    }
    NSNumber *secondsArg = args[@"seconds"];
    double seconds = [secondsArg isKindOfClass:NSNumber.class] ? secondsArg.doubleValue : 5;
    seconds = MAX(1, MIN(30, seconds));
    NSArray *services = args[@"services"];
    NSMutableArray<CBUUID *> *uuids = nil;
    if ([services isKindOfClass:NSArray.class] && services.count > 0) {
      uuids = [NSMutableArray array];
      for (NSString *service in services) {
        if (![service isKindOfClass:NSString.class] || service.length == 0) continue;
        [uuids addObject:[CBUUID UUIDWithString:service]];
      }
    }
    [bluetooth.found removeAllObjects];
    bluetooth.scanReply = reply;
    [bluetooth.central scanForPeripheralsWithServices:(uuids.count > 0 ? uuids : nil)
                                              options:@{CBCentralManagerScanOptionAllowDuplicatesKey: @NO}];
    [bluetooth timeout:seconds block:^{
      if (bluetooth.scanReply == nil) return;
      [bluetooth.central stopScan];
      void (^done)(NSDictionary *, NSString *) = bluetooth.scanReply;
      bluetooth.scanReply = nil;
      NSArray *values = [bluetooth.found.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"rssi"] compare:a[@"rssi"]];
      }];
      done(@{@"peripherals": values, @"count": @(values.count)}, nil);
    }];
  }];
}

static void bluetooth_connect(NSDictionary *args, DshNativeReply reply) {
  DshBluetooth *bluetooth = DshBluetooth.shared;
  [bluetooth ensureReady:^(NSString *error) {
    if (error != nil) {
      reply(nil, error);
      return;
    }
    NSString *identifier = args[@"id"];
    if (![identifier isKindOfClass:NSString.class] || identifier.length == 0) {
      reply(nil, @"connect needs the peripheral 'id' from scan");
      return;
    }
    NSString *lookup = nil;
    CBPeripheral *peripheral = [bluetooth peripheral:identifier error:&lookup];
    if (peripheral == nil) {
      reply(nil, lookup);
      return;
    }
    NSNumber *timeoutArg = args[@"timeout"];
    double timeout = [timeoutArg isKindOfClass:NSNumber.class] ? timeoutArg.doubleValue : 10;
    timeout = MAX(1, MIN(30, timeout));
    peripheral.delegate = bluetooth;
    NSUUID *uuid = peripheral.identifier;
    if (peripheral.state == CBPeripheralStateConnected) {
      if (peripheral.services.count > 0) {
        NSMutableArray *services = [NSMutableArray array];
        for (CBService *service in peripheral.services) [services addObject:service.UUID.UUIDString];
        reply(@{@"connected": @YES, @"id": uuid.UUIDString, @"services": services}, nil);
      } else {
        if (bluetooth.connects[uuid] != nil) {
          reply(nil, @"a connection to that peripheral is already in progress");
          return;
        }
        bluetooth.connects[uuid] = [reply copy];
        [bluetooth timeout:timeout block:^{
          void (^done)(NSDictionary *, NSString *) = bluetooth.connects[uuid];
          if (done == nil) return;
          [bluetooth.connects removeObjectForKey:uuid];
          done(nil, @"discovering services timed out");
        }];
        [peripheral discoverServices:nil];
      }
      return;
    }
    if (bluetooth.connects[uuid] != nil) {
      reply(nil, @"a connection to that peripheral is already in progress");
      return;
    }
    bluetooth.peripherals[uuid] = peripheral;
    peripheral.delegate = bluetooth;
    bluetooth.connects[uuid] = [reply copy];
    [bluetooth timeout:timeout block:^{
      void (^done)(NSDictionary *, NSString *) = bluetooth.connects[uuid];
      if (done == nil) return;
      [bluetooth.connects removeObjectForKey:uuid];
      [bluetooth.central cancelPeripheralConnection:peripheral];
      done(nil, @"the connection timed out");
    }];
    [bluetooth.central connectPeripheral:peripheral options:nil];
  }];
}

static void bluetooth_disconnect(NSDictionary *args, DshNativeReply reply) {
  DshBluetooth *bluetooth = DshBluetooth.shared;
  NSString *identifier = args[@"id"];
  NSString *error = nil;
  CBPeripheral *peripheral = [bluetooth peripheral:identifier error:&error];
  if (peripheral == nil) {
    reply(nil, error);
    return;
  }
  [bluetooth.central cancelPeripheralConnection:peripheral];
  reply(@{@"disconnected": @YES, @"id": peripheral.identifier.UUIDString}, nil);
}

static void bluetooth_characteristics(NSDictionary *args, DshNativeReply reply) {
  DshBluetooth *bluetooth = DshBluetooth.shared;
  NSString *error = nil;
  CBPeripheral *peripheral = [bluetooth peripheral:args[@"id"] error:&error];
  if (peripheral == nil) {
    reply(nil, error);
    return;
  }
  CBService *service = [bluetooth service:args[@"service"] on:peripheral error:&error];
  if (service == nil) {
    reply(nil, error);
    return;
  }
  if (service.characteristics.count > 0) {
    reply(service_summary(service), nil);
    return;
  }
  NSString *key = [NSString stringWithFormat:@"%@|%@", peripheral.identifier.UUIDString, service.UUID.UUIDString];
  if (bluetooth.characteristics[key] != nil) {
    reply(nil, @"characteristics for that service are already being discovered");
    return;
  }
  bluetooth.characteristics[key] = [reply copy];
  [bluetooth timeout:10 block:^{
    void (^done)(NSDictionary *, NSString *) = bluetooth.characteristics[key];
    if (done == nil) return;
    [bluetooth.characteristics removeObjectForKey:key];
    done(nil, @"discovering characteristics timed out");
  }];
  [peripheral discoverCharacteristics:nil forService:service];
}

static void bluetooth_read(NSDictionary *args, DshNativeReply reply) {
  DshBluetooth *bluetooth = DshBluetooth.shared;
  NSString *error = nil;
  CBPeripheral *peripheral = [bluetooth peripheral:args[@"id"] error:&error];
  if (peripheral == nil) {
    reply(nil, error);
    return;
  }
  CBService *service = [bluetooth service:args[@"service"] on:peripheral error:&error];
  if (service == nil) {
    reply(nil, error);
    return;
  }
  CBCharacteristic *characteristic = [bluetooth characteristic:args[@"characteristic"] in:service error:&error];
  if (characteristic == nil) {
    reply(nil, error);
    return;
  }
  NSString *key = [bluetooth key:peripheral characteristic:characteristic];
  if (bluetooth.reads[key] != nil) {
    reply(nil, @"a read of that characteristic is already pending");
    return;
  }
  bluetooth.reads[key] = [reply copy];
  [bluetooth timeout:10 block:^{
    void (^done)(NSDictionary *, NSString *) = bluetooth.reads[key];
    if (done == nil) return;
    [bluetooth.reads removeObjectForKey:key];
    done(nil, @"reading the characteristic timed out");
  }];
  [peripheral readValueForCharacteristic:characteristic];
}

static void bluetooth_write(NSDictionary *args, DshNativeReply reply) {
  DshBluetooth *bluetooth = DshBluetooth.shared;
  NSString *error = nil;
  CBPeripheral *peripheral = [bluetooth peripheral:args[@"id"] error:&error];
  if (peripheral == nil) {
    reply(nil, error);
    return;
  }
  CBService *service = [bluetooth service:args[@"service"] on:peripheral error:&error];
  if (service == nil) {
    reply(nil, error);
    return;
  }
  CBCharacteristic *characteristic = [bluetooth characteristic:args[@"characteristic"] in:service error:&error];
  if (characteristic == nil) {
    reply(nil, error);
    return;
  }
  NSData *data = data_from_args(args, &error);
  if (data == nil) {
    reply(nil, error);
    return;
  }
  BOOL withoutResponse = [args[@"withoutResponse"] isKindOfClass:NSNumber.class] && [args[@"withoutResponse"] boolValue];
  CBCharacteristicWriteType type = withoutResponse ? CBCharacteristicWriteWithoutResponse : CBCharacteristicWriteWithResponse;
  NSString *key = [bluetooth key:peripheral characteristic:characteristic];
  if (bluetooth.writes[key] != nil) {
    reply(nil, @"a write to that characteristic is already pending");
    return;
  }
  bluetooth.writes[key] = [reply copy];
  [bluetooth timeout:10 block:^{
    void (^done)(NSDictionary *, NSString *) = bluetooth.writes[key];
    if (done == nil) return;
    [bluetooth.writes removeObjectForKey:key];
    done(nil, @"writing the characteristic timed out");
  }];
  [peripheral writeValue:data forCharacteristic:characteristic type:type];
}

static void bluetooth_notify(NSDictionary *args, DshNativeReply reply) {
  DshBluetooth *bluetooth = DshBluetooth.shared;
  NSString *error = nil;
  CBPeripheral *peripheral = [bluetooth peripheral:args[@"id"] error:&error];
  if (peripheral == nil) {
    reply(nil, error);
    return;
  }
  CBService *service = [bluetooth service:args[@"service"] on:peripheral error:&error];
  if (service == nil) {
    reply(nil, error);
    return;
  }
  CBCharacteristic *characteristic = [bluetooth characteristic:args[@"characteristic"] in:service error:&error];
  if (characteristic == nil) {
    reply(nil, error);
    return;
  }
  BOOL enabled = [args[@"enabled"] isKindOfClass:NSNumber.class] ? [args[@"enabled"] boolValue] : YES;
  NSString *key = [bluetooth key:peripheral characteristic:characteristic];
  if (bluetooth.notifies[key] != nil) {
    reply(nil, @"a notification change for that characteristic is already pending");
    return;
  }
  bluetooth.notifies[key] = [reply copy];
  [bluetooth timeout:10 block:^{
    void (^done)(NSDictionary *, NSString *) = bluetooth.notifies[key];
    if (done == nil) return;
    [bluetooth.notifies removeObjectForKey:key];
    done(nil, @"changing notifications timed out");
  }];
  [peripheral setNotifyValue:enabled forCharacteristic:characteristic];
}

void dsh_native_bluetooth(NSString *op, NSDictionary *args, DshNativeReply reply) {
  if ([op isEqualToString:@"state"]) { bluetooth_state(reply); return; }
  if ([op isEqualToString:@"scan"]) { bluetooth_scan(args, reply); return; }
  if ([op isEqualToString:@"connect"]) { bluetooth_connect(args, reply); return; }
  if ([op isEqualToString:@"disconnect"]) { bluetooth_disconnect(args, reply); return; }
  if ([op isEqualToString:@"characteristics"]) { bluetooth_characteristics(args, reply); return; }
  if ([op isEqualToString:@"read"]) { bluetooth_read(args, reply); return; }
  if ([op isEqualToString:@"write"]) { bluetooth_write(args, reply); return; }
  if ([op isEqualToString:@"notify"]) { bluetooth_notify(args, reply); return; }
  reply(nil, [NSString stringWithFormat:@"bluetooth has no operation '%@'", op]);
}

#pragma mark - Delegate

@implementation DshBluetooth (Delegate)

- (void)centralManager:(CBCentralManager *)central
 didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary<NSString *, id> *)advertisementData
                  RSSI:(NSNumber *)RSSI {
  NSUUID *uuid = peripheral.identifier;
  self.peripherals[uuid] = peripheral;
  self.advertisements[uuid] = advertisementData;
  NSString *name = peripheral.name ?: advertisementData[CBAdvertisementDataLocalNameKey];
  NSMutableArray *services = [NSMutableArray array];
  for (CBUUID *service in advertisementData[CBAdvertisementDataServiceUUIDsKey]) {
    [services addObject:service.UUIDString];
  }
  self.found[uuid] = @{
    @"id": uuid.UUIDString,
    @"name": name.length > 0 ? name : @"(unnamed)",
    @"rssi": RSSI ?: @0,
    @"services": services,
  };
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
  peripheral.delegate = self;
  [peripheral discoverServices:nil];
}

- (void)centralManager:(CBCentralManager *)central
didFailToConnectPeripheral:(CBPeripheral *)peripheral
                 error:(NSError *)error {
  void (^done)(NSDictionary *, NSString *) = self.connects[peripheral.identifier];
  [self.connects removeObjectForKey:peripheral.identifier];
  if (done) done(nil, error.localizedDescription ?: @"the connection failed");
}

- (void)centralManager:(CBCentralManager *)central
didDisconnectPeripheral:(CBPeripheral *)peripheral
                 error:(NSError *)error {
  // A later call can reconnect; the peripheral stays in the table.
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
  void (^done)(NSDictionary *, NSString *) = self.connects[peripheral.identifier];
  if (done == nil) return;
  [self.connects removeObjectForKey:peripheral.identifier];
  if (error != nil) {
    done(nil, error.localizedDescription ?: @"discovering services failed");
    return;
  }
  NSMutableArray *services = [NSMutableArray array];
  for (CBService *service in peripheral.services) [services addObject:service.UUID.UUIDString];
  done(@{@"connected": @YES, @"id": peripheral.identifier.UUIDString, @"services": services}, nil);
}

- (void)peripheral:(CBPeripheral *)peripheral
didDiscoverCharacteristicsForService:(CBService *)service
             error:(NSError *)error {
  NSString *key = [NSString stringWithFormat:@"%@|%@", peripheral.identifier.UUIDString, service.UUID.UUIDString];
  void (^done)(NSDictionary *, NSString *) = self.characteristics[key];
  if (done == nil) return;
  [self.characteristics removeObjectForKey:key];
  if (error != nil) {
    done(nil, error.localizedDescription ?: @"discovering characteristics failed");
    return;
  }
  done(service_summary(service), nil);
}

- (void)peripheral:(CBPeripheral *)peripheral
didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
  NSString *key = [self key:peripheral characteristic:characteristic];
  void (^done)(NSDictionary *, NSString *) = self.reads[key];
  if (done == nil) return;
  [self.reads removeObjectForKey:key];
  if (error != nil) {
    done(nil, error.localizedDescription ?: @"reading the characteristic failed");
    return;
  }
  NSMutableDictionary *result = [data_summary(characteristic.value) mutableCopy];
  result[@"characteristic"] = characteristic.UUID.UUIDString;
  done(result, nil);
}

- (void)peripheral:(CBPeripheral *)peripheral
didWriteValueForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
  NSString *key = [self key:peripheral characteristic:characteristic];
  void (^done)(NSDictionary *, NSString *) = self.writes[key];
  if (done == nil) return;
  [self.writes removeObjectForKey:key];
  if (error != nil) {
    done(nil, error.localizedDescription ?: @"writing the characteristic failed");
    return;
  }
  done(@{@"written": @YES, @"characteristic": characteristic.UUID.UUIDString}, nil);
}

- (void)peripheral:(CBPeripheral *)peripheral
didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
  NSString *key = [self key:peripheral characteristic:characteristic];
  void (^done)(NSDictionary *, NSString *) = self.notifies[key];
  if (done == nil) return;
  [self.notifies removeObjectForKey:key];
  if (error != nil) {
    done(nil, error.localizedDescription ?: @"changing notifications failed");
    return;
  }
  done(@{@"notifying": @(characteristic.isNotifying), @"characteristic": characteristic.UUID.UUIDString}, nil);
}

@end
