# Advanced CloudNativePG Setup Guide: Disaster Recovery & Node Scheduling

Since you have already installed the CloudNativePG Helm chart, this guide focuses on deploying a highly resilient PostgreSQL cluster with **Disaster Recovery (S3 Backups)** and **Dedicated Node Scheduling (Taints & Tolerations)**.

---

## 🧠 Advanced Concepts

### 1. Taints and Tolerations (Node Isolation)
Trong Kubernetes, nếu bạn muốn dành riêng một Node vật lý chỉ để chạy Database (nhằm đảm bảo hiệu năng RAM/CPU không bị ảnh hưởng bởi Gitea hay ứng dụng khác), bạn sử dụng **Taint**.
- **Taint (Vết nhơ):** Đánh dấu lên Node, ví dụ: "Node này chỉ dành cho DB, Pod nào không có giấy phép thì không được chạy ở đây".
- **Toleration (Sự chịu đựng):** Cấp giấy phép cho Pod của DB để nó có thể vượt qua Taint và chạy trên Node đó.

### 2. Disaster Recovery (S3 & Barman)
CloudNativePG sử dụng công cụ **Barman** tích hợp sẵn để sao lưu lên S3.
- **Physical Backup (Base Backup + WAL):** CNPG liên tục đẩy các file nhật ký giao dịch (WAL) lên S3. Nếu server cháy, bạn có thể khôi phục lại dữ liệu chính xác đến từng giây (Point-In-Time Recovery - PITR).
- **Logical Backup (pg_dump):** Việc dump dữ liệu ra file `.sql` mỗi ngày là một lớp bảo vệ bổ sung, giúp bạn dễ dàng chuyển dữ liệu sang môi trường khác.

---

## 🚀 Step-by-Step Advanced Setup

### Step 1: Chuẩn bị Node (Taint Node)
Đầu tiên, bạn cần đánh dấu (taint) một Worker node dành riêng cho Database. Chạy lệnh này trên master node (thay `worker-node-1` bằng tên node thực tế của bạn):

```bash
# Đánh dấu node này dành riêng cho database, cấm các Pod khác nhảy vào
kubectl taint nodes worker-node-1 database=true:NoSchedule

# (Tùy chọn) Đánh nhãn (Label) để chắc chắn Pod chạy đúng vào node này
kubectl label nodes worker-node-1 node-role.kubernetes.io/database=true
```

### Step 2: Tạo Secret cho S3 Credentials
Bạn cần tạo một Secret chứa thông tin đăng nhập S3 (MinIO, AWS S3, Cloudflare R2, v.v.).

```bash
kubectl create namespace gitea

kubectl create secret generic aws-creds \
  --from-literal=ACCESS_KEY_ID='your-s3-access-key' \
  --from-literal=ACCESS_SECRET_KEY='your-s3-secret-key' \
  --namespace gitea
```

### Step 3: Triển khai Cluster với Tolerations và S3 Backup
Tạo file `gitea-db-cluster.yaml`. File này bao gồm cấu hình HA, Backup S3 liên tục (WAL) và Node Scheduling.

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: gitea-db
  namespace: gitea
spec:
  instances: 3 # Khuyến cáo 3 node để đảm bảo HA
  imageName: ghcr.io/cloudnative-pg/postgresql:16
  
  # ---------------------------------------------
  # 1. NODE SCHEDULING (Taints & Tolerations)
  # ---------------------------------------------
  affinity:
    nodeSelector:
      node-role.kubernetes.io/database: "true" # Chỉ định Node đã label
      
  tolerations:
    - key: "database"
      operator: "Equal"
      value: "true"
      effect: "NoSchedule" # Cấp phép cho Pod này vượt qua Taint của Node

  # ---------------------------------------------
  # 2. STORAGE CONFIGURATION
  # ---------------------------------------------
  storage:
    size: 20Gi
    # storageClass: local-path

  # ---------------------------------------------
  # 3. DISASTER RECOVERY (S3 WAL Archiving)
  # ---------------------------------------------
  backup:
    barmanObjectStore:
      destinationPath: "s3://your-bucket-name/cnpg-backups/"
      endpointURL: "https://s3.your-provider.com" # Đổi URL nếu dùng MinIO/R2
      s3Credentials:
        accessKeyId:
          name: aws-creds
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: aws-creds
          key: ACCESS_SECRET_KEY
      # Tự động nén và quản lý WAL
      wal:
        compression: gzip
