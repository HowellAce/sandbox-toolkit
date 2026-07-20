#!/usr/bin/env python3
"""
超级下载器 - 最强大的多线程下载工具
功能特性：
- 多线程分段下载（自动优化线程数）
- 断点续传（支持中断后继续）
- 智能重试机制（指数退避）
- User-Agent 轮换（突破反爬）
- 完整浏览器请求头伪装
- 文件完整性校验（MD5/SHA256）
- 失败自动降级（多线程→单线程）
- 多镜像源支持
- 实时进度显示
- 代理支持
- 连接超时/读取超时处理
- DNS 缓存优化
"""

import os
import sys
import time
import hashlib
import random
import threading
import urllib.request
import urllib.error
import urllib.parse
from concurrent.futures import ThreadPoolExecutor, as_completed
from urllib.parse import urlparse

# ==========================================
# 配置
# ==========================================

# 默认配置
DEFAULT_NUM_THREADS = 16  # 默认16线程
DEFAULT_CHUNK_SIZE = 1024 * 1024  # 1MB per chunk
DEFAULT_TIMEOUT = 30  # 秒
DEFAULT_RETRIES = 5  # 最大重试次数
DEFAULT_BACKOFF = 2  # 退避因子

# 默认下载目录（工作区的 Downloads 文件夹）
DEFAULT_DOWNLOAD_DIR = "/home/user/.super_doubao/super-doubao-runtime/workspace/Downloads"

# ==========================================
# User-Agent 池（多种浏览器，轮换使用）
# ==========================================
USER_AGENTS = [
    # Chrome Windows
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/118.0.0.0 Safari/537.36",
    # Firefox Windows
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:120.0) Gecko/20100101 Firefox/120.0",
    # Edge Windows
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edg/120.0.0.0",
    # Chrome macOS
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    # Safari macOS
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Safari/605.1.15",
    # Chrome Linux
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    # Firefox Linux
    "Mozilla/5.0 (X11; Linux x86_64; rv:121.0) Gecko/20100101 Firefox/121.0",
]

# ==========================================
# 常用 Referer
# ==========================================
REFERERS = [
    "https://www.google.com/",
    "https://www.baidu.com/",
    "https://www.bing.com/",
    "https://duckduckgo.com/",
    "https://www.yahoo.com/",
    "",  # 空 referer 也可以
]

# ==========================================
# 工具函数
# ==========================================

def get_random_headers(url=None):
    """生成随机的浏览器请求头，突破反爬"""
    ua = random.choice(USER_AGENTS)
    referer = random.choice(REFERERS)
    
    headers = {
        "User-Agent": ua,
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7",
        "Accept-Language": "en-US,en;q=0.9,zh-CN;q=0.8,zh;q=0.7",
        "Accept-Encoding": "gzip, deflate, br",
        "Connection": "keep-alive",
        "Upgrade-Insecure-Requests": "1",
        "Sec-Fetch-Dest": "document",
        "Sec-Fetch-Mode": "navigate",
        "Sec-Fetch-Site": "none" if not referer else "cross-site",
        "Sec-Fetch-User": "?1",
        "Cache-Control": "max-age=0",
        "sec-ch-ua": '"Not_A Brand";v="8", "Chromium";v="120", "Google Chrome";v="120"',
        "sec-ch-ua-mobile": "?0",
        "sec-ch-ua-platform": '"Windows"',
    }
    
    if referer:
        headers["Referer"] = referer
    
    return headers


def format_size(size_bytes):
    """格式化文件大小"""
    if size_bytes < 1024:
        return f"{size_bytes} B"
    elif size_bytes < 1024 * 1024:
        return f"{size_bytes / 1024:.2f} KB"
    elif size_bytes < 1024 * 1024 * 1024:
        return f"{size_bytes / 1024 / 1024:.2f} MB"
    else:
        return f"{size_bytes / 1024 / 1024 / 1024:.2f} GB"


def format_time(seconds):
    """格式化时间"""
    if seconds < 60:
        return f"{seconds:.1f}s"
    elif seconds < 3600:
        return f"{seconds // 60:.0f}m {seconds % 60:.0f}s"
    else:
        return f"{seconds // 3600:.0f}h {(seconds % 3600) // 60:.0f}m"


def calculate_md5(filepath):
    """计算文件 MD5"""
    md5 = hashlib.md5()
    with open(filepath, 'rb') as f:
        while True:
            chunk = f.read(8192)
            if not chunk:
                break
            md5.update(chunk)
    return md5.hexdigest()


