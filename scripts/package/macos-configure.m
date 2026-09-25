// SPDX-License-Identifier: GPL-3.0-or-later
// Installer-only operation. Not a daemon, setuid executable or runtime fallback.
#import "host-configuration.h"
#import "configuration-files.h"

static int failure(const char *reason) {
    fprintf(stderr, "PLANK configuration: %s; existing configuration and keys were not replaced\n", reason);
    return 1;
}

static NSData *propertyList(id object) {
    return [NSPropertyListSerialization dataWithPropertyList:object format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
}

static NSData *legacyINI(NSData *data, NSData *reference, NSString **uuid) {
    id old = data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL] : nil;
    if (![old isKindOfClass:NSDictionary.class] || [old count] != 4 ||
        ![old[@"Address"] isEqual:@"0.0.0.0"] || ![old[@"Name"] isKindOfClass:NSString.class] ||
        ![old[@"Port"] isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)old[@"Port"]) == CFBooleanGetTypeID() ||
        [old[@"Port"] doubleValue] != [old[@"Port"] unsignedShortValue] || ![old[@"Port"] unsignedShortValue]) return nil;
    *uuid = PLANKMacReadWorkstationUUID(propertyList(@{@"UUID": old[@"UUID"] ?: @""}));
    if (!*uuid) return nil;
    NSString *text = [[NSString alloc] initWithData:reference encoding:NSUTF8StringEncoding];
    text = [text stringByReplacingOccurrencesOfString:@"port = 28989"
        withString:[NSString stringWithFormat:@"port = %@", old[@"Port"]]];
    text = [text stringByReplacingOccurrencesOfString:@"host_name = PLANK Mac Host"
        withString:[@"host_name = " stringByAppendingString:old[@"Name"]]];
    NSData *ini = [text dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *parsed = PLANKMacParseHostConfiguration(ini);
    return [parsed[@"Name"] isEqual:old[@"Name"]] && [parsed[@"Port"] isEqual:old[@"Port"]] ? ini : nil;
}

int main(int argc, const char *argv[]) { @autoreleasepool {
    umask(022); // Public configuration only; temporary files still start at 0600.
    if (argc != 5) return failure("expected MODE CONFIG_DIRECTORY STATE_DIRECTORY TEMPLATE");
    NSString *mode = @(argv[1]), *configPath = @(argv[2]), *statePath = @(argv[3]);
    BOOL client = [mode isEqual:@"client"], check = [mode isEqual:@"host-check"], finish = [mode isEqual:@"host-finish"];
    if (!client && !check && !finish && ![mode isEqual:@"host-prepare"]) return failure("invalid operation");
    uid_t owner = geteuid();
    // The production installer invokes this as root. Non-root fixture tests
    // exercise the exact same implementation exclusively in owned temporary dirs.
    int config = plank_config_directory(configPath, owner, 0755, !check && !finish);
    if (config < 0 && !(check && errno == ENOENT)) return failure("unsafe or missing configuration directory");
    NSData *reference = [NSData dataWithContentsOfFile:@(argv[4]) options:NSDataReadingUncached error:NULL];
    if (!reference.length || reference.length > 32768) return failure("missing or oversized reference template");
    if (client) {
        BOOL exists = plank_config_exists(config, "client.conf");
        // Never parse/rewrite an administrator's private policy during install.
        BOOL ok = exists ? plank_config_read(config, "client.conf", owner, 0644) != nil :
            plank_config_create(config, "client.conf", reference);
        close(config);
        return ok ? 0 : failure("unsafe Client policy or cannot create default policy");
    }
    if (!PLANKMacParseHostConfiguration(reference)) return failure("invalid Host reference template");
    int state = plank_config_directory(statePath, owner, 0755, !check && !finish);
    if (state < 0) return failure("unsafe or missing identity directory");
    BOOL hasConfig = config >= 0 && plank_config_exists(config, "host.conf");
    BOOL hasIdentity = plank_config_exists(state, "identity.plist");
    BOOL hasLegacy = plank_config_exists(state, "host.plist");
    NSData *ini = hasConfig ? plank_config_read(config, "host.conf", owner, 0644) : nil;
    NSString *uuid = hasIdentity ? PLANKMacReadWorkstationUUID(plank_config_read(state, "identity.plist", owner, 0644)) : nil;
    NSString *oldUUID = nil;
    NSData *converted = hasLegacy ? legacyINI(plank_config_read(state, "host.plist", owner, 0644), reference, &oldUUID) : nil;
    if ((hasConfig && !PLANKMacParseHostConfiguration(ini)) || (hasIdentity && !uuid) ||
        (hasLegacy && !converted) || (uuid && oldUUID && [uuid caseInsensitiveCompare:oldUUID] != NSOrderedSame))
        return failure("invalid configuration, identity or conflicting UUID");
    if (!uuid && !oldUUID && plank_config_exists(state, "SignIn"))
        return failure("TLS identity exists without workstation UUID; restore its identity record");
    if (check) { if (config >= 0) close(config); close(state); return 0; }
    if (finish) {
        if (!hasConfig || !hasIdentity) return failure("conversion is incomplete");
        // Preinstall retains the old file until the replacement app is installed.
        // Retrying after an interruption validates the same UUID before retiring it.
        if (hasLegacy && (unlinkat(state, "host.plist", 0) || fsync(state))) return failure("cannot retire converted plist");
    } else {
        uuid = uuid ?: oldUUID ?: NSUUID.UUID.UUIDString;
        if (!hasIdentity && !plank_config_create(state, "identity.plist", propertyList(@{@"UUID": uuid})))
            return failure("cannot create identity record");
        if (!hasConfig && !plank_config_create(config, "host.conf", converted ?: reference))
            return failure("cannot create Host configuration");
    }
    close(config); close(state);
    return 0;
} }