```

Apply cấu hình:
```bash
kubectl apply -f gitea-db-cluster.yaml
```

### Step 4: Đặt lịch Backup vật lý (Base Backup) mỗi ngày
CNPG sẽ tự đẩy WAL lên S3, nhưng bạn cần một Base Backup mỗi ngày làm mốc. Tạo file `scheduled-backup.yaml`:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: gitea-db-daily-backup
  namespace: gitea
spec:
  schedule: "0 0 2 * * *" # Chạy vào 2:00 AM mỗi ngày
  backupOwnerReference: self
  cluster:
    name: gitea-db
```

Apply cấu hình:
```bash
kubectl apply -f scheduled-backup.yaml
```

### Step 5: (Tùy chọn) Script Dump Data Logical (.sql) mỗi ngày
Dù CNPG đã có Barman lo việc backup vật lý (PITR), nếu bạn vẫn muốn có 1 file dump `.sql` thuần túy đẩy lên S3 mỗi ngày, cách tốt nhất trong K8s là dùng **CronJob**.

Tạo file `logical-dump-cronjob.yaml`:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: gitea-db-logical-dump
  namespace: gitea
spec:
  schedule: "30 2 * * *" # Chạy vào 2:30 AM mỗi ngày
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: pg-dump-s3
            image: bitnami/postgresql:16 # Chứa tool pg_dump
            env:
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: gitea-db-superuser
                  key: password
            - name: S3_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: aws-creds
                  key: ACCESS_KEY_ID
            - name: S3_SECRET_KEY
              valueFrom:
                secretKeyRef:
                  name: aws-creds
                  key: ACCESS_SECRET_KEY
            command:
            - /bin/bash
            - -c
            - |
              echo "Bắt đầu dump dữ liệu..."
              pg_dump -h gitea-db-rw -U postgres gitea > /tmp/gitea-dump-$(date +%F).sql
              echo "Cài đặt AWS CLI..."
              apt-get update && apt-get install -y awscli
              echo "Upload lên S3..."
              AWS_ACCESS_KEY_ID=$S3_ACCESS_KEY AWS_SECRET_ACCESS_KEY=$S3_SECRET_KEY \
              aws s3 cp /tmp/gitea-dump-*.sql s3://your-bucket-name/logical-dumps/ --endpoint-url https://s3.your-provider.com
          restartPolicy: OnFailure
```

Apply CronJob:
```bash
kubectl apply -f logical-dump-cronjob.yaml
```

---

## 🛠️ Tổng kết kiến thức

1. **Tại sao phải dùng Taint/Toleration thay vì chỉ dùng NodeSelector?**
   - NodeSelector chỉ nói với Pod rằng: "Hãy đến node này". Nhưng nó KHÔNG cấm các Pod khác (như Gitea, Web server) nhảy vào node đó.
   - Taint nói với Node rằng: "Cấm tất cả, trừ những ai có thẻ (Toleration)". Kết hợp cả hai đảm bảo Node đó **chỉ** chạy Database.

2. **Tại sao lại cần cả `backup` (WAL) và `CronJob` (pg_dump)?**
   - **WAL (Vật lý):** Khôi phục (Restore) cực nhanh, có thể quay ngược thời gian chính xác tới một phút cụ thể (PITR) khi database bị hỏng hóc nặng.
   - **pg_dump (Logical):** Giúp bạn có một file `.sql` có thể đọc được bằng mắt thường, dễ dàng mang đi test ở máy tính cá nhân hoặc migrate sang một database ngoài K8s. Cả hai tạo thành chiến lược Disaster Recovery hoàn hảo.
  