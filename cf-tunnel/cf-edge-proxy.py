#!/usr/bin/env python3
"""
Cloudflare Edge 代理
在 127.0.0.1:7844 监听，通过 HTTP 代理转发到真正的 Cloudflare 边缘服务器
"""
import socket, threading, struct

HTTP_PROXY = ('127.0.0.1', 18080)
LISTEN_ADDR = ('127.0.0.1', 7844)
# Cloudflare 边缘服务器 IP 列表
CF_EDGE_IPS = [
    '198.41.192.37', '198.41.192.107', '198.41.192.167', '198.41.192.227',
    '198.41.200.53', '198.41.200.63', '198.41.200.73', '198.41.200.83',
]
current_ip = 0

def handle_client(client):
    global current_ip
    target_ip = CF_EDGE_IPS[current_ip % len(CF_EDGE_IPS)]
    current_ip += 1
    target = f"{target_ip}:7844"
    
    try:
        print(f"[EDGE] 转发到 {target}", flush=True)
        
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
                print(f"[EDGE] 代理无响应", flush=True)
                client.close()
                return
            response += chunk
        
        if b'200' in response.split(b'\r\n')[0]:
            print(f"[EDGE] 隧道建立成功 {target}", flush=True)
            
            # 双向转发
            def forward(src, dst):
                try:
                    while True:
                        data = src.recv(65536)
                        if not data:
                            break
                        dst.send(data)
                except Exception as e:
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
            print(f"[EDGE] 代理拒绝 {target}: {response.decode()[:100]}", flush=True)
            client.close()
            proxy.close()
    except Exception as e:
        print(f"[EDGE] 错误: {e}", flush=True)
        try: client.close()
        except: pass

def main():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(LISTEN_ADDR)
    server.listen(50)
    print(f"CF Edge proxy on {LISTEN_ADDR[0]}:{LISTEN_ADDR[1]} (via HTTP proxy)", flush=True)
    print(f"边缘 IP 列表: {CF_EDGE_IPS}", flush=True)
    
    while True:
        client, addr = server.accept()
        t = threading.Thread(target=handle_client, args=(client,))
        t.daemon = True
        t.start()

if __name__ == '__main__':
    main()
