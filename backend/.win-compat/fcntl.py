"""Minimal ``fcntl`` shim so the SupoClip backend can run natively on Windows.

SupoClip uses ``fcntl.flock`` for advisory cross-process file locks (media
leases, download locks, source-cache locks). POSIX provides that in ``fcntl``;
Windows provides byte-range locks in ``msvcrt``. This module maps the small
surface the backend uses (``flock`` plus the four lock flags) onto ``msvcrt``.

It is only placed on ``PYTHONPATH`` for local Windows development, so the
Linux/Docker images keep using the real ``fcntl`` module.
"""

from __future__ import annotations

import msvcrt
import os
import time

LOCK_SH = 1
LOCK_EX = 2
LOCK_NB = 4
LOCK_UN = 8

_POLL_SECONDS = 0.05
_LOCK_BYTES = 1


def _fileno(file: object) -> int:
    return file if isinstance(file, int) else file.fileno()  # type: ignore[union-attr]


def _try_lock(fd: int, exclusive: bool) -> bool:
    os.lseek(fd, 0, os.SEEK_SET)
    mode = msvcrt.LK_NBLCK if exclusive else msvcrt.LK_NBRLCK
    try:
        msvcrt.locking(fd, mode, _LOCK_BYTES)
    except OSError:
        return False
    return True


def flock(file: object, operation: int) -> None:
    """Acquire or release an advisory lock on the first byte of ``file``."""

    fd = _fileno(file)

    if operation & LOCK_UN:
        os.lseek(fd, 0, os.SEEK_SET)
        try:
            msvcrt.locking(fd, msvcrt.LK_UNLCK, _LOCK_BYTES)
        except OSError:
            # Nothing held (or already released by closing) - flock() is idempotent.
            pass
        return

    exclusive = bool(operation & LOCK_EX)
    if operation & LOCK_NB:
        if not _try_lock(fd, exclusive):
            raise BlockingIOError("resource temporarily unavailable")
        return

    while not _try_lock(fd, exclusive):
        time.sleep(_POLL_SECONDS)
