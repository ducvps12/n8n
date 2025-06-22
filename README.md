# Cách sử dụng
1. Cài đặt công cụ
Chạy lệnh sau để cài đặt công cụ:

sudo bash install.sh
hoặc có thể chạy 1 lệnh duy nhất sau (ưu tiên hơn)

sudo bash -c 'URL=https://cloudfly.vn/download/n8n-host/install.sh && if [ -f /usr/bin/curl ];then curl -ksSO $URL ;else wget --no-check-certificate -O install.sh $URL;fi;bash install.sh'
2. Các chức năng chính
Sau khi cài đặt, bạn có thể sử dụng công cụ bằng cách chạy lệnh:

n8n-host
Công cụ sẽ hiển thị menu chính với các chức năng sau:

Số	Chức năng
1	Cài đặt N8N
2	Thay đổi tên miền
3	Nâng cấp phiên bản N8N
4	Tắt xác thực 2 bước (2FA/MFA)
5	Đặt lại thông tin đăng nhập
6	Export tất cả (workflows & credentials)
7	Import workflows & credentials từ template
8	Lấy thông tin Redis
9	Xóa N8N và cài đặt lại
3. Hướng dẫn sử dụng các chức năng
Cài đặt N8N
Chọn 1) Cài đặt N8N từ menu.
Nhập tên miền bạn muốn sử dụng (ví dụ: n8n.example.com).
Công cụ sẽ tự động cài đặt và cấu hình N8N trên server.
Thay đổi tên miền
Chọn 2) Thay đổi tên miền từ menu.
Nhập tên miền mới.
Công cụ sẽ cập nhật cấu hình và cấp lại chứng chỉ SSL.
Nâng cấp phiên bản N8N
Chọn 3) Nâng cấp phiên bản N8N từ menu.
Công cụ sẽ tải phiên bản mới nhất từ Docker Hub và khởi động lại N8N.
Tắt xác thực 2 bước (2FA/MFA)
Chọn 4) Tắt xác thực 2 bước (2FA/MFA) từ menu.
Nhập email của tài khoản cần tắt 2FA.
Công cụ sẽ thực hiện tắt 2FA cho tài khoản.
Đặt lại thông tin đăng nhập
Chọn 5) Đặt lại thông tin đăng nhập từ menu.
Công cụ sẽ reset thông tin tài khoản owner và yêu cầu tạo lại tài khoản khi truy cập N8N.
Export tất cả (workflows & credentials)
Chọn 6) Export tất cả (workflows & credentials) từ menu.
Công cụ sẽ xuất dữ liệu và cung cấp đường dẫn tải xuống.
Import workflows & credentials từ template
Chọn 7) Import workflows & credentials từ menu.
Công cụ sẽ import dữ liệu từ file template import-workflow-credentials.json.
Lấy thông tin Redis
Chọn 8) Lấy thông tin Redis từ menu.
Công cụ sẽ hiển thị thông tin kết nối Redis.
Xóa N8N và cài đặt lại
Chọn 9) Xóa N8N và cài đặt lại từ menu.
Công cụ sẽ xóa toàn bộ dữ liệu và cài đặt lại N8N từ đầu.
4. Gỡ bỏ công cụ
Để gỡ bỏ công cụ, chạy lệnh:

n8n-host --uninstall
