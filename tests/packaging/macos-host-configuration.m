// SPDX-License-Identifier: GPL-3.0-or-later
#import "host-configuration.h"
#include <assert.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>

// Only this test executable substitutes the OS lookup. Production has no test
// environment override, and no fixture changes the machine's actual hostname.
static const char *testHostName = "workstation-a";
static unsigned int hostnameCalls;
static BOOL unterminatedHostName;
int gethostname(char *name, size_t length) {
    hostnameCalls++;
    if (!testHostName) { errno = EIO; return -1; }
    if (unterminatedHostName) { memset(name, 'x', length); return 0; }
    if (strlen(testHostName) >= length) { errno = ENAMETOOLONG; return -1; }
    memcpy(name, testHostName, strlen(testHostName) + 1);
    return 0;
}

static NSDictionary *parse(NSString *text) { return PLANKMacParseHostConfiguration([text dataUsingEncoding:NSUTF8StringEncoding]); }
int main(void) { @autoreleasepool {
    assert([parse(@"# Defaults\n")[@"Name"] isEqual:@"workstation-a"]);
    assert(hostnameCalls == 1);
    testHostName = "workstation-b.example.test";
    assert([parse(@"[general]\n# host_name = workstation-name\n")[@"Name"] isEqual:@"workstation-b.example.test"]);
    assert(hostnameCalls == 2); // Resolve again on configuration reload, never cache the installer name.
    assert([parse(@"[general]\nhost_name = Custom Host\n")[@"Name"] isEqual:@"Custom Host"]);
    assert([parse(@"[general]\nhost_name = PLANK Mac Host\n")[@"Name"] isEqual:@"PLANK Mac Host"]);
    assert(hostnameCalls == 2); // Explicit overrides always win, including the old generic label.
    for (const char **candidate = (const char *[]){"", "bad\nname", "bad\x01", "\xff", NULL}; *candidate; candidate++) {
        testHostName = *candidate;
        assert([parse(@"# Defaults\n")[@"Name"] isEqual:@"PLANK"]);
    }
    testHostName = NULL;
    assert([parse(@"# Defaults\n")[@"Name"] isEqual:@"PLANK"]);
    assert([parse(@"[general]\nhost_name = Still Custom\n")[@"Name"] isEqual:@"Still Custom"]);
    char longestName[257];
    memset(longestName, 'x', sizeof(longestName));
    longestName[255] = '\0'; testHostName = longestName;
    assert([parse(@"# Defaults\n")[@"Name"] length] == 255);
    longestName[255] = 'x'; longestName[256] = '\0';
    assert([parse(@"# Defaults\n")[@"Name"] isEqual:@"PLANK"]);
    unterminatedHostName = YES;
    assert([parse(@"# Defaults\n")[@"Name"] isEqual:@"PLANK"]);
    unterminatedHostName = NO; testHostName = "workstation-a";
    assert([parse(@"# Defaults\n")[@"Port"] isEqual:@28989]);
    NSDictionary *config = parse(@"; comment\r\n[general]\r\nhost_name = Example Host\r\n[network]\r\nport = 30000\r\n");
    assert([config[@"Name"] isEqual:@"Example Host"] && [config[@"Port"] isEqual:@30000]);
    assert([config[@"Address"] isEqual:@"0.0.0.0"] && config.count == 5);
    assert([config[@"PingTimeoutMs"] isEqual:@10000] && [config[@"PublishSessionUser"] isEqual:@NO]);
    for (NSString *timeout in @[@"200", @"201", @"10000", @"30000", @"120000"]) {
        NSDictionary *custom = parse([@"[network]\nping_timeout = " stringByAppendingString:timeout]);
        assert([custom[@"PingTimeoutMs"] unsignedIntValue] == (uint32_t)timeout.integerValue);
        assert([custom[@"Port"] isEqual:@28989]);
    }
    for (NSString *timeout in @[@"", @"0", @"-1", @"100", @"199", @"120001", @"4294967296", @"1e4",
                               @"10000.0", @"+10000", @"true", @"１２３４", @"10000 # comment", @"1 000"])
        assert(!parse([@"[network]\nping_timeout = " stringByAppendingString:timeout]));
    for (NSString *flag in @[@"true", @"false"]) {
        NSDictionary *custom = parse([@"[security]\npublish_session_user = " stringByAppendingString:flag]);
        assert([custom[@"PublishSessionUser"] isEqual:@([flag isEqual:@"true"])]);
    }
    for (NSString *flag in @[@"", @"1", @"0", @"yes", @"True", @"FALSE", @"\"true\"", @"true # comment"])
        assert(!parse([@"[security]\npublish_session_user = " stringByAppendingString:flag]));
    for (NSString *text in @[@"[network]\npublish_session_user=true", @"[security]\nping_timeout=10000",
                            @"[network]\nping_timeout=200\nping_timeout=300",
                            @"[security]\npublish_session_user=true\npublish_session_user=false"])
        assert(!parse(text));
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
