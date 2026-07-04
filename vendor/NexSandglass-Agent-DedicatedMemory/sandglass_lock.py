"""
Small cross-process file lock helpers for NexSandglass memory writes.

The lock is intentionally simple and dependency-free: create a sibling
``.lock`` file with O_EXCL, retry until timeout, remove stale locks, and
never write after timeout. Shared memory roots may be used by multiple
agents, so failing closed is safer than a corrupted memory file.
"""

from __future__ import annotations

import os
import time
from contextlib import contextmanager
from dataclasses import dataclass


class MemoryLockTimeout(TimeoutError):
    """Raised when a memory file lock cannot be acquired in time."""


@dataclass
class FileLock:
    target: str
    timeout: float = 15.0
    stale_after: float = 120.0
    poll: float = 0.04

    @property
    def path(self) -> str:
        return self.target + ".lock"

    def acquire(self) -> int:
        os.makedirs(os.path.dirname(os.path.abspath(self.path)), exist_ok=True)
        deadline = time.time() + self.timeout
        while time.time() < deadline:
            self._remove_stale()
            try:
                fd = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
                payload = f"pid={os.getpid()} acquiredAt={time.time()} target={self.target}\n".encode("utf-8")
                os.write(fd, payload)
                os.fsync(fd)
                return fd
            except FileExistsError:
                time.sleep(self.poll)
        raise MemoryLockTimeout(f"MEMORY_LOCK_TIMEOUT path={self.target} lock={self.path} timeout={self.timeout}")

    def release(self, fd: int) -> None:
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.unlink(self.path)
        except FileNotFoundError:
            pass

    def _remove_stale(self) -> None:
        try:
            age = time.time() - os.path.getmtime(self.path)
            if age > self.stale_after:
                os.unlink(self.path)
        except FileNotFoundError:
            pass
        except OSError:
            pass


@contextmanager
def locked_file(target: str, timeout: float = 15.0, stale_after: float = 120.0):
    lock = FileLock(target=target, timeout=timeout, stale_after=stale_after)
    fd = lock.acquire()
    try:
        yield
    finally:
        lock.release(fd)
