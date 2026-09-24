// SPDX-License-Identifier: GPL-3.0-or-later
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <assert.h>
#import "server-information.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return 2;
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:@"f92140f5-8740-4b3b-82f7-74db5353de27"];
        NSMutableString *name = [@"Test <Mac> & desktop" mutableCopy];
        PLANKMacServerInformation *info = [[PLANKMacServerInformation alloc]
            initWithName:name workstationUUID:uuid version:@"1.0.0-macos-host"];
        assert(info);
        [name setString:@"Changed after construction"];
        assert(![info XMLForControlPort:0]);
        NSData *xml = [info XMLForControlPort:28987];
        assert([xml isEqual:[info XMLForControlPort:28987]]);
        NSXMLDocument *document = [[NSXMLDocument alloc] initWithData:xml options:0 error:NULL];
        NSXMLElement *root = document.rootElement;
        assert([root.name isEqual:@"root"]);
        assert([[root attributeForName:@"status_code"].stringValue isEqual:@"200"]);
        NSDictionary *expected = @{
            @"hostname": @"Test <Mac> & desktop", @"uniqueid": uuid.UUIDString.lowercaseString,
            @"HttpsPort": @"28987", @"PlankHostMetadataVersion": @"1", @"PlankHostVersion": @"1.0.0-macos-host",
            @"PlankAuth": @"1", @"ServerCodecModeSupport": @"0", @"PlankTopologyVersion": @"0",
            @"PlankFeatureFlags": @"0", @"PairStatus": @"0", @"PlankOccupied": @"0"
        };
        // Exact public-field allowlist: occupancy is a nameless 0/1 bit.
        // Adding owner, username, UID, or topology data must still fail.
        assert(root.childCount == expected.count);
        for (NSString *key in expected) {
            NSArray<NSXMLElement *> *nodes = [root elementsForName:key];
            assert(nodes.count == 1 && [nodes.firstObject.stringValue isEqual:expected[key]]);
        }
        assert(![[PLANKMacServerInformation alloc] initWithName:@"test" workstationUUID:nil version:@"test"]);
        assert(![[PLANKMacServerInformation alloc] initWithName:@"test" workstationUUID:
            [[NSUUID alloc] initWithUUIDString:@"00000000-0000-0000-0000-000000000000"] version:@"test"]);
        for (NSString *bad in @[@"", @"bad\nline", @"bad\rline", @"bad\tname",
                [@"x" stringByPaddingToLength:256 withString:@"x" startingAtIndex:0]]) {
            assert(![[PLANKMacServerInformation alloc] initWithName:bad workstationUUID:uuid version:@"test"]);
            assert(![[PLANKMacServerInformation alloc] initWithName:@"test" workstationUUID:uuid version:bad]);
        }
        for (NSString *target in @[@"/serverinfo"]) {
            assert(PLANKMacIsServerInformationTarget(target));
        }
        assert(PLANKMacIsTopologyTarget(@"/plank/topology"));
        assert(PLANKMacIsDesktopTarget(@"/applist"));
        assert(!PLANKMacIsTopologyTarget(@"/plank/topology?uniqueid=0123456789ABCDEF"));
        assert(!PLANKMacIsDesktopTarget(@"/applist?uuid=abc"));
        for (NSString *target in @[@"/serverinfo?", @"/serverinfo/", @"/serverinfo#x",
                @"/serverinfo?uuid=abc", @"/serverinfo?uniqueid=0123456789ABCDEF&uuid=abcdef-0123",
                @"/serverinfo?uuid=abc&uuid=def", @"/serverinfo?uuid=", @"/serverinfo?uuid=a&",
                @"/serverinfo?password=abc", @"/serverinfo?session_token=abc", @"/serverinfo?uuid=a=b",
                @"/serverinfo?uuid=%61", @"/serverinfo?uuid=abc#def", @"/serverinfo?UUID=abc",
                @"https://localhost/serverinfo", @"//serverinfo", @"/serverinfo?uuid=not-hex",
                [@"/serverinfo?uuid=" stringByAppendingString:
                    [@"a" stringByPaddingToLength:65 withString:@"a" startingAtIndex:0]]]) {
            assert(!PLANKMacIsServerInformationTarget(target));
        }
        NSData *fixture = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
        assert(fixture);
        PLANKMacServerInformation *qualified = [[PLANKMacServerInformation alloc]
            initWithName:@"PLANK Mac qualification" workstationUUID:uuid version:@"macos-host-qualification"];
        NSXMLDocument *expectedDocument = [[NSXMLDocument alloc] initWithData:fixture options:0 error:NULL];
        NSXMLDocument *actualDocument = [[NSXMLDocument alloc]
            initWithData:[qualified XMLForControlPort:28989] options:0 error:NULL];
        assert([expectedDocument.rootElement.XMLString isEqual:actualDocument.rootElement.XMLString]);
        PLANKMacServerInformation *desktop = [[PLANKMacServerInformation alloc]
            initWithName:@"PLANK Mac qualification" workstationUUID:uuid
            version:@"macos-host-qualification" streaming:YES occupied:YES];
        NSXMLDocument *occupiedDocument = [[NSXMLDocument alloc]
            initWithData:[desktop XMLForControlPort:28989] options:0 error:NULL];
        NSArray<NSXMLElement *> *occupied = [occupiedDocument.rootElement elementsForName:@"PlankOccupied"];
        assert(occupied.count == 1 && [occupied.firstObject.stringValue isEqual:@"1"]);
        for (NSString *secret in @[@"username", @"uid", @"user", @"account", @"session"]) {
            assert([occupiedDocument.rootElement elementsForName:secret].count == 0);
        }
        puts("macos_server_information=pass public_allowlist=1 no_media_claim=1 escaped_xml=1 bounded_query=1 nameless_occupancy=1");
    }
}
