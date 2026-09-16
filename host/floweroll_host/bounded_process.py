"""POSIX subprocess capture with actual in-flight byte/deadline limits.
This is resource control, not a filesystem/security sandbox.
"""
from __future__ import annotations
import os
import selectors
import signal
import subprocess
import time
from pathlib import Path
from typing import Mapping, Sequence, Tuple

class ProcessOutputLimitError(RuntimeError):
    pass

def run_bounded(command: Sequence[str], *, cwd: Path, env: Mapping[str,str],
                timeout: float, stdout_limit: int, stderr_limit: int) -> Tuple[int, bytes, bytes]:
    if timeout <= 0 or stdout_limit < 1 or stderr_limit < 1:
        raise ValueError('process limits must be positive')
    process = subprocess.Popen(list(command), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, shell=False, cwd=str(cwd), env=dict(env), start_new_session=True)
    buffers = {'stdout':bytearray(), 'stderr':bytearray()}
    limits = {'stdout':stdout_limit,'stderr':stderr_limit}
    selector=selectors.DefaultSelector()
    deadline=time.monotonic()+timeout
    try:
        for name,stream in [('stdout',process.stdout),('stderr',process.stderr)]:
            os.set_blocking(stream.fileno(),False)
            selector.register(stream,selectors.EVENT_READ,name)
        while selector.get_map():
            remaining=deadline-time.monotonic()
            if remaining <= 0:
                raise TimeoutError('provider process exceeded deadline')
            for key,_ in selector.select(min(0.1,remaining)):
                chunk=os.read(key.fd,65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                name=key.data
                if len(buffers[name])+len(chunk)>limits[name]:
                    raise ProcessOutputLimitError('provider process exceeded '+name+' limit')
                buffers[name].extend(chunk)
        remaining=deadline-time.monotonic()
        if remaining <= 0: raise TimeoutError('provider process exceeded deadline')
        try: code=process.wait(timeout=remaining)
        except subprocess.TimeoutExpired as exc: raise TimeoutError('provider process exceeded deadline') from exc
        return code,bytes(buffers['stdout']),bytes(buffers['stderr'])
    finally:
        # Also reclaim children retaining inherited pipes. Never target another session.
        try: os.killpg(process.pid,signal.SIGKILL)
        except ProcessLookupError: pass
        process.wait(timeout=5)
        selector.close()
        if process.stdout: process.stdout.close()
        if process.stderr: process.stderr.close()
