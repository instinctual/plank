// SPDX-License-Identifier: GPL-3.0-or-later
#import "host-configuration.h"
#import "configuration-files.h"
#include "host-network-policy.h"

NSDictionary *PLANKMacParseHostConfiguration(NSData *data) {
    if (!data.length || data.length > 32768) return nil;
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text || [text rangeOfString:@"\0"].location != NSNotFound) return nil;
    NSMutableDictionary *values = [NSMutableDictionary new];
    NSString *section = @"";
    NSCharacterSet *spaces = NSCharacterSet.whitespaceCharacterSet;
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:spaces];
        if (!line.length || [line hasPrefix:@"#"] || [line hasPrefix:@";"]) continue;
        if ([line hasPrefix:@"["] && [line hasSuffix:@"]"]) {
            section = [line substringWithRange:NSMakeRange(1, line.length - 2)];
            if (![section isEqual:@"general"] && ![section isEqual:@"network"] && ![section isEqual:@"security"]) return nil;
            continue;
        }
        NSRange separator = [line rangeOfString:@"="];
        if (separator.location == NSNotFound) return nil;
        NSString *key = [[line substringToIndex:separator.location] stringByTrimmingCharactersInSet:spaces];
        NSString *value = [[line substringFromIndex:separator.location + 1] stringByTrimmingCharactersInSet:spaces];
        key = [NSString stringWithFormat:@"%@.%@", section, key];
        if ((![key isEqual:@"general.host_name"] && ![key isEqual:@"network.port"] &&
             ![key isEqual:@"network.ping_timeout"] && ![key isEqual:@"security.publish_session_user"]) || values[key]) return nil;
        values[key] = value;
    }
    NSString *name = values[@"general.host_name"] ?: @"PLANK Mac Host";
    if (!name.length || [name lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 255 ||
        [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return nil;
    NSString *port = values[@"network.port"] ?: @"28989";
    if (!port.length || port.length > 5 || [port rangeOfCharacterFromSet:
        [[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet]].location != NSNotFound ||
        port.integerValue < 1 || port.integerValue > 65535) return nil;
    NSString *timeout = values[@"network.ping_timeout"] ?: @(PLANKMacDefaultPingTimeoutMs).stringValue;
    if (!timeout.length || timeout.length > 6 || [timeout rangeOfCharacterFromSet:
        [[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet]].location != NSNotFound ||
        !plank_macos_valid_ping_timeout((uint32_t)timeout.integerValue)) return nil;
    NSString *publishUser = values[@"security.publish_session_user"] ?: @"false";
    if (![publishUser isEqual:@"true"] && ![publishUser isEqual:@"false"]) return nil;
    // Listening on all interfaces is product policy, not a second configuration key.
    return @{@"Address": @"0.0.0.0", @"Name": name, @"Port": @(port.integerValue),
             @"PingTimeoutMs": @(timeout.integerValue), @"PublishSessionUser": @([publishUser isEqual:@"true"])};
}

NSString *PLANKMacReadWorkstationUUID(NSData *data) {
    id state = data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL] : nil;
    if (![state isKindOfClass:NSDictionary.class] || [state count] != 1 ||
        ![state[@"UUID"] isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:state[@"UUID"]]) return nil;
    return state[@"UUID"];
}

NSDictionary *PLANKMacReadHostConfiguration(NSString *configDirectory, NSString *stateDirectory,
                                           uid_t owner, BOOL privateFixture) {
    mode_t directoryMode = privateFixture ? 0700 : 0755, fileMode = privateFixture ? 0600 : 0644;
    int configFD = plank_config_directory(configDirectory, owner, directoryMode, NO);
    int stateFD = plank_config_directory(stateDirectory, owner, directoryMode, NO);
    NSData *ini = configFD >= 0 ? plank_config_read(configFD, "host.conf", owner, fileMode) : nil;
    NSData *identity = stateFD >= 0 ? plank_config_read(stateFD, "identity.plist", owner, fileMode) : nil;
    if (configFD >= 0) close(configFD);
    if (stateFD >= 0) close(stateFD);
    NSDictionary *config = PLANKMacParseHostConfiguration(ini);
    NSString *uuid = PLANKMacReadWorkstationUUID(identity);
    if (!config || !uuid) return nil;
    NSMutableDictionary *result = [config mutableCopy];
    result[@"UUID"] = uuid;
    // Standalone synthetic-account qualification must never expose its test
    // listener beyond loopback. Installed workers always listen on all interfaces.
    if (privateFixture) result[@"Address"] = @"127.0.0.1";
    return result;
}
