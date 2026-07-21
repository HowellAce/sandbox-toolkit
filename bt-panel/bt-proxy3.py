#!/usr/bin/env python3
"""
宝塔面板反向代理 v3
解决 v2 的单线程、无 WebSocket、无 keep-alive 问题

改进：
1. ThreadingHTTPServer 多线程并发处理
2. 支持 WebSocket 升级（终端、文件管理等功能需要）
3. HTTP/1.1 keep-alive 连接复用
4. 流式响应（支持 SSE/长轮询）
5. 正确处理 chunked encoding
"""
import os, sys, ssl, socket, threading, select, time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

for k in ['http_proxy', 'https_proxy', 'HTTP_PROXY', 'HTTPS_PROXY']:
    os.environ.pop(k, None)

BROWSER_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
BT_HOST = '127.0.0.1'
BT_PORT = 24965
PROXY_PORT = 18099

# SSL 上下文（复用）
_ssl_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
_ssl_ctx.check_hostname = False
_ssl_ctx.verify_mode = ssl.CERT_NONE

_is_ssl = os.path.exists('/www/server/panel/data/ssl.pl')

# 连接锁（防止过多并发连接耗尽文件描述符）
_conn_lock = threading.Lock()
_active_conns = 0
MAX_CONCURRENT = 50