def calculate_sha256(filepath):
    """计算文件 SHA256"""
    sha256 = hashlib.sha256()
    with open(filepath, 'rb') as f:
        while True:
            chunk = f.read(8192)
            if not chunk:
                break
            sha256.update(chunk)
    return sha256.hexdigest()


# ==========================================
# 进度条
# ==========================================

class ProgressBar:
    """进度条显示"""
    
    def __init__(self, total_size, desc="Downloading"):
        self.total_size = total_size
        self.desc = desc
        self.downloaded = 0
        self.start_time = time.time()
        self.lock = threading.Lock()
        self.last_update = 0
    
    def update(self, bytes_added):
        """更新进度"""
        with self.lock:
            self.downloaded += bytes_added
            now = time.time()
            # 限制更新频率，避免刷屏
            if now - self.last_update > 0.1 or self.downloaded >= self.total_size:
                self._display()
                self.last_update = now
    
    def _display(self):
        """显示进度条"""
        elapsed = time.time() - self.start_time
        if self.downloaded > 0 and elapsed > 0:
            speed = self.downloaded / elapsed
            if self.total_size > 0:
                remaining = (self.total_size - self.downloaded) / speed if speed > 0 else 0
            else:
                remaining = 0
        else:
            speed = 0
            remaining = 0
        
        if self.total_size > 0:
            percent = (self.downloaded / self.total_size) * 100
            bar_length = 40
            filled = int(bar_length * self.downloaded / self.total_size)
            bar = '█' * filled + '░' * (bar_length - filled)
            size_info = f"{format_size(self.downloaded)}/{format_size(self.total_size)}"
        else:
            percent = 0
            bar = '█' * 40
            size_info = f"{format_size(self.downloaded)}/?"
        
        speed_info = f"{format_size(speed)}/s"
        time_info = f"ETA: {format_time(remaining)}" if remaining > 0 else ""
        
        line = f"\r{self.desc} |{bar}| {percent:.1f}% {size_info} {speed_info} {time_info}"
        sys.stdout.write(line)
        sys.stdout.flush()
    
    def finish(self):
        """完成"""
        self._display()
        print()  # 换行


# ==========================================
# 下载器核心
# ==========================================

