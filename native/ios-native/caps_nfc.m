// nfc: read one NDEF tag with the system's NFC sheet. Reading only; the user
// holds the phone to the tag and can cancel. CoreNFC requires the
// `com.apple.developer.nfc.readersession.formats` entitlement and a short usage
// description in Info.plist, both added in app/project.yml.
#import "dsh_ios_native.h"
#import <CoreNFC/CoreNFC.h>

@interface DshNFCSession : NSObject <NFCNDEFReaderSessionDelegate>
@property (nonatomic, copy) DshNativeReply reply;
@property (nonatomic) BOOL answered;
@end

static DshNFCSession *sNFCSession;

@implementation DshNFCSession

- (void)readerSession:(NFCNDEFReaderSession *)session didDetectNDEFs:(NSArray<NFCNDEFMessage *> *)messages {
  if (self.answered) return;
  self.answered = YES;
  NSMutableArray *records = [NSMutableArray array];
  for (NFCNDEFMessage *message in messages) {
    for (NFCNDEFPayload *payload in message.records) {
      NSMutableDictionary *entry = [@{
        @"typeNameFormat": @(payload.typeNameFormat),
        @"type": [[NSString alloc] initWithData:payload.type encoding:NSUTF8StringEncoding] ?: @"",
        @"identifier": [[NSString alloc] initWithData:payload.identifier encoding:NSUTF8StringEncoding] ?: @"",
        @"payload": [payload.payload base64EncodedStringWithOptions:0],
      } mutableCopy];
      NSString *text = [self textFor:payload];
      if (text.length > 0) entry[@"text"] = text;
      NSString *uri = [self uriFor:payload];
      if (uri.length > 0) entry[@"uri"] = uri;
      [records addObject:entry];
    }
  }
  DshNativeReply reply = self.reply;
  self.reply = nil;
  [session invalidateSession];
  sNFCSession = nil;
  if (reply) reply(@{@"records": records, @"count": @(records.count), @"cancelled": @NO}, nil);
}

- (void)readerSession:(NFCNDEFReaderSession *)session didInvalidateWithError:(NSError *)error {
  if (self.answered) return;
  self.answered = YES;
  DshNativeReply reply = self.reply;
  self.reply = nil;
  sNFCSession = nil;
  if (error.code == NFCReaderErrorReaderSessionInvalidationErrorUserCanceled) {
    if (reply) reply(@{@"cancelled": @YES, @"records": @[]}, nil);
    return;
  }
  if (reply) reply(nil, error.localizedDescription ?: @"the NFC session ended");
}

- (NSString *)textFor:(NFCNDEFPayload *)payload {
  if (payload.typeNameFormat != NFCTypeNameFormatNFCWellKnown) return nil;
  NSString *type = [[NSString alloc] initWithData:payload.type encoding:NSUTF8StringEncoding];
  if (![type isEqualToString:@"T"]) return nil;
  NSData *data = payload.payload;
  if (data.length < 1) return nil;
  const uint8_t *bytes = data.bytes;
  uint8_t status = bytes[0];
  NSUInteger languageLength = status & 0x3F;
  if (data.length < 1 + languageLength) return nil;
  NSData *textData = [data subdataWithRange:NSMakeRange(1 + languageLength, data.length - 1 - languageLength)];
  return [[NSString alloc] initWithData:textData encoding:NSUTF8StringEncoding];
}

- (NSString *)uriFor:(NFCNDEFPayload *)payload {
  if (payload.typeNameFormat != NFCTypeNameFormatNFCWellKnown) return nil;
  NSString *type = [[NSString alloc] initWithData:payload.type encoding:NSUTF8StringEncoding];
  if (![type isEqualToString:@"U"]) return nil;
  NSData *data = payload.payload;
  if (data.length < 1) return nil;
  const uint8_t *bytes = data.bytes;
  static NSString *const prefixes[] = {
    @"", @"http://www.", @"https://www.", @"http://", @"https://", @"tel:", @"mailto:",
    @"ftp://anonymous:anonymous@", @"ftp://ftp.", @"ftps://", @"sftp://", @"smb://",
    @"nfs://", @"ftp://", @"dav://", @"news:", @"telnet://", @"imap:", @"rtsp://",
    @"urn:", @"pop:", @"sip:", @"sips:", @"tftp:", @"btspp://", @"btl2cap://",
    @"btgoep://", @"tcpobex://", @"irdaobex://", @"file://", @"urn:epc:id:",
    @"urn:epc:tag:", @"urn:epc:pat:", @"urn:epc:raw:", @"urn:epc:", @"urn:nfc:",
  };
  uint8_t prefix = bytes[0];
  if (prefix >= sizeof(prefixes) / sizeof(prefixes[0])) return nil;
  NSData *rest = [data subdataWithRange:NSMakeRange(1, data.length - 1)];
  NSString *suffix = [[NSString alloc] initWithData:rest encoding:NSUTF8StringEncoding];
  return suffix.length > 0 ? [prefixes[prefix] stringByAppendingString:suffix] : nil;
}

@end

void dsh_native_nfc(NSString *op, NSDictionary *args, DshNativeReply reply) {
  if (![op isEqualToString:@"scan"]) {
    reply(nil, [NSString stringWithFormat:@"nfc has no operation '%@'", op]);
    return;
  }
  if (![NFCNDEFReaderSession readingAvailable]) {
    reply(nil, @"NFC reading is not available on this device, or this build is not entitled for it");
    return;
  }
  if (sNFCSession != nil) {
    reply(nil, @"an NFC scan is already waiting for a tag");
    return;
  }
  NSString *message = args[@"message"];
  if (message != nil && ![message isKindOfClass:NSString.class]) message = nil;
  dsh_native_on_main(^{
    DshNFCSession *session = [DshNFCSession new];
    session.reply = reply;
    NFCNDEFReaderSession *reader =
      [[NFCNDEFReaderSession alloc] initWithDelegate:session
                                               queue:dispatch_get_main_queue()
                            invalidateAfterFirstRead:YES];
    if (message.length > 0) reader.alertMessage = message;
    sNFCSession = session;
    [reader beginSession];
  });
}
