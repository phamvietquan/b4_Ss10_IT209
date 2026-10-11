#!/bin/bash
# =============================================================================
# Bài 4: Thiết lập Custom Network & Named Volume bằng Docker CLI
# Mục tiêu: Kết nối Backend Web API + PostgreSQL bằng Custom Bridge Network
# =============================================================================

set -e  # Dừng script nếu có lỗi

echo "============================================="
echo "  DOCKER CUSTOM NETWORK & NAMED VOLUME DEMO"
echo "============================================="

# -----------------------------------------------------------------------------
# BƯỚC 1: Dọn dẹp tài nguyên cũ (nếu có) để chạy lại từ đầu
# -----------------------------------------------------------------------------
echo ""
echo "[STEP 1] Dọn dẹp tài nguyên cũ..."

docker rm -f db-server app-container 2>/dev/null || true
docker network rm app-net 2>/dev/null || true
docker volume rm db-data 2>/dev/null || true

echo "  -> Cleanup hoàn tất."

# -----------------------------------------------------------------------------
# BƯỚC 2: Tạo Custom Bridge Network tên app-net
# -----------------------------------------------------------------------------
echo ""
echo "[STEP 2] Tạo Custom Bridge Network: app-net"

docker network create \
  --driver bridge \
  --subnet 172.20.0.0/16 \
  --gateway 172.20.0.1 \
  app-net

echo "  -> Network 'app-net' đã tạo thành công."
docker network ls | grep app-net

# -----------------------------------------------------------------------------
# BƯỚC 3: Tạo Named Volume tên db-data
# -----------------------------------------------------------------------------
echo ""
echo "[STEP 3] Tạo Named Volume: db-data"

docker volume create db-data

echo "  -> Volume 'db-data' đã tạo thành công."
docker volume ls | grep db-data

# -----------------------------------------------------------------------------
# BƯỚC 4: Khởi chạy Database Container (PostgreSQL 15 Alpine)
# - Tham gia network: app-net
# - Mount volume: db-data -> /var/lib/postgresql/data
# - Biến môi trường: POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB
# -----------------------------------------------------------------------------
echo ""
echo "[STEP 4] Khởi chạy PostgreSQL Database Container: db-server"

docker run -d \
  --name db-server \
  --network app-net \
  -v db-data:/var/lib/postgresql/data \
  -e POSTGRES_USER=appuser \
  -e POSTGRES_PASSWORD=secret123 \
  -e POSTGRES_DB=appdb \
  postgres:15-alpine

echo "  -> Container 'db-server' đã khởi chạy."
echo "  -> Chờ PostgreSQL sẵn sàng..."
sleep 8

# Kiểm tra container đang chạy
docker ps --filter "name=db-server" --format "table {{.Names}}\t{{.Status}}\t{{.Networks}}"

# -----------------------------------------------------------------------------
# BƯỚC 5: Khởi chạy Backend Container (app-container)
# - Tham gia cùng network: app-net
# - Kết nối DB bằng hostname "db-server" (DNS resolution nội bộ)
# - Dùng image alpine để test (thực tế thay bằng image ứng dụng)
# -----------------------------------------------------------------------------
echo ""
echo "[STEP 5] Khởi chạy Backend Container: app-container"

docker run -d \
  --name app-container \
  --network app-net \
  -e DB_HOST=db-server \
  -e DB_PORT=5432 \
  -e DB_USER=appuser \
  -e DB_PASSWORD=secret123 \
  -e DB_NAME=appdb \
  alpine:latest \
  sh -c "apk add --no-cache postgresql-client iputils > /dev/null 2>&1 && tail -f /dev/null"

echo "  -> Container 'app-container' đã khởi chạy."
echo "  -> Chờ backend container sẵn sàng..."
sleep 5

docker ps --filter "name=app-container" --format "table {{.Names}}\t{{.Status}}\t{{.Networks}}"

