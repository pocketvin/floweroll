"""Uvicorn lifecycle adapter for the existing Host runner and network tests."""
from __future__ import annotations

import socket
import threading

import uvicorn

from .http_app import create_http_app


class _HostServer(uvicorn.Server):
    def __init__(self, config, shutdown_event):
        super().__init__(config)
        self.shutdown_event = shutdown_event

    async def shutdown(self, sockets=None):
        # Set before Uvicorn drains connections, not in lifespan teardown (which
        # is too late for long-lived streams waiting on shutdown).
        self.shutdown_event.set()
        await super().shutdown(sockets=sockets)


class FlowerollHTTPServer:
    def __init__(self, server_address, app, auth_token=None):
        self.app, self.auth_token = app, auth_token
        self.shutdown_event = threading.Event()
        self._done = threading.Event()
        self._thread = None
        self._closed = False
        self.asgi_app = create_http_app(app, auth_token=auth_token, shutdown_event=self.shutdown_event)
        self._server = _HostServer(uvicorn.Config(self.asgi_app, host=server_address[0], port=server_address[1],
                                  loop="asyncio", http="h11", ws="none", workers=1,
                                  access_log=False, log_level="warning", proxy_headers=False,
                                  server_header=False), self.shutdown_event)
        family = socket.AF_INET6 if ":" in server_address[0] else socket.AF_INET
        self.socket = socket.socket(family, socket.SOCK_STREAM)
        try:
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            self.socket.bind(server_address)
            self.socket.listen(128)
            self.server_address = self.socket.getsockname()
            self.server_port = self.server_address[1]
        except BaseException:
            self.socket.close()
            self.asgi_app.state.close_host()
            self._closed = True
            raise

    def serve_forever(self, poll_interval=0.5):
        if self._closed or self.shutdown_event.is_set():
            self.server_close()
            return
        self._thread = threading.current_thread()
        try:
            self._server.run(sockets=[self.socket])
        finally:
            self.shutdown_event.set()
            self.socket.close()
            # Also handle pre-start failures or shutdown before lifespan startup.
            self.asgi_app.state.close_host()
            self._closed = True
            self._done.set()

    def shutdown(self):
        self.shutdown_event.set()
        self._server.should_exit = True
        if self._thread is not None and self._thread is not threading.current_thread():
            self._done.wait()

    def server_close(self):
        self.shutdown()
        if not self._closed and self._thread is None:
            self.socket.close()
            self.asgi_app.state.close_host()
            self._closed = True
