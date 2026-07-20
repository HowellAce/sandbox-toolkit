#!/usr/bin/env python3
"""
SOCKS5 代理桥接器
接受 cloudflared 的 SOCKS5 连接，通过 HTTP 代理的 CONNECT 方法转发
"""
import socket, threading, struct, select

HTTP_PROXY = ('127.0.0.1', 18080)
LISTEN_PORT = 11080

def handle_client(client):
    try:
        # SOCKS5 握手
        version = client.recv(1)
        if version != b'\x05':
            client.close()
            return
        nmethods = client.recv(1)
        methods = client.recv(ord(nmethods))
        # 不需要认证
        client.send(b'\x05\x00')
        
        # 读取请求
        version = client.recv(1)
        cmd = client.recv(1)
        rsv = client.recv(1)
        atyp = client.recv(1)
        
        if cmd != b'\x01':  # 只支持 CONNECT
            client.send(b'\x05\x07\x00\x01' + b'\x00' * 6)
            client.close()
            return
        
        # 读取目标地址
        if atyp == b'\x01':  # IPv4
            addr = socket.inet_ntoa(client.recv(4))
        elif atyp == b'\x03':  # 域名
            alen = ord(client.recv(1))
            addr = client.recv(alen).decode()
        elif atyp == b'\x04':  # IPv6
            addr = socket.inet_ntop(socket.AF_INET6, client.recv(16))
        else:
            client.close()
            return
        
        port = struct.unpack('!H', client.recv(2))[0]
        target = f"{addr}:{port}"
        
        print(f"[SOCKS5] CONNECT {target}", flush=True)
        
        # 通过 HTTP 代理建立 CONNECT 隧道
        proxy = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        proxy.settimeout(30)
        proxy.connect(HTTP_PROXY)
        connect_req = f"CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n\r\n"
        proxy.send(connect_req.encode())
        
        # 读取代理响应
        response = b''
        while b'\r\n\r\n' not in response:
            chunk = proxy.recv(4096)
            if not chunk:
                break
            response += chunk
        
        if b'200' in response.split(b'\r\n')[0]:
            # 成功，回复 SOCKS5 客户端
            client.send(b'\x05\x00\x00\x01' + socket.inet_aton('0.0.0.0') + struct.pack('!H', 0))
            
            # 双向转发
            def forward(src, dst):
                try:
                    while True:
                        data = src.recv(4096)
                        if not data:
                            break
                        dst.send(data)
                except:
                    pass
                finally:
                    try: src.close()
                    except: pass
                    try: dst.close()
                    except: pass
            
            t1 = threading.Thread(target=forward, args=(client, proxy))
            t2 = threading.Thread(target=forward, args=(proxy, client))
            t1.daemon = True
            t2.daemon = True
            t1.start()
            t2.start()
            t1.join()
        else:
            print(f"[SOCKS5] FAILED {target}: {response.decode()[:100]}", flush=True)
            client.send(b'\x05\x05\x00\x01' + b'\x00' * 6)
            client.close()
            proxy.close()
    except Exception as e:
        print(f"[SOCKS5] Error: {e}", flush=True)
        try: client.close()
        except: pass

def main():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(('0.0.0.0', LISTEN_PORT))
    server.listen(50)
    print(f"SOCKS5 bridge on port {LISTEN_PORT} (via HTTP proxy {HTTP_PROXY})", flush=True)
    
    while True:
        client, addr = server.accept()
        t = threading.Thread(target=handle_client, args=(client,))
        t.daemon = True
        t.start()

if __name__ == '__main__':
    main()
