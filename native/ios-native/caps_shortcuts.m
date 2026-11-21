// shortcuts: run one of the user's Shortcuts by name.
//
// The system has no public API to run a shortcut silently, and that is a good
// thing: the Shortcuts URL scheme opens the Shortcuts app, which may ask the
// user before anything runs. This tool therefore reports that the shortcut was
// handed to Shortcuts, not that it finished; a caller that needs the result
// should ask the user or read the screen through phone control.
#import "dsh_ios_native.h"
#import <UIKit/UIKit.h>

void dsh_native_shortcuts(NSString *op, NSDictionary *args, DshNativeReply reply) {
  if (![op isEqualToString:@"run"]) {
    reply(nil, [NSString stringWithFormat:@"shortcuts has no operation '%@'", op]);
    return;
  }
  NSString *name = args[@"name"];
  if (![name isKindOfClass:NSString.class] || name.length == 0) {
    reply(nil, @"shortcuts run needs a non-empty 'name'");
    return;
  }
  NSString *input = args[@"input"];
  if (input != nil && ![input isKindOfClass:NSString.class]) {
    reply(nil, @"shortcuts 'input' must be text");
    return;
  }

  NSURLComponents *components = [NSURLComponents componentsWithString:@"shortcuts://run-shortcut"];
  NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
  [items addObject:[NSURLQueryItem queryItemWithName:@"name" value:name]];
  if (input.length > 0) [items addObject:[NSURLQueryItem queryItemWithName:@"input" value:input]];
  components.queryItems = items;
  NSURL *target = components.URL;
  if (target == nil) {
    reply(nil, @"the shortcut name could not be turned into a URL");
    return;
  }

  dsh_native_on_main(^{
    [UIApplication.sharedApplication openURL:target options:@{} completionHandler:^(BOOL opened) {
      if (opened) {
        reply(@{@"started": @YES, @"name": name}, nil);
      } else {
        reply(nil, @"Shortcuts did not open. Is the Shortcuts app installed?");
      }
    }];
  });
}
