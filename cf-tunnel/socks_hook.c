#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>

// Hook connect() 函数，把 7844 端口的连接重定向到 SOCKS5 代理
int connect(int sockfd, const struct sockaddr *addr, socklen_t addrlen) {
    static int (*real_connect)(int, const struct sockaddr *, socklen_t) = NULL;
    if (!real_connect) {
        real_connect = dlsym(RTLD_NEXT, "connect");
    }
    
    if (addr->sa_family == AF_INET) {
        struct sockaddr_in *sin = (struct sockaddr_in *)addr;
        int port = ntohs(sin->sin_port);
        
        // 如果是 7844 端口，重定向到 127.0.0.1:11080 (SOCKS5)
        if (port == 7844) {
            struct sockaddr_in proxy_addr;
            proxy_addr.sin_family = AF_INET;
            proxy_addr.sin_port = htons(11080);
            proxy_addr.sin_addr.s_addr = inet_addr("127.0.0.1");
            
            // 先连接到 SOCKS5 代理
            int ret = real_connect(sockfd, (struct sockaddr*)&proxy_addr, sizeof(proxy_addr));
            if (ret < 0) return ret;
            
            // 发送 SOCKS5 握手
            unsigned char hello[] = {0x05, 0x01, 0x00};
            send(sockfd, hello, 3, 0);
            
            unsigned char resp[2];
            recv(sockfd, resp, 2, 0);
            
            // 发送 CONNECT 请求
            unsigned char request[22];
            request[0] = 0x05; // version
            request[1] = 0x01; // connect
            request[2] = 0x00; // reserved
            request[3] = 0x01; // IPv4
            memcpy(request + 4, &sin->sin_addr, 4); // 目标 IP
            memcpy(request + 8, &sin->sin_port, 2); // 目标端口
            
            send(sockfd, request, 10, 0);
            
            unsigned char connect_resp[10];
            recv(sockfd, connect_resp, 10, 0);
            
            if (connect_resp[1] == 0x00) {
                return 0; // 成功
            } else {
                return -1;
            }
        }
    }
    
    return real_connect(sockfd, addr, addrlen);
}
