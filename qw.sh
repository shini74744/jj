import os
import threading
import requests
import time
import random

# 获取VPS性能来自动选择线程数量
def get_optimal_threads():
    cpu_count = os.cpu_count()
    return cpu_count * 2  # 以CPU核心数的两倍作为默认线程数

# 随机选择测速地址
def get_random_speedtest_url():
    urls = [
        "http://ipv4.download.thinkbroadband.com/10MB.zip",  # 可下载测试文件
        "http://ipv4.speedtest.tele2.net/10MB.zip",  # 另一个测速地址
        "http://speed.hetzner.de/10MB.bin"  # Hetzner测速地址
    ]
    return random.choice(urls)

# 测试下载流量
def download_speed(url, thread_count):
    def download_chunk():
        try:
            response = requests.get(url, stream=True)
            for _ in response.iter_content(chunk_size=1024 * 1024):  # 每次下载1MB
                pass
        except Exception as e:
            print(f"Error in downloading: {e}")

    threads = []
    for _ in range(thread_count):
        thread = threading.Thread(target=download_chunk)
        threads.append(thread)
        thread.start()

    for thread in threads:
        thread.join()

# 测试上传流量
def upload_speed(url, thread_count):
    def upload_chunk():
        try:
            data = os.urandom(1024 * 1024)  # 每次上传1MB的随机数据
            response = requests.post(url, data=data)
        except Exception as e:
            print(f"Error in uploading: {e}")

    threads = []
    for _ in range(thread_count):
        thread = threading.Thread(target=upload_chunk)
        threads.append(thread)
        thread.start()

    for thread in threads:
        thread.join()

# 显示菜单并执行相应操作
def display_menu():
    print("===== VPS 流量消耗脚本 =====")
    print("1. 开始测速消耗")
    print("2. 退出")
    choice = input("请选择操作（1/2）: ")
    
    if choice == "1":
        # 选择线程数
        thread_count_input = input(f"请输入线程数量（默认根据VPS性能选择，当前推荐 {get_optimal_threads()}）：")
        thread_count = int(thread_count_input) if thread_count_input else get_optimal_threads()

        # 选择测速地址
        url_input = input(f"请输入测速地址（默认随机选择，当前选择 {get_random_speedtest_url()}）：")
        url = url_input if url_input else get_random_speedtest_url()

        # 选择上传还是下载
        mode_input = input("选择测速模式（1: 下载 2: 上传 3: 同时）: ")
        if mode_input == "1":
            print("开始下载测速...")
            download_speed(url, thread_count)
        elif mode_input == "2":
            print("开始上传测速...")
            upload_speed(url, thread_count)
        elif mode_input == "3":
            print("开始下载和上传测速...")
            download_thread = threading.Thread(target=download_speed, args=(url, thread_count))
            upload_thread = threading.Thread(target=upload_speed, args=(url, thread_count))
            download_thread.start()
            upload_thread.start()
            download_thread.join()
            upload_thread.join()
        else:
            print("无效选择，请重新运行程序。")
    
    elif choice == "2":
        print("退出程序。")
        exit()
    else:
        print("无效选择，请重新选择。")

if __name__ == "__main__":
    while True:
        display_menu()
