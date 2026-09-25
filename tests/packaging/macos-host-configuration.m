// SPDX-License-Identifier: GPL-3.0-or-later
#import "host-configuration.h"
#include <assert.h>
static NSDictionary *parse(NSString *text) { return PLANKMacParseHostConfiguration([text dataUsingEncoding:NSUTF8StringEncoding]); }
int main(void) { @autoreleasepool {
    assert([parse(@"# Defaults\n")[@"Port"] isEqual:@28989]);
    NSDictionary *config = parse(@"; comment\r\n[general]\r\nhost_name = Example Host\r\n[network]\r\nport = 30000\r\n");
    assert([config[@"Name"] isEqual:@"Example Host"] && [config[@"Port"] isEqual:@30000]);
    assert([config[@"Address"] isEqual:@"0.0.0.0"] && config.count == 3);
    assert([parse(@"[general]\nhost_name = Écran 🎬 #1\n")[@"Name"] isEqual:@"Écran 🎬 #1"]);
    for (NSString *port in @[@"", @"0", @"65536", @"-1", @"true", @"28989.5", @"+80", @"1 2", @"1#comment", @"１２"])
        assert(!parse([@"[network]\nport = " stringByAppendingString:port]));
    for (NSString *text in @[@"", @"port = 80", @"[network]\nport=1\nport=2", @"[general]\nhost_name = ",
        @"[network]\nbind_address=127.0.0.1", @"[state]\nUUID=bad", @"[network]\nport=1\n[network]\nport=2",
        @"[general]\nhost_name=x\tq", @"[general]\nhost_name=x\x01", @"[general]junk\nhost_name=x"])
        assert(!parse(text));
    assert(!PLANKMacParseHostConfiguration([NSData dataWithBytes:"#x\0y" length:4]));
    assert(!PLANKMacParseHostConfiguration([NSData dataWithBytes:"\xff" length:1]));
    assert(!PLANKMacParseHostConfiguration([NSMutableData dataWithLength:32769]));
    assert(!parse([@"[general]\nhost_name = " stringByAppendingString:[@"x" stringByPaddingToLength:256 withString:@"x" startingAtIndex:0]]));
    puts("host_ini_parser=pass");
    return 0;
} }