# -----------------------------------------------------------------------------
# BƯỚC 6: Kiểm tra DNS Resolution (ping db-server từ app-container)
# -----------------------------------------------------------------------------
echo ""
echo "[STEP 6] Kiểm tra DNS Resolution: ping db-server từ app-container"

docker exec app-container ping -c 2 db-server

echo "  -> DNS Resolution thành công! app-container nhận ra hostname 'db-server'."

# Kiểm tra network inspect
echo ""
echo "[STEP 6b] Inspect network app-net:"
docker network inspect app-net --format '{{range .Containers}}  Container: {{.Name}} | IP: {{.IPv4Address}}{{"\n"}}{{end}}'

# -----------------------------------------------------------------------------
# BƯỚC 7: TEST DATA PERSISTENCE
# Ghi dữ liệu vào PostgreSQL -> Xóa cứng container DB -> Tạo lại -> Xác minh
# -----------------------------------------------------------------------------
echo ""
echo "============================================="
echo "  TEST DATA PERSISTENCE"
echo "============================================="

# 7a. Thêm dữ liệu vào PostgreSQL
echo ""
echo "[STEP 7a] Thêm dữ liệu vào PostgreSQL..."

docker exec db-server psql -U appuser -d appdb -c "
CREATE TABLE IF NOT EXISTS products (
  id SERIAL PRIMARY KEY,
  name VARCHAR(100) NOT NULL,
  created_at TIMESTAMP DEFAULT NOW()
);
INSERT INTO products (name) VALUES ('Laptop Dell XPS'), ('MacBook Pro'), ('ThinkPad X1 Carbon');
SELECT * FROM products;
"

echo "  -> Dữ liệu đã ghi thành công vào volume db-data."

# 7b. Xóa cứng container DB
echo ""
echo "[STEP 7b] Xóa cứng container db-server (docker rm -f)..."

docker rm -f db-server

echo "  -> Container 'db-server' đã bị xóa hoàn toàn."
echo "  -> Volume 'db-data' vẫn còn tồn tại:"
docker volume ls | grep db-data

# 7c. Khởi chạy lại container DB MỚI gắn cùng volume db-data
echo ""
echo "[STEP 7c] Tạo lại container db-server MỚI với cùng volume db-data..."

docker run -d \
  --name db-server \
  --network app-net \
  -v db-data:/var/lib/postgresql/data \
  -e POSTGRES_USER=appuser \
  -e POSTGRES_PASSWORD=secret123 \
  -e POSTGRES_DB=appdb \
  postgres:15-alpine

echo "  -> Container 'db-server' mới đã khởi chạy."
echo "  -> Chờ PostgreSQL khởi động..."
sleep 10

# 7d. Xác minh dữ liệu không bị mất
echo ""
echo "[STEP 7d] Xác minh dữ liệu sau khi tái tạo container..."

docker exec db-server psql -U appuser -d appdb -c "SELECT * FROM products;"

echo ""
echo "  -> DATA PERSISTENCE VERIFIED! Dữ liệu nguyên vẹn sau khi tái tạo container."

# -----------------------------------------------------------------------------
# BƯỚC 8: Tổng kết kiểm tra
# -----------------------------------------------------------------------------
echo ""
echo "============================================="
echo "  TỔNG KẾT KIỂM TRA"
echo "============================================="

echo ""
echo ">> docker network ls | grep app-net:"
docker network ls | grep app-net

echo ""
echo ">> docker volume ls | grep db-data:"
docker volume ls | grep db-data

echo ""
echo ">> docker network inspect app-net (Containers):"
docker network inspect app-net --format '
Network Name : {{.Name}}
Driver       : {{.Driver}}
Subnet       : {{range .IPAM.Config}}{{.Subnet}}{{end}}
Containers   :{{range .Containers}}
  - {{.Name}} ({{.IPv4Address}}){{end}}'

echo ""
echo ">> Ping test cuối (app-container -> db-server):"
docker exec app-container ping -c 2 db-server

echo ""
echo "============================================="
echo "  HOÀN THÀNH! Tất cả bài kiểm tra PASSED."
echo "============================================="
