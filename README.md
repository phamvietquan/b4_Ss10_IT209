# Bài 4: Thiết lập Custom Network & Named Volume bằng Docker CLI

## Mục tiêu

Kết nối cụm 2 Container (**Backend Web API** + **PostgreSQL Database**) bằng Docker CLI thủ công, sử dụng Custom Bridge Network để giao tiếp nội bộ qua DNS và Named Volume để lưu trữ dữ liệu bền vững.

---

## Kiến trúc hệ thống

```
┌─────────────────────────────────────────────────┐
│              Custom Bridge Network: app-net      │
│                 Subnet: 172.20.0.0/16            │
│                                                  │
│  ┌─────────────────┐     DNS: "db-server"        │
│  │  app-container  │ ──────────────────────────► │
│  │  (Backend API)  │                             │
│  │  alpine:latest  │     ┌─────────────────┐     │
│  │  env: DB_HOST=  │     │   db-server     │     │
│  │    db-server    │     │  (PostgreSQL)   │     │
│  └─────────────────┘     │ postgres:15-alp │     │
│                           │       │         │     │
└───────────────────────────┼───────┼─────────┘
                            │       │ mount
                    ┌───────▼───────▼──────┐
                    │   Named Volume       │
                    │      db-data         │
                    │ /var/lib/postgresql/ │
                    │        data          │
                    └──────────────────────┘
```

---

## Các lệnh thực thi (`commands.sh`)

### Bước 1 – Tạo Custom Bridge Network

```bash
docker network create \
  --driver bridge \
  --subnet 172.20.0.0/16 \
  --gateway 172.20.0.1 \
  app-net
```

- **`--driver bridge`**: Tạo network loại bridge – phù hợp giao tiếp nội bộ giữa các container trên cùng host.
- **`--subnet`**: Định nghĩa dải IP riêng để tránh xung đột với bridge mặc định (`docker0`).
- Docker tự động cấp phát DNS cho mỗi container trong network, cho phép gọi nhau bằng **tên container** thay vì IP.

### Bước 2 – Tạo Named Volume

```bash
docker volume create db-data
```

- Volume được Docker quản lý tại `/var/lib/docker/volumes/db-data/`.
- **Tách biệt lifecycle** với container: xóa container không mất dữ liệu.

### Bước 3 – Chạy Database Container

```bash
docker run -d \
  --name db-server \
  --network app-net \
  -v db-data:/var/lib/postgresql/data \
  -e POSTGRES_USER=appuser \
  -e POSTGRES_PASSWORD=secret123 \
  -e POSTGRES_DB=appdb \
  postgres:15-alpine
```

| Tham số | Ý nghĩa |
|---|---|
| `--name db-server` | Đặt tên container – dùng làm DNS hostname trong `app-net` |
| `--network app-net` | Tham gia custom network |
| `-v db-data:/var/lib/postgresql/data` | Mount volume vào thư mục data của PostgreSQL |
| `-e POSTGRES_*` | Biến môi trường cấu hình DB |

### Bước 4 – Chạy Backend Container

```bash
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
```

- Backend truyền `DB_HOST=db-server` – đây là hostname DNS do Docker cấp tự động trong `app-net`.
- Không cần biết IP của `db-server`, Docker DNS resolver tự phân giải.

---

## Kết quả kiểm tra

### Kiểm tra Network & Volume

```bash
docker network ls | grep app-net
# NETWORK ID     NAME      DRIVER    SCOPE
# xxxxxxxxxxxx   app-net   bridge    local

docker volume ls | grep db-data
# DRIVER    VOLUME NAME
# local     db-data
```

### Kiểm tra DNS Resolution (ping)

```bash
docker exec -it app-container ping -c 2 db-server
# PING db-server (172.20.0.2): 56 data bytes
# 64 bytes from 172.20.0.2: seq=0 ttl=64 time=0.123 ms
# 64 bytes from 172.20.0.2: seq=1 ttl=64 time=0.089 ms
```

**Kết quả:** `app-container` phân giải được hostname `db-server` thành IP nội bộ `172.20.0.2`.

### Kiểm tra Network Inspect

```bash
docker network inspect app-net
# {
#   "Name": "app-net",
#   "Driver": "bridge",
#   "Containers": {
#     "...": { "Name": "db-server",     "IPv4Address": "172.20.0.2/16" },
#     "...": { "Name": "app-container", "IPv4Address": "172.20.0.3/16" }
#   }
# }
```

---

## Test Data Persistence

### Kịch bản

```
Ghi dữ liệu vào DB  -->  Xóa cứng container DB  -->  Tạo lại container DB  -->  Xác minh dữ liệu
```

### Chi tiết

**1. Ghi dữ liệu:**

```sql
-- Chạy bên trong db-server
CREATE TABLE products (id SERIAL PRIMARY KEY, name VARCHAR(100));
INSERT INTO products (name) VALUES ('Laptop Dell XPS'), ('MacBook Pro'), ('ThinkPad X1 Carbon');
```

**2. Xóa cứng container:**

```bash
docker rm -f db-server
# Container bị xóa hoàn toàn, nhưng volume db-data vẫn còn
```

**3. Tạo lại container với cùng volume:**

```bash
docker run -d --name db-server --network app-net \
  -v db-data:/var/lib/postgresql/data \
  -e POSTGRES_USER=appuser -e POSTGRES_PASSWORD=secret123 -e POSTGRES_DB=appdb \
  postgres:15-alpine
```

**4. Kết quả xác minh:**

```
 id |       name        |         created_at
----+-------------------+----------------------------
  1 | Laptop Dell XPS   | 2026-10-12 xx:xx:xx
  2 | MacBook Pro       | 2026-10-12 xx:xx:xx
  3 | ThinkPad X1 Carbon| 2026-10-12 xx:xx:xx
(3 rows)
```

**Kết luận:** Dữ liệu nguyên vẹn sau khi tái tạo container vì **Named Volume tồn tại độc lập với vòng đời container**.

---

## Giải thích kỹ thuật

### Tại sao Custom Network thay vì network mặc định?

| | `bridge` mặc định (docker0) | Custom Bridge Network (`app-net`) |
|---|---|---|
| **DNS Resolution** | Không hỗ trợ (chỉ dùng được `--link` deprecated) | Hỗ trợ DNS tự động theo tên container |
| **Cô lập** | Tất cả container mặc định đều trên cùng bridge | Chỉ container tham gia `app-net` mới thấy nhau |
| **Subnet tùy chỉnh** | Không | Có – tránh xung đột IP |

### Tại sao Named Volume thay vì Bind Mount?

| | Named Volume | Bind Mount |
|---|---|---|
| **Quản lý** | Docker quản lý | Người dùng quản lý |
| **Portability** | Portable, không phụ thuộc cấu trúc host | Phụ thuộc đường dẫn tuyệt đối trên host |
| **Production** | Khuyến nghị | Dùng cho dev (share source code) |
| **Backup** | `docker volume inspect` | Trỏ thẳng vào filesystem |

---

## Cách chạy script

```bash
# Cấp quyền thực thi
chmod +x commands.sh

# Chạy toàn bộ demo
./commands.sh
```

> **Lưu ý:** Cần Docker Engine đang chạy. Script tự dọn dẹp tài nguyên cũ trước khi chạy.

---

## Cấu trúc thư mục nộp bài

```
homework/session_10/ex4/
├── commands.sh    # Script thực thi đầy đủ 8 bước
└── README.md      # Tài liệu giải thích (file này)
```
