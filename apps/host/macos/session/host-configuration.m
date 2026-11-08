// SPDX-License-Identifier: GPL-3.0-or-later
#import "host-configuration.h"
#import "configuration-files.h"
#include "host-network-policy.h"
#include <string.h>

static BOOL validHostName(NSString *name) {
    return name.length && [name lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= 255 &&
        [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}

static NSString *systemHostName(void) {
    // Local OS lookup only: no reverse DNS, user account name or cached installer
    // value. Match Linux's fallback if the OS cannot supply a usable hostname.
    char name[256] = {0};
    if (gethostname(name, sizeof(name)) || !memchr(name, '\0', sizeof(name))) return @"PLANK";
    NSString *result = [NSString stringWithUTF8String:name];
    return validHostName(result) ? result : @"PLANK";
}

static BOOL metricsNumber(NSString *value, NSInteger minimum, NSInteger maximum) {
    return value.length && value.length <= 5 && [value rangeOfCharacterFromSet:
        [[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet]].location == NSNotFound &&
        value.integerValue >= minimum && value.integerValue <= maximum;
}

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
            if (![section isEqual:@"general"] && ![section isEqual:@"network"] &&
                ![section isEqual:@"security"] && ![section isEqual:@"metrics"]) return nil;
            continue;
        }
        NSRange separator = [line rangeOfString:@"="];
        if (separator.location == NSNotFound) return nil;
        NSString *key = [[line substringToIndex:separator.location] stringByTrimmingCharactersInSet:spaces];
        NSString *value = [[line substringFromIndex:separator.location + 1] stringByTrimmingCharactersInSet:spaces];
        key = [NSString stringWithFormat:@"%@.%@", section, key];
        if ((![key isEqual:@"general.host_name"] && ![key isEqual:@"network.port"] &&
             ![key isEqual:@"network.ping_timeout"] && ![key isEqual:@"general.mirror_host_displays"] &&
             ![key isEqual:@"security.publish_session_user"] && ![key isEqual:@"metrics.metrics_enabled"] &&
             ![key isEqual:@"metrics.metrics_port"] && ![key isEqual:@"metrics.metrics_interval_seconds"]) || values[key]) return nil;
        values[key] = value;
    }
    NSString *name = values[@"general.host_name"] ?: systemHostName();
    if (!validHostName(name)) return nil;
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
    NSString *mirrorHostDisplays = values[@"general.mirror_host_displays"] ?: @"false";
    if (![mirrorHostDisplays isEqual:@"true"] && ![mirrorHostDisplays isEqual:@"false"]) return nil;
    NSString *metricsEnabled = values[@"metrics.metrics_enabled"] ?: @"false";
    NSString *metricsPort = values[@"metrics.metrics_port"] ?: @"28991";
    NSString *metricsInterval = values[@"metrics.metrics_interval_seconds"] ?: @"1";
    BOOL metricsValid = ([metricsEnabled isEqual:@"true"] || [metricsEnabled isEqual:@"false"]) &&
        metricsNumber(metricsPort, 1024, 65535) && metricsNumber(metricsInterval, 1, 60);
    // Optional observability must never prevent access to the workstation.
    NSDictionary *metrics = @{@"Enabled": @(metricsValid && [metricsEnabled isEqual:@"true"]),
        @"Port": @(metricsValid ? metricsPort.integerValue : 28991),
        @"IntervalSeconds": @(metricsValid ? metricsInterval.integerValue : 1), @"Valid": @(metricsValid)};
    // Listening on all interfaces is product policy, not a second configuration key.
    return @{@"Address": @"0.0.0.0", @"Name": name, @"Port": @(port.integerValue),
             @"MirrorHostDisplays": @([mirrorHostDisplays isEqual:@"true"]), @"PingTimeoutMs": @(timeout.integerValue),
             @"Metrics": metrics, @"PublishSessionUser": @([publishUser isEqual:@"true"])};
}

NSString *PLANKMacReadWorkstationUUID(NSData *data) {
    id state = data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL] : nil;
    if (![state isKindOfClass:NSDictionary.class] || [state count] != 1 ||
        ![state[@"UUID"] isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:state[@"UUID"]]) return nil;
    return state[@"UUID"];
}

BOOL PLANKMacHostConfigurationValidForStartup(NSDictionary *config) {
    // The parser validates administrator keys and supplies optional defaults.
    // Validate the values needed to start the listener, not the total number
    // of parsed settings: adding optional metrics must not block access.
    return [config isKindOfClass:NSDictionary.class] &&
        [config[@"Address"] isKindOfClass:NSString.class] &&
        [config[@"Name"] isKindOfClass:NSString.class] &&
        [config[@"UUID"] isKindOfClass:NSString.class] &&
        [config[@"Port"] isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)config[@"Port"]) != CFBooleanGetTypeID() &&
        [config[@"Port"] doubleValue] == [config[@"Port"] unsignedShortValue] &&
        [config[@"Port"] unsignedShortValue] != 0;
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
