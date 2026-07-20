#!/usr/bin/env python3
"""
宝塔面板反向代理 v2
绕过 is_spider() 检查，转发带正确 UA 的请求
"""
import os, sys, ssl, socket, threading
from http.server import HTTPServer, BaseHTTPRequestHandler

for k in ['http_proxy', 'https_proxy', 'HTTP_PROXY', 'HTTPS_PROXY']:
    os.environ.pop(k, None)

BROWSER_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
BT_PORT = 24965

class BTProxyHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.proxy_request()
    def do_POST(self):
        self.proxy_request()
    def do_HEAD(self):
        self.proxy_request()
    
    def proxy_request(self):
        try:
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            
            sock = socket.create_connection(('127.0.0.1', BT_PORT), timeout=30)
            
            is_ssl = os.path.exists('/www/server/panel/data/ssl.pl')
            if is_ssl:
                ssock = ctx.wrap_socket(sock, server_hostname='127.0.0.1')
            else:
                ssock = sock
            
            body = b''
            if self.command == 'POST':
                content_length = int(self.headers.get('Content-Length', 0))
                body = self.rfile.read(content_length) if content_length > 0 else b''
            
            headers = f"{self.command} {self.path} HTTP/1.0\r\n"
            headers += f"Host: 127.0.0.1:{BT_PORT}\r\n"
            headers += f"User-Agent: {BROWSER_UA}\r\n"
            headers += "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8\r\n"
            headers += "Accept-Language: zh-CN,zh;q=0.9,en;q=0.8\r\n"
            
            for k, v in self.headers.items():
                if k.lower() not in ['host', 'user-agent', 'connection', 'transfer-encoding', 'accept-encoding']:
                    headers += f"{k}: {v}\r\n"
            
            headers += "Connection: close\r\n\r\n"
            
            ssock.send(headers.encode() + body)
            
            response = b''
            while True:
                try:
                    chunk = ssock.recv(8192)
                    if not chunk:
                        break
                    response += chunk
                except:
                    break
            ssock.close()
            
            if b'\r\n\r\n' in response:
                header_part, body_part = response.split(b'\r\n\r\n', 1)
                header_lines = header_part.decode('utf-8', errors='replace').split('\r\n')
                
                status_line = header_lines[0]
                parts = status_line.split(' ', 2)
                status_code = int(parts[1]) if len(parts) > 1 else 200
                
                self.send_response(status_code)
                for line in header_lines[1:]:
                    if ':' in line:
                        k, v = line.split(':', 1)
                        k = k.strip()
                        v = v.strip()
                        if k.lower() not in ['transfer-encoding', 'connection', 'content-length', 'content-encoding']:
                            self.send_header(k, v)
                self.send_header('Content-Length', str(len(body_part)))
                self.end_headers()
                self.wfile.write(body_part)
            else:
                self.send_response(502)
                self.end_headers()
                self.wfile.write(b"Bad gateway")
                
        except Exception as e:
            self.send_response(502)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(f"Proxy Error: {e}".encode())
    
    def log_message(self, format, *args):
        pass

if __name__ == '__main__':
    port = 18099
    server = HTTPServer(('0.0.0.0', port), BTProxyHandler)
    print(f"BT Panel proxy on http://0.0.0.0:{port}", flush=True)
    server.serve_forever()