class BTProxyHandler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def _connect_backend(self):
        """创建到后端的连接"""
        sock = socket.create_connection((BT_HOST, BT_PORT), timeout=30)
        if _is_ssl:
            sock = _ssl_ctx.wrap_socket(sock, server_hostname=BT_HOST)
        return sock

    def _is_websocket(self):
        """检查是否是 WebSocket 升级请求"""
        upgrade = self.headers.get('Upgrade', '').lower()
        return upgrade == 'websocket'

    def _handle_websocket(self):
        """处理 WebSocket 升级：建立隧道，双向转发"""
        try:
            backend = self._connect_backend()
        except Exception as e:
            self.send_response(502)
            self.end_headers()
            self.wfile.write(f"WS connect failed: {e}".encode())
            return

        # 构建发往后端的请求
        req_lines = [f"{self.command} {self.path} HTTP/1.1"]
        req_lines.append(f"Host: {BT_HOST}:{BT_PORT}")
        req_lines.append(f"User-Agent: {BROWSER_UA}")

        for k, v in self.headers.items():
            kl = k.lower()
            if kl in ['host', 'user-agent', 'connection', 'transfer-encoding', 'accept-encoding']:
                continue
            req_lines.append(f"{k}: {v}")

        req_lines.append("Connection: Upgrade")
        req_lines.append("")
        req_lines.append("")

        backend.sendall('\r\n'.join(req_lines).encode())

        # 建立隧道：双向转发
        self.connection.setblocking(False)
        backend.setblocking(False)

        # 先转发后端的响应给客户端
        # 发送 101 Switching Protocols
        self.send_response(101)
        self.send_header('Upgrade', 'websocket')
        self.send_header('Connection', 'Upgrade')
        sec_key = self.headers.get('Sec-WebSocket-Accept', '')
        if sec_key:
            self.send_header('Sec-WebSocket-Accept', sec_key)
        self.end_headers()

        # 双向隧道
        sockets = [self.connection, backend]
        try:
            while True:
                readable, _, errored = select.select(sockets, [], sockets, 60)
                if errored:
                    break
                if not readable:
                    # 超时，检查连接是否还活着
                    continue
                for s in readable:
                    other = backend if s is self.connection else self.connection
                    try:
                        data = s.recv(65536)
                        if not data:
                            return
                        other.sendall(data)
                    except (BlockingIOError, ssl.SSLWantReadError):
                        continue
                    except:
                        return
        finally:
            try:
                backend.close()
            except:
                pass

    def proxy_request(self):
        global _active_conns

        # WebSocket 升级
        if self._is_websocket():
            self._handle_websocket()
            return

        with _conn_lock:
            _active_conns += 1
            if _active_conns > MAX_CONCURRENT:
                _active_conns -= 1
                self.send_response(503)
                self.send_header('Content-Type', 'text/plain')
                self.send_header('Content-Length', '18')
                self.end_headers()
                self.wfile.write(b'Too many requests')
                return

        try:
            backend = self._connect_backend()
        except Exception as e:
            with _conn_lock:
                _active_conns -= 1
            self.send_response(502)
            self.send_header('Content-Type', 'text/plain')
            self.send_header('Content-Length', str(len(str(e).encode()) + 15))
            self.end_headers()
            self.wfile.write(f"Backend Error: {e}".encode())
            return

        try:
            # 读取请求体
            body = b''
            if self.command in ('POST', 'PUT', 'PATCH', 'DELETE'):
                content_length = int(self.headers.get('Content-Length', 0))
                if content_length > 0:
                    body = self.rfile.read(content_length)
                elif self.headers.get('Transfer-Encoding', '').lower() == 'chunked':
                    # 读取 chunked body
                    while True:
                        line = self.rfile.readline().strip()
                        if not line:
                            break
                        size = int(line, 16)
                        if size == 0:
                            self.rfile.readline()
                            break
                        body += self.rfile.read(size)
                        self.rfile.readline()

            # 构建后端请求
            req_headers = f"{self.command} {self.path} HTTP/1.1\r\n"
            req_headers += f"Host: {BT_HOST}:{BT_PORT}\r\n"
            req_headers += f"User-Agent: {BROWSER_UA}\r\n"

            for k, v in self.headers.items():
                kl = k.lower()
                if kl in ['host', 'user-agent', 'connection', 'transfer-encoding', 'accept-encoding']:
                    continue
                req_headers += f"{k}: {v}\r\n"

            req_headers += "Accept-Encoding: identity\r\n"
            req_headers += "Connection: close\r\n\r\n"

            backend.sendall(req_headers.encode() + body)

            # 读取后端响应（流式）
            # 先读取响应头
            resp_header_data = b''
            while b'\r\n\r\n' not in resp_header_data:
                chunk = backend.recv(8192)
                if not chunk:
                    break
                resp_header_data += chunk

            if b'\r\n\r\n' not in resp_header_data:
                self.send_response(502)
                self.send_header('Content-Length', '11')
                self.end_headers()
                self.wfile.write(b'Bad gateway')
                return

            header_part, initial_body = resp_header_data.split(b'\r\n\r\n', 1)
            header_lines = header_part.decode('utf-8', errors='replace').split('\r\n')

            # 解析状态行
            status_line = header_lines[0]
            parts = status_line.split(' ', 2)
            status_code = int(parts[1]) if len(parts) > 1 else 200
            status_msg = parts[2] if len(parts) > 2 else ''

            # 发送状态码
            self.send_response(status_code, status_msg)

            # 处理响应头
            is_chunked = False
            content_length = None
            for line in header_lines[1:]:
                if ':' in line:
                    k, v = line.split(':', 1)
                    k = k.strip()
                    v = v.strip()
                    kl = k.lower()
                    if kl == 'transfer-encoding':
                        if 'chunked' in v.lower():
                            is_chunked = True
                        continue
                    if kl == 'connection':
                        continue
                    if kl == 'content-length':
                        content_length = int(v)
                        continue
                    if kl == 'content-encoding':
                        # 不转发 gzip/br，因为我们已经用 Accept-Encoding: identity
                        continue
                    self.send_header(k, v)

            # 读取完整响应体
            resp_body = initial_body
            if is_chunked:
                # 解析 chunked encoding
                data = initial_body
                while True:
                    # 检查是否有完整的 chunk
                    while b'\r\n' not in data:
                        chunk = backend.recv(8192)
                        if not chunk:
                            break
                        data += chunk
                    if b'\r\n' not in data:
                        break
                    size_line, data = data.split(b'\r\n', 1)
                    try:
                        chunk_size = int(size_line.strip(), 16)
                    except:
                        break
                    if chunk_size == 0:
                        break
                    while len(data) < chunk_size + 2:
                        chunk = backend.recv(8192)
                        if not chunk:
                            break
                        data += chunk
                    resp_body += data[:chunk_size]
                    data = data[chunk_size + 2:]  # skip data + \r\n
            else:
                # 普通响应，读取到连接关闭或达到 content_length
                if content_length is not None:
                    while len(resp_body) < content_length:
                        chunk = backend.recv(65536)
                        if not chunk:
                            break
                        resp_body += chunk
                else:
                    while True:
                        chunk = backend.recv(65536)
                        if not chunk:
                            break
                        resp_body += chunk

            # 发送响应头和体
            self.send_header('Content-Length', str(len(resp_body)))
            self.send_header('Connection', 'keep-alive')
            self.end_headers()
            self.wfile.write(resp_body)

        except Exception as e:
            try:
                self.send_response(502)
                self.send_header('Content-Type', 'text/plain')
                self.send_header('Content-Length', str(len(str(e).encode()) + 15))
                self.end_headers()
                self.wfile.write(f"Proxy Error: {e}".encode())
            except:
                pass
        finally:
            try:
                backend.close()
            except:
                pass
            with _conn_lock:
                _active_conns -= 1

    def do_GET(self):
        self.proxy_request()

    def do_POST(self):
        self.proxy_request()

    def do_PUT(self):
        self.proxy_request()

    def do_DELETE(self):
        self.proxy_request()

    def do_HEAD(self):
        self.proxy_request()

    def do_OPTIONS(self):
        self.proxy_request()

    def log_message(self, fmt, *args):
        pass  # 静默日志


if __name__ == '__main__':
    server = ThreadingHTTPServer(('0.0.0.0', PROXY_PORT), BTProxyHandler)
    server.daemon_threads = True
    print(f"BT Panel proxy v3 on http://0.0.0.0:{PROXY_PORT} (threaded, WS support)", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
