"""Atomic filesystem operations provided by macOS."""
import ctypes
import os


def rename_with_flags(source, destination, flags):
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.renamex_np(os.fsencode(source), os.fsencode(destination), flags) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), source, None, destination)


RENAME_SWAP = 2
RENAME_EXCL = 4
