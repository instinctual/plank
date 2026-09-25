// SPDX-License-Identifier: GPL-3.0-or-later
#import "server-information.h"

static BOOL publicText(NSString *value, NSUInteger maximum) {
    if (!value.length || [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > maximum) return NO;
    for (NSUInteger index = 0; index < value.length; ++index) {
        unichar c = [value characterAtIndex:index];
        if (c < 32 || c == 127 || c == 0xfffe || c == 0xffff) return NO;
    }
    return [value canBeConvertedToEncoding:NSUTF8StringEncoding];
}

// Same optional metadata-v1 spelling as Linux and the Client. Reject, rather
// than replace, unsupported characters; this is not an authentication identity.
static NSString *publicSessionUser(NSString *name) {
    if (!name.length || name.length > 256) return nil;
    NSRange realm = [name rangeOfString:@"@"];
    if (realm.location != NSNotFound) name = [name substringToIndex:realm.location];
    if (!name.length || name.length > 64) return nil;
    for (NSUInteger index = 0; index < name.length; ++index) {
        unichar c = [name characterAtIndex:index];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-')) return nil;
    }
    return [name copy];
}

@implementation PLANKMacServerInformation {
    NSString *_name;
    NSUUID *_uuid;
    NSString *_version;
    BOOL _streaming;
    BOOL _occupied;
    NSString *_sessionUser;
}

- (instancetype)initWithName:(NSString *)name workstationUUID:(NSUUID *)uuid version:(NSString *)version {
    return [self initWithName:name workstationUUID:uuid version:version streaming:NO occupied:NO sessionUser:nil];
}
- (instancetype)initWithName:(NSString *)name workstationUUID:(NSUUID *)uuid version:(NSString *)version
                  streaming:(BOOL)streaming {
    return [self initWithName:name workstationUUID:uuid version:version streaming:streaming occupied:NO sessionUser:nil];
}
- (instancetype)initWithName:(NSString *)name workstationUUID:(NSUUID *)uuid version:(NSString *)version
                  streaming:(BOOL)streaming occupied:(BOOL)occupied sessionUser:(NSString *)sessionUser {
    if (!uuid || !publicText(name, 255) || !publicText(version, 128)) return nil;
    uuid_t bytes;
    [uuid getUUIDBytes:bytes];
    const uuid_t zero = {0};
    if (!memcmp(bytes, zero, sizeof(bytes))) return nil;
    self = [super init];
    if (self) {
        _name = [name copy];
        _uuid = [uuid copy];
        _version = [version copy];
        _streaming = streaming;
        _occupied = occupied;
        _sessionUser = occupied ? publicSessionUser(sessionUser) : nil;
    }
    return self;
}

- (NSData *)XMLForControlPort:(uint16_t)port {
    return [self XMLForControlPort:port authorized:NO];
}
- (NSData *)XMLForControlPort:(uint16_t)port authorized:(BOOL)authorized {
    return [self XMLForControlPort:port authorized:authorized streamOccupied:NO];
}
- (NSData *)XMLForControlPort:(uint16_t)port authorized:(BOOL)authorized
               streamOccupied:(BOOL)streamOccupied {
    if (!port) return nil;
    NSXMLElement *root = [NSXMLElement elementWithName:@"root"];
    [root addAttribute:[NSXMLNode attributeWithName:@"status_code" stringValue:@"200"]];
    // Explicit zero is essential: an omitted codec mask makes the current
    // Client assume H.264. No media capability is advertised until native
    // stream claim, exact format negotiation and lifetime revocation exist.
    NSArray *fields = @[
        @[@"hostname", _name], @[@"uniqueid", _uuid.UUIDString.lowercaseString],
        @[@"HttpsPort", [NSString stringWithFormat:@"%u", port]],
        @[@"PlankHostMetadataVersion", @"1"], @[@"PlankHostVersion", _version],
        @[@"PlankAuth", @"1"], @[@"ServerCodecModeSupport", _streaming ? @"1049088" : @"0"],
        @[@"PlankTopologyVersion", _streaming ? @"13" : @"0"],
        @[@"PlankFeatureFlags", _streaming ? @"7897201" : @"0"],
        @[@"PairStatus", authorized ? @"1" : @"0"],
        @[@"PlankOccupied", (_occupied || streamOccupied) ? @"1" : @"0"]
    ];
    for (NSArray *field in fields)
        [root addChild:[NSXMLNode elementWithName:field[0] stringValue:field[1]]];
    if (_sessionUser)
        [root addChild:[NSXMLNode elementWithName:@"PlankSessionUser" stringValue:_sessionUser]];
    return [[[NSXMLDocument alloc] initWithRootElement:root] XMLData];
}
@end

BOOL PLANKMacIsServerInformationTarget(NSString *target) { return [target isEqual:@"/serverinfo"]; }
BOOL PLANKMacIsTopologyTarget(NSString *target) { return [target isEqual:@"/plank/topology"]; }
BOOL PLANKMacIsDesktopTarget(NSString *target) { return [target isEqual:@"/applist"]; }
