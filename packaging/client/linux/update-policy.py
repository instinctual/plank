#!/usr/bin/python3
"""Installer-only additions to administrator Client policy; never replace values."""
import os
from pathlib import Path
import re
import secrets
import stat
import sys

KEYS = ("internet_check_enabled", "internet_check_hosts",
        "internet_check_interval_seconds", "internet_check_timeout_ms")
SECTION = re.compile(r"^\s*\[([^]]+)\]\s*(?:[#;].*)?$")
ASSIGNMENT = re.compile(r"^\s*([^=\s]+)\s*=")


def add_missing_keys(original, reference):
    blocks, comments, section = {}, [], ""
    for line in reference.decode("utf-8").splitlines(keepends=True):
        header = SECTION.match(line)
        if header:
            section, comments = header[1], []
        elif line.lstrip().startswith(("#", ";")):
            comments.append(line)
        else:
            assignment = ASSIGNMENT.match(line)
            if section == "network" and assignment and assignment[1] in KEYS:
                blocks[assignment[1]] = "".join(comments) + line.rstrip("\r\n") + "\n"
            comments = []
    if set(blocks) != set(KEYS):
        raise ValueError("incomplete connectivity policy template")

    lines = original.decode("utf-8").splitlines(keepends=True)
    present, section, insertion = set(), "", None
    for index, line in enumerate(lines):
        header = SECTION.match(line)
        if header:
            section = header[1]
            if section == "network" and insertion is None:
                insertion = index + 1
        elif section == "network":
            assignment = ASSIGNMENT.match(line)
            if assignment:
                present.add(assignment[1])
    missing = [blocks[key] for key in KEYS if key not in present]
    if not missing:
        return original
    addition = "\n" + "\n".join(missing) + "\n"
    if insertion is None:
        prefix = "".join(lines)
        if prefix and not prefix.endswith("\n"):
            prefix += "\n"
        result = prefix + "\n[network]\n" + addition
    else:
        prefix = "".join(lines[:insertion])
        if not prefix.endswith("\n"):
            prefix += "\n"
        result = prefix + addition + "".join(lines[insertion:])
    updated = result.encode("utf-8")
    if len(updated) > 32768:
        raise ValueError("updated policy exceeds 32 KiB")
    return updated


def update(directory, template):
    # The package owns /etc/plank. Reject symlinks, unsafe ownership/modes and
    # hard links rather than letting a root maintainer script redirect writes.
    if os.path.realpath(directory) != os.path.abspath(directory):
        raise ValueError("symlinked policy directory")
    descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    temporary = None
    try:
        info = os.fstat(descriptor)
        if info.st_uid != os.geteuid() or info.st_mode & 0o022:
            raise ValueError("unsafe policy directory")

        def read_existing():
            fd = os.open("client.conf", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=descriptor)
            with os.fdopen(fd, "rb") as stream:
                info = os.fstat(stream.fileno())
                if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or
                        info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o644 or
                        info.st_size > 32768):
                    raise ValueError("unsafe Client policy")
                return stream.read(32769)

        original = read_existing()
        updated = add_missing_keys(original, Path(template).read_bytes())
        if original == updated:
            return
        temporary = ".client-connectivity-" + secrets.token_hex(12)
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o600, dir_fd=descriptor)
        with os.fdopen(fd, "wb") as stream:
            stream.write(updated)
            stream.flush()
            os.fchmod(stream.fileno(), 0o644)
            os.fsync(stream.fileno())
        if read_existing() != original:
            raise ValueError("policy changed during upgrade")
        os.replace(temporary, "client.conf", src_dir_fd=descriptor, dst_dir_fd=descriptor)
        temporary = None
        os.fsync(descriptor)
    finally:
        if temporary is not None:
            os.unlink(temporary, dir_fd=descriptor)
        os.close(descriptor)


if __name__ == "__main__":
    try:
        if len(sys.argv) != 3:
            raise ValueError("expected policy directory and packaged template")
        update(sys.argv[1], sys.argv[2])
    except (OSError, ValueError):
        # No configuration contents or administrator values in installation logs.
        sys.exit("PLANK Client: could not complete the connectivity-default update safely; check /etc/plank/client.conf.")
