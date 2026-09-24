// SPDX-License-Identifier: GPL-3.0-or-later
#import "media-features.h"
#include <stdio.h>
#include <stdlib.h>
static unsigned checks;
#define CHECK(x) do { ++checks; if (!(x)) { fprintf(stderr, "line %d: %s\n", __LINE__, #x); exit(1); } } while (0)
int main(int argc, const char **argv) {
    if (argc != 3) return 2;
    @autoreleasepool {
        NSDictionary *vector = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(argv[1])] options:0 error:NULL];
        NSDictionary *legacy = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(argv[2])] options:0 error:NULL];
        CHECK(vector && legacy);
        unsigned status = 0;
        NSDictionary *offer = vector[@"offer"], *launch = vector[@"launch"];
        CHECK([PLANKMacNegotiateMedia(offer, &status) isEqual:vector[@"response"]] && status == 200);
        NSDictionary *normalized = PLANKMacNormalizeMediaLaunch(launch);
        NSMutableDictionary *expected = [legacy mutableCopy];
        expected[@"clipboard"] = @YES; expected[@"microphone"] = @YES; expected[@"camera"] = @YES;
        CHECK([normalized isEqual:expected]);
        CHECK([PLANKMacMediaReplyFeatures(launch, YES, YES, YES) isEqual:launch[@"features"]]);
        NSDictionary *disabled = PLANKMacMediaReplyFeatures(launch, NO, NO, NO);
        for (NSString *name in @[@"clipboard", @"microphone", @"camera"]) CHECK(disabled[name] == NSNull.null);
        for (unsigned schema = 4; schema <= 6; ++schema) {
            NSMutableDictionary *old = [expected mutableCopy]; old[@"schema_version"] = @(schema);
            if (schema < 6) [old removeObjectForKey:@"camera"];
            NSDictionary *converted = PLANKMacNormalizeMediaLaunch(old);
            CHECK(converted.count == 12);
            CHECK([converted[@"microphone"] boolValue] == (schema >= 5));
            CHECK([converted[@"camera"] boolValue] == (schema >= 6));
            CHECK([converted[@"clipboard"] boolValue]);
            old[@"microphone"] = @1; CHECK(!PLANKMacNormalizeMediaLaunch(old));
        }
        for (NSString *name in PLANKMacMediaNames()) {
            NSMutableDictionary *changed = [offer mutableCopy], *features = [offer[@"features"] mutableCopy];
            features[name] = @[@{@"schema_version": @999}]; changed[@"features"] = features;
            NSDictionary *reply = PLANKMacNegotiateMedia(changed, &status);
            if ([@[@"desktop", @"audio", @"input"] containsObject:name]) CHECK(!reply && status == 426);
            else CHECK(reply && status == 200 && reply[@"features"][name] == NSNull.null);
            features[name] = @[@{@"schema_version": @YES}];
            CHECK(!PLANKMacNegotiateMedia(changed, &status) && status == 400);
        }
        NSMutableDictionary *additive = [offer mutableCopy], *features = [offer[@"features"] mutableCopy];
        additive[@"future_hint"] = @YES;
        features[@"future_optional"] = @[@{@"schema_version": @7}]; additive[@"features"] = features;
        CHECK([PLANKMacNegotiateMedia(additive, &status) isEqual:vector[@"response"]]);
        additive[@"required_features"] = @[@"desktop", @"audio", @"input", @"future_optional"];
        CHECK(!PLANKMacNegotiateMedia(additive, &status) && status == 426);
        for (id version in @[@YES, @1.5, @"1"]) {
            NSMutableDictionary *bad = [offer mutableCopy]; bad[@"schema_version"] = version;
            CHECK(!PLANKMacNegotiateMedia(bad, &status) && status == 400);
        }
        NSMutableDictionary *wrongTransport = [offer mutableCopy]; wrongTransport[@"transport"] = @"plank-native/1";
        CHECK(!PLANKMacNegotiateMedia(wrongTransport, &status) && status == 426);
        for (NSString *name in @[@"desktop", @"audio", @"input"]) {
            NSMutableDictionary *bad = [launch mutableCopy], *selected = [launch[@"features"] mutableCopy];
            selected[name] = NSNull.null; bad[@"features"] = selected;
            CHECK(!PLANKMacNormalizeMediaLaunch(bad));
        }
        NSMutableDictionary *bad = [launch mutableCopy], *selected = [launch[@"features"] mutableCopy];
        NSMutableDictionary *audio = [selected[@"audio"] mutableCopy]; audio[@"channels"] = @1;
        selected[@"audio"] = audio; bad[@"features"] = selected; CHECK(!PLANKMacNormalizeMediaLaunch(bad));
        bad = [launch mutableCopy]; bad[@"schema_version"] = @YES; CHECK(!PLANKMacNormalizeMediaLaunch(bad));
        printf("Mac media features: %u checks passed\n", checks);
    }
}