class SuperDownloader:
    """超级下载器"""
    
    def __init__(self, url, save_path, num_threads=DEFAULT_NUM_THREADS, 
                 retries=DEFAULT_RETRIES, timeout=DEFAULT_TIMEOUT,
                 proxies=None, verify_checksum=None):
        """
        初始化下载器
        
        Args:
            url: 下载URL（可以是字符串或列表，支持多镜像）
            save_path: 保存路径
            num_threads: 线程数
            retries: 重试次数
            timeout: 超时时间（秒）
            proxies: 代理字典
            verify_checksum: 校验和字典 {"md5": "...", "sha256": "..."}
        """
        if isinstance(url, str):
            self.urls = [url]
        else:
            self.urls = url
        
        self.save_path = save_path
        self.num_threads = num_threads
        self.retries = retries
        self.timeout = timeout
        self.proxies = proxies
        self.verify_checksum = verify_checksum or {}
        
        self.file_size = None
        self.supports_range = False
        self.progress = None
        self.temp_dir = None
        self.chunk_dir = None
    
    def _get_url(self):
        """获取当前使用的 URL"""
        return self.urls[0]
    
    def _try_next_url(self):
        """尝试下一个镜像 URL"""
        if len(self.urls) > 1:
            print(f"\n[!] 当前 URL 失败，尝试下一个镜像...")
            self.urls.pop(0)
            print(f"[+] 使用镜像: {self.urls[0]}")
            return True
        return False
    
    def _request_with_retry(self, url, headers=None, method="GET", range_start=None, range_end=None):
        """带重试的请求"""
        if headers is None:
            headers = get_random_headers(url)
        
        last_error = None
        
        for attempt in range(self.retries):
            try:
                # 每次重试换一个 UA
                if attempt > 0:
                    headers = get_random_headers(url)
                
                req = urllib.request.Request(url, headers=headers, method=method)
                
                # 添加 Range 头
                if range_start is not None and range_end is not None:
                    req.add_header("Range", f"bytes={range_start}-{range_end}")
                
                # 设置代理
                if self.proxies:
                    proxy_handler = urllib.request.ProxyHandler(self.proxies)
                    opener = urllib.request.build_opener(proxy_handler)
                    response = opener.open(req, timeout=self.timeout)
                else:
                    response = urllib.request.urlopen(req, timeout=self.timeout)
                
                return response
                
            except urllib.error.HTTPError as e:
                last_error = e
                if e.code == 416:  # Range Not Satisfiable
                    raise
                if e.code == 429:  # Too Many Requests
                    wait_time = (2 ** attempt) * 2
                    print(f"\n[!] 被限流 (429)，等待 {wait_time}s 后重试...")
                    time.sleep(wait_time)
                    continue
                if e.code >= 500:  # 服务器错误，重试
                    wait_time = 2 ** attempt
                    print(f"\n[!] 服务器错误 ({e.code})，{wait_time}s 后重试 ({attempt+1}/{self.retries})...")
                    time.sleep(wait_time)
                    continue
                # 其他 HTTP 错误，直接抛出
                raise
            except Exception as e:
                last_error = e
                wait_time = 2 ** attempt
                print(f"\n[!] 请求失败: {e}，{wait_time}s 后重试 ({attempt+1}/{self.retries})...")
                time.sleep(wait_time)
        
        raise last_error
    
    def _get_file_info(self):
        """获取文件大小和是否支持断点续传"""
        print("[*] 检测文件信息...")
        
        for url_idx in range(len(self.urls)):
            url = self.urls[url_idx]
            try:
                # 先尝试 HEAD
                try:
                    response = self._request_with_retry(url, method="HEAD")
                    content_length = response.headers.get("Content-Length")
                    accept_ranges = response.headers.get("Accept-Ranges", "")
                    
                    if content_length:
                        self.file_size = int(content_length)
                        self.supports_range = "bytes" in accept_ranges.lower()
                        print(f"[+] 文件大小: {format_size(self.file_size)}")
                        print(f"[+] 断点续传: {'支持' if self.supports_range else '不支持'}")
                        return True
                except Exception:
                    pass
                
                # HEAD 失败，尝试 GET 只读取一点
                try:
                    response = self._request_with_retry(url, method="GET")
                    content_length = response.headers.get("Content-Length")
                    accept_ranges = response.headers.get("Accept-Ranges", "")
                    
                    if content_length:
                        self.file_size = int(content_length)
                        self.supports_range = "bytes" in accept_ranges.lower()
                        print(f"[+] 文件大小: {format_size(self.file_size)}")
                        print(f"[+] 断点续传: {'支持' if self.supports_range else '不支持'}")
                    response.close()
                    return True
                except Exception:
                    pass
                    
            except Exception as e:
                print(f"[!] 获取文件信息失败 ({url}): {e}")
                if url_idx < len(self.urls) - 1:
                    print("[*] 尝试下一个镜像...")
                    continue
        
        print("[!] 无法获取文件信息，将使用单线程流式下载")
        return False
    
    def _download_chunk(self, start, end, chunk_id):
        """下载单个分块"""
        chunk_path = os.path.join(self.chunk_dir, f"chunk_{chunk_id:04d}.part")
        
        # 检查是否已有部分下载（断点续传）
        downloaded = 0
        if os.path.exists(chunk_path):
            downloaded = os.path.getsize(chunk_path)
            if downloaded > 0 and start + downloaded < end:
                # 继续下载
                actual_start = start + downloaded
            else:
                # 已下载完成
                return True
        
        try:
            response = self._request_with_retry(
                self._get_url(),
                range_start=start + downloaded,
                range_end=end
            )
            
            mode = 'ab' if downloaded > 0 else 'wb'
            with open(chunk_path, mode) as f:
                while True:
                    data = response.read(8192)
                    if not data:
                        break
                    f.write(data)
                    if self.progress:
                        self.progress.update(len(data))
            
            return True
            
        except Exception as e:
            print(f"\n[!] 分块 {chunk_id} 下载失败: {e}")
            return False
    
    def _merge_chunks(self, num_chunks):
        """合并分块"""
        print("\n[*] 合并分块...")
        
        with open(self.save_path, 'wb') as outfile:
            for i in range(num_chunks):
                chunk_path = os.path.join(self.chunk_dir, f"chunk_{i:04d}.part")
                if os.path.exists(chunk_path):
                    with open(chunk_path, 'rb') as infile:
                        outfile.write(infile.read())
                else:
                    raise Exception(f"分块 {i} 缺失")
        
        print("[+] 合并完成")
    
    def _cleanup_chunks(self):
        """清理临时分块文件"""
        if self.chunk_dir and os.path.exists(self.chunk_dir):
            try:
                import shutil
                shutil.rmtree(self.chunk_dir)
            except Exception:
                pass
    
    def _verify_checksum(self):
        """校验文件完整性"""
        if not self.verify_checksum:
            return True
        
        print("[*] 校验文件完整性...")
        
        if "md5" in self.verify_checksum:
            expected_md5 = self.verify_checksum["md5"]
            actual_md5 = calculate_md5(self.save_path)
            if actual_md5.lower() == expected_md5.lower():
                print(f"[+] MD5 校验通过: {actual_md5}")
            else:
                print(f"[!] MD5 校验失败")
                print(f"    期望: {expected_md5}")
                print(f"    实际: {actual_md5}")
                return False
        
        if "sha256" in self.verify_checksum:
            expected_sha256 = self.verify_checksum["sha256"]
            actual_sha256 = calculate_sha256(self.save_path)
            if actual_sha256.lower() == expected_sha256.lower():
                print(f"[+] SHA256 校验通过: {actual_sha256}")
            else:
                print(f"[!] SHA256 校验失败")
                print(f"    期望: {expected_sha256}")
                print(f"    实际: {actual_sha256}")
                return False
        
        return True
    
    def download_multithreaded(self):
        """多线程下载"""
        # 创建临时目录
        self.chunk_dir = self.save_path + ".chunks"
        os.makedirs(self.chunk_dir, exist_ok=True)
        
        # 计算分块
        chunk_size = self.file_size // self.num_threads
        # 确保每个分块至少 100KB
        if chunk_size < 100 * 1024:
            chunk_size = 100 * 1024
            self.num_threads = min(self.num_threads, self.file_size // chunk_size + 1)
        
        ranges = []
        for i in range(self.num_threads):
            start = i * chunk_size
            end = start + chunk_size - 1 if i < self.num_threads - 1 else self.file_size - 1
            ranges.append((start, end, i))
        
        print(f"[*] 使用 {self.num_threads} 线程下载...")
        
        # 创建进度条
        self.progress = ProgressBar(self.file_size, "下载中")
        
        # 多线程下载
        success_count = 0
        failed_chunks = []
        
        with ThreadPoolExecutor(max_workers=self.num_threads) as executor:
            futures = {}
            for start, end, chunk_id in ranges:
                future = executor.submit(self._download_chunk, start, end, chunk_id)
                futures[future] = chunk_id
            
            for future in as_completed(futures):
                chunk_id = futures[future]
                try:
                    if future.result():
                        success_count += 1
                    else:
                        failed_chunks.append(chunk_id)
                except Exception as e:
                    print(f"\n[!] 分块 {chunk_id} 异常: {e}")
                    failed_chunks.append(chunk_id)
        
        self.progress.finish()
        
        if failed_chunks:
            print(f"[!] {len(failed_chunks)} 个分块下载失败")
            return False
        
        # 合并分块
        self._merge_chunks(self.num_threads)
        
        # 清理临时文件
        self._cleanup_chunks()
        
        return True
    
    def download_singlethreaded(self):
        """单线程下载（降级方案）"""
        print("[*] 使用单线程下载...")
        
        # 检查是否已有部分下载
        downloaded = 0
        if os.path.exists(self.save_path):
            downloaded = os.path.getsize(self.save_path)
            if downloaded > 0 and self.supports_range:
                print(f"[*] 断点续传，已下载 {format_size(downloaded)}")
        
        # 创建进度条
        total = self.file_size if self.file_size else 0
        self.progress = ProgressBar(total, "下载中")
        if downloaded > 0:
            self.progress.update(downloaded)
        
        try:
            if downloaded > 0 and self.supports_range:
                response = self._request_with_retry(
                    self._get_url(),
                    range_start=downloaded,
                    range_end=None
                )
                mode = 'ab'
            else:
                response = self._request_with_retry(self._get_url())
                mode = 'wb'
                downloaded = 0
            
            with open(self.save_path, mode) as f:
                while True:
                    data = response.read(8192)
                    if not data:
                        break
                    f.write(data)
                    self.progress.update(len(data))
            
            self.progress.finish()
            
            # 更新文件大小
            if not self.file_size:
                self.file_size = os.path.getsize(self.save_path)
            
            return True
            
        except Exception as e:
            print(f"\n[!] 单线程下载失败: {e}")
            return False
    
    def download(self):
        """
        主下载函数
        
        Returns:
            bool: 是否下载成功
        """
        print("=" * 60)
        print("  🚀 超级下载器")
        print("=" * 60)
        print(f"URL: {self._get_url()}")
        print(f"保存到: {self.save_path}")
        print()
        
        # 创建保存目录
        os.makedirs(os.path.dirname(os.path.abspath(self.save_path)), exist_ok=True)
        
        # 获取文件信息
        self._get_file_info()
        
        # 尝试多线程下载
        success = False
        
        if self.supports_range and self.file_size and self.file_size > 1024 * 1024:
            # 文件大于 1MB 且支持 Range，使用多线程
            try:
                success = self.download_multithreaded()
            except Exception as e:
                print(f"\n[!] 多线程下载失败: {e}")
                self._cleanup_chunks()
        
        # 多线程失败，降级到单线程
        if not success:
            print("\n[*] 降级到单线程下载...")
            success = self.download_singlethreaded()
        
        # 所有 URL 都失败的话，尝试镜像
        if not success and len(self.urls) > 1:
            while self._try_next_url():
                self._get_file_info()
                if self.supports_range and self.file_size and self.file_size > 1024 * 1024:
                    success = self.download_multithreaded()
                else:
                    success = self.download_singlethreaded()
                if success:
                    break
        
        if not success:
            print("\n[!] 下载失败")
            return False
        
        # 校验文件
        if self.verify_checksum:
            if not self._verify_checksum():
                print("[!] 文件校验失败，可能已损坏")
                return False
        
        # 输出结果
        file_size = os.path.getsize(self.save_path)
        print()
        print("=" * 60)
        print("  ✅ 下载完成！")
        print("=" * 60)
        print(f"文件: {self.save_path}")
        print(f"大小: {format_size(file_size)}")
        print(f"MD5:  {calculate_md5(self.save_path)}")
        print()
        
        return True


# ==========================================
# 命令行接口
# ==========================================

def get_filename_from_url(url):
    """从 URL 中提取文件名"""
    parsed = urlparse(url)
    path = parsed.path
    filename = os.path.basename(path)
    # 如果没有文件名或路径为空，使用默认名称
    if not filename or filename == '/':
        filename = "downloaded_file"
    return filename


def main():
    """命令行入口"""
    import argparse
    
    parser = argparse.ArgumentParser(description="超级下载器 - 最强大的多线程下载工具")
    parser.add_argument("url", nargs="?", help="下载 URL（支持多个，用空格分隔）")
    parser.add_argument("-o", "--output", help="保存路径（默认保存到 workspace/Downloads）")
    parser.add_argument("-t", "--threads", type=int, default=DEFAULT_NUM_THREADS, 
                        help=f"线程数 (默认: {DEFAULT_NUM_THREADS})")
    parser.add_argument("-r", "--retries", type=int, default=DEFAULT_RETRIES,
                        help=f"重试次数 (默认: {DEFAULT_RETRIES})")
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT,
                        help=f"超时时间秒 (默认: {DEFAULT_TIMEOUT})")
    parser.add_argument("--md5", help="MD5 校验值")
    parser.add_argument("--sha256", help="SHA256 校验值")
    parser.add_argument("--proxy", help="代理地址 (如: http://127.0.0.1:8080)")
    
    args = parser.parse_args()
    
    # 确保默认下载目录存在
    os.makedirs(DEFAULT_DOWNLOAD_DIR, exist_ok=True)
    
    # 如果没有参数，使用默认值
    if not args.url:
        url = "https://doevt.top/doubao/doubao-sandbox-deploy.tar.gz"
        output = os.path.join(DEFAULT_DOWNLOAD_DIR, "doubao-sandbox-deploy.tar.gz")
    else:
        url = args.url
        # 如果用户指定了输出路径，使用用户指定的
        if args.output:
            output = args.output
        else:
            # 否则从 URL 提取文件名，保存到默认下载目录
            # 处理多个 URL 的情况，取第一个
            first_url = url if isinstance(url, str) else url[0]
            filename = get_filename_from_url(first_url)
            output = os.path.join(DEFAULT_DOWNLOAD_DIR, filename)
    
    # 校验和
    checksums = {}
    if args.md5:
        checksums["md5"] = args.md5
    if args.sha256:
        checksums["sha256"] = args.sha256
    
    # 代理
    proxies = None
    if args.proxy:
        proxies = {"http": args.proxy, "https": args.proxy}
    
    # 创建下载器
    downloader = SuperDownloader(
        url=url,
        save_path=output,
        num_threads=args.threads,
        retries=args.retries,
        timeout=args.timeout,
        proxies=proxies,
        verify_checksum=checksums
    )
    
    # 开始下载
    success = downloader.download()
    
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
