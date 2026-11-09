// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <grp.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static inline BOOL plank_config_directory_metadata(NSString *path, NSUInteger component,
                                                   NSUInteger count, const struct stat *st,
                                                   uid_t owner, mode_t mode) {
    if (!S_ISDIR(st->st_mode) || (st->st_uid != 0 && st->st_uid != owner)) return NO;
    // Other installers may make this shared system parent admin-writable.
    // Permit only root:admin 0775 on this exact ancestor of our system state;
    // never extend the exception to PLANK itself, /etc, or a lookalike path.
    BOOL sharedParent = component == 2 && [path isEqual:@"/Library/Application Support/PLANK"];
    if (st->st_mode & 0022) {
        if (sharedParent) {
            if (owner != 0 || st->st_uid != 0 || (st->st_mode & 07777) != 0775) return NO;
            struct group admin, *found = NULL;
            char buffer[16384];
            if (getgrnam_r("admin", &admin, buffer, sizeof(buffer), &found) ||
                !found || st->st_gid != admin.gr_gid) return NO;
        } else if (!(st->st_uid == 0 && (st->st_mode & S_ISVTX))) {
            return NO;
        }
    }
    return component != count - 1 || (st->st_uid == owner && (st->st_mode & 07777) == mode);
}

static inline void plank_config_directory_failure(NSArray<NSString *> *parts, NSUInteger component,
                                                  const struct stat *st, int error) {
    NSString *directory = [NSString pathWithComponents:[parts subarrayWithRange:NSMakeRange(0, component + 1)]];
    if (st) {
        fprintf(stderr, "PLANK configuration directory rejected: %s (uid=%lu gid=%lu mode=%04o)\n",
            directory.fileSystemRepresentation, (unsigned long)st->st_uid,
            (unsigned long)st->st_gid, (unsigned int)(st->st_mode & 07777));
    } else if (error != ENOENT) {
        fprintf(stderr, "PLANK configuration directory unavailable: %s (%s)\n",
            directory.fileSystemRepresentation, strerror(error));
    }
}

// No symlink traversal, including intermediate components. Production callers
// use /private/etc explicitly because macOS's /etc is a system symlink.
static inline int plank_config_directory(NSString *path, uid_t owner, mode_t mode, BOOL create) {
    if (!path.isAbsolutePath || path.pathComponents.count < 2) { errno = EINVAL; return -1; }
    int fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    NSArray *parts = path.pathComponents;
    for (NSUInteger i = 1; fd >= 0 && i < parts.count; i++) {
        NSString *part = parts[i];
        if (![part length] || [part isEqual:@"."] || [part isEqual:@".."]) { close(fd); errno = EINVAL; return -1; }
        if (create && i == parts.count - 1 && mkdirat(fd, part.fileSystemRepresentation, mode) && errno != EEXIST) {
            int saved = errno; close(fd); errno = saved; return -1;
        }
        int next = openat(fd, part.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        int saved = errno; close(fd); fd = next; errno = saved;
        struct stat st;
        if (fd < 0) {
            plank_config_directory_failure(parts, i, NULL, saved);
            errno = saved; break;
        }
        if (fstat(fd, &st)) {
            saved = errno; close(fd);
            plank_config_directory_failure(parts, i, NULL, saved);
            errno = saved; return -1;
        }
        if (!plank_config_directory_metadata(path, i, parts.count, &st, owner, mode)) {
            plank_config_directory_failure(parts, i, &st, EPERM);
            close(fd); errno = EPERM; return -1;
        }
    }
    return fd;
}

static inline NSData *plank_config_read(int directory, const char *name, uid_t owner, mode_t mode) {
    int fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) return nil;
    struct stat st;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_uid != owner || st.st_nlink != 1 ||
        (st.st_mode & 07777) != mode || st.st_size < 0 || st.st_size > 32768) { close(fd); return nil; }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)st.st_size];
    size_t offset = 0;
    while (offset < data.length) {
        ssize_t got = read(fd, (char *)data.mutableBytes + offset, data.length - offset);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) break;
        offset += (size_t)got;
    }
    char extra;
    BOOL valid = offset == data.length && read(fd, &extra, 1) == 0;
    close(fd);
    return valid ? data : nil;
}

static inline BOOL plank_config_exists(int directory, const char *name) {
    struct stat st;
    // An unreadable or dangling object is not permission to replace it.
    return !fstatat(directory, name, &st, AT_SYMLINK_NOFOLLOW) || errno != ENOENT;
}

// Publish a complete file without replacing any existing administrator data.
static inline BOOL plank_config_create(int directory, const char *name, NSData *data) {
    NSString *temporary = [@".plank-config-" stringByAppendingString:NSUUID.UUID.UUIDString];
    int fd = openat(directory, temporary.UTF8String, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return NO;
    size_t offset = 0;
    while (offset < data.length) {
        ssize_t wrote = write(fd, (const char *)data.bytes + offset, data.length - offset);
        if (wrote < 0 && errno == EINTR) continue;
        if (wrote <= 0) break;
        offset += (size_t)wrote;
    }
    BOOL ok = offset == data.length && !fchmod(fd, 0644) && !fsync(fd);
    close(fd);
    if (ok) ok = !renameatx_np(directory, temporary.UTF8String, directory, name, RENAME_EXCL);
    if (!ok) unlinkat(directory, temporary.UTF8String, 0);
    if (ok) ok = !fsync(directory);
    return ok;
}
