Hướng dẫn sử dụng công cụ n8n-host
1. Cài đặt công cụ
Cách 1: Dùng script cài đặt thủ công


sudo bash install.sh
Cách 2 (khuyến nghị): Cài đặt nhanh bằng một dòng lệnh

sudo bash -c 'URL=https://raw.githubusercontent.com/ducvps12/n8n/refs/heads/main/install.sh && if [ -f /usr/bin/curl ]; then curl -ksSO $URL; else wget --no-check-certificate -O install.sh $URL; fi; bash install.sh'

2. Chức năng chính
Sau khi cài đặt, chạy lệnh bên dưới để sử dụng công cụ:


n8n-host
Menu chức năng sẽ hiển thị gồm:

STT	Chức năng
1	Cài đặt N8N
2	Thay đổi tên miền
3	Nâng cấp phiên bản N8N
4	Tắt xác thực 2 bước (2FA/MFA)
5	Đặt lại thông tin đăng nhập
6	Xuất toàn bộ workflows & credentials
7	Nhập workflows & credentials từ template
8	Lấy thông tin Redis
9	Xóa và cài đặt lại N8N

3. Hướng dẫn chi tiết từng chức năng
1. Cài đặt N8N
Chọn 1 → Nhập tên miền (ví dụ: n8n.example.com) → Công cụ sẽ tự động cài và cấu hình N8N.

2. Thay đổi tên miền
Chọn 2 → Nhập tên miền mới → Công cụ sẽ cập nhật cấu hình và cấp lại SSL.

3. Nâng cấp phiên bản N8N
Chọn 3 → Công cụ sẽ tải phiên bản mới nhất từ Docker Hub và khởi động lại N8N.

4. Tắt xác thực 2 bước (2FA/MFA)
Chọn 4 → Nhập email tài khoản cần tắt → Công cụ sẽ thực hiện tắt 2FA.

5. Đặt lại thông tin đăng nhập
Chọn 5 → Reset tài khoản owner → Hệ thống sẽ yêu cầu tạo lại tài khoản khi truy cập.

6. Export toàn bộ workflows & credentials
Chọn 6 → Công cụ sẽ xuất dữ liệu và hiển thị link tải.

7. Import từ template
Chọn 7 → Import dữ liệu từ file import-workflow-credentials.json.

8. Lấy thông tin Redis
Chọn 8 → Công cụ hiển thị thông tin kết nối Redis.

9. Xóa và cài đặt lại N8N
Chọn 9 → Xóa toàn bộ dữ liệu và tiến hành cài đặt lại N8N từ đầu.

4. Gỡ bỏ công cụ
Để gỡ bỏ hoàn toàn công cụ, chạy:

n8n-host --uninstall
