// SPDX-License-Identifier: GPL-3.0-or-later
// Exercise the production metadata policy without changing system directories.
#import "configuration-files.h"
#include <assert.h>

static BOOL permitted(NSString *path, NSUInteger component, uid_t owner,
                      uid_t actualOwner, gid_t group, mode_t permissions) {
    struct stat st = {0};
    st.st_mode = S_IFDIR | permissions;
    st.st_uid = actualOwner;
    st.st_gid = group;
    return plank_config_directory_metadata(path, component, path.pathComponents.count, &st, owner, 0755);
}

int main(void) { @autoreleasepool {
    struct group *admin = getgrnam("admin");
    assert(admin);
    const gid_t adminGroup = admin->gr_gid, otherGroup = adminGroup == 0 ? 1 : 0;
    const uid_t otherOwner = 501;
    NSString *state = @"/Library/Application Support/PLANK";

    assert(permitted(state, 2, 0, 0, adminGroup, 0755));
    assert(permitted(state, 2, 0, 0, adminGroup, 0775));
    assert(!permitted(state, 2, 0, otherOwner, adminGroup, 0775));
    assert(!permitted(state, 2, 0, 0, otherGroup, 0775));
    assert(!permitted(state, 2, otherOwner, 0, adminGroup, 0775));
    for (NSNumber *mode in @[@0777, @01777, @01775, @02775, @0770])
        assert(!permitted(state, 2, 0, 0, adminGroup, mode.unsignedShortValue));

    // The protected leaf and other ancestors never inherit the shared exception.
    assert(permitted(state, 3, 0, 0, adminGroup, 0755));
    assert(!permitted(state, 3, 0, 0, adminGroup, 0775));
    assert(!permitted(state, 3, 0, otherOwner, adminGroup, 0755));
    assert(!permitted(state, 1, 0, 0, adminGroup, 0775));
    for (NSString *path in @[@"/Library/Application Support/PLANK-other",
                             @"/Library/Application Support/PLANK/SignIn",
                             @"/private/etc/plank", @"/Users/example/Library/Application Support/PLANK"])
        assert(!permitted(path, 2, 0, 0, adminGroup, 0775));

    // Existing root-owned sticky temporary parents remain usable by fixtures.
    assert(permitted(@"/private/tmp/plank-fixture", 2, otherOwner, 0, otherGroup, 01777));
    assert(!permitted(@"/private/tmp/plank-fixture", 2, otherOwner, otherOwner, otherGroup, 01777));
    struct stat regular = {0};
    regular.st_mode = S_IFREG | 0775; regular.st_uid = 0; regular.st_gid = adminGroup;
    assert(!plank_config_directory_metadata(state, 2, 4, &regular, 0, 0755));
    puts("macos_configuration_paths=pass shared_admin_parent=1 protected_leaf=1 unsafe_ancestors_rejected=1");
    return 0;
} }
