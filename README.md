<img width="1200" height="675" alt="image" src="https://github.com/user-attachments/assets/2f69fd42-4757-47df-8d58-ee50ad1bc4c6" />




Dưới đây là **Runbook chi tiết** để dựng một cluster Kubernetes 2 node (1 Master, 1 Worker) bằng `kubeadm`. Trong mỗi bước, mình sẽ giải thích rõ tại sao chúng ta lại phải chạy lệnh đó.

---

### Phase 0: Chuẩn bị VM trên Proxmox

Trước khi gõ lệnh, bạn cần tạo 2 VMs trên giao diện Proxmox với cấu hình khuyến nghị sau. Dùng hệ điều hành **Ubuntu Server 22.04 LTS** hoặc **24.04 LTS**.

* **CPU:** Ít nhất 2 Cores. Ở mục *Type*, hãy chọn **`host`** thay vì `kvm64`. Lựa chọn này giúp VM nhận diện đầy đủ tập lệnh của CPU vật lý, tối ưu hiệu năng cho container.
* **RAM:** Ít nhất 4GB. Tắt tính năng *Ballooning* (K8s không thích việc RAM bị thu hồi đột ngột).
* **Disk:** 30GB+. Chọn *Bus/Device* là **SCSI**, bật **Discard** và **SSD emulation** để tăng tốc I/O.
* **Network:** Sử dụng **`vmbr0`** (Bridge mode) để VM có dải mạng nội bộ giống như máy tính của bạn.
* **Thiết lập IP Tĩnh:** Trong quá trình cài đặt Ubuntu, hãy gán IP tĩnh (Static IP) để các node không bị đổi IP khi khởi động lại.
* Node 1 (Master): `192.168.x.100` (Hostname: `k8s-master`)
* Node 2 (Worker): `192.168.x.101` (Hostname: `k8s-worker-1`)



---

### Phase 1: Chuẩn bị Hệ điều hành (Chạy trên CẢ 2 NODE)

Sau khi SSH vào cả 2 VM, hãy thực hiện các bước chuẩn bị môi trường chạy.

#### 1. Tắt Swap (Bộ nhớ ảo)

Kubernetes (cụ thể là `kubelet`) quản lý tài nguyên RAM cấp cho các Pod cực kỳ chặt chẽ. Nếu hệ thống dùng Swap, các thông số giám sát này bị sai lệch, dẫn đến ứng dụng chạy chậm hoặc crash không rõ nguyên nhân. Kubeadm sẽ từ chối cài đặt nếu swap đang bật.

```bash
# Tắt swap ngay lập tức cho session hiện tại
sudo swapoff -a

# Comment dòng chứa swap trong fstab để tắt vĩnh viễn sau khi khởi động lại
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

```

#### 2. Load Kernel Modules

K8s cần hệ điều hành hỗ trợ `overlay` (để xếp lớp file hệ thống của container) và `br_netfilter` (để bridge traffic mạng giữa các Pod).

```bash
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

```

#### 3. Cấu hình Sysctl cho Networking

Cho phép Linux forward các gói tin IP (điều kiện bắt buộc để router nội bộ của K8s hoạt động) và bắt `iptables` phải kiểm tra các luồng traffic đi qua bridge.

```bash
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

# Apply thay đổi ngay lập tức
sudo sysctl --system

```

---

### Phase 2: Cài đặt Container Runtime - Containerd (Chạy trên CẢ 2 NODE)

K8s không tự chạy container, nó ra lệnh cho một phần mềm bên dưới (Container Runtime) làm việc đó. Ở chuẩn Production hiện nay, chúng ta dùng **`containerd`**.

```bash
# Cài đặt containerd
sudo apt-get update
sudo apt-get install -y containerd

# Tạo thư mục config cho containerd
sudo mkdir -p /etc/containerd

# Sinh file cấu hình mặc định
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null

```

**Cấu hình Cgroup Driver (RẤT QUAN TRỌNG):**
Linux quản lý tài nguyên CPU/RAM bằng `cgroups`. Ubuntu dùng `systemd` làm quản lý gốc. Kubelet mặc định cấu hình dùng `systemd`. Bạn phải chỉnh `containerd` cũng dùng `systemd`, nếu không sẽ xảy ra tình trạng "trống đánh xuôi kèn thổi ngược" khiến Node bị treo.

```bash
# Sửa false thành true cho SystemdCgroup
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

# Khởi động lại dịch vụ
sudo systemctl restart containerd
sudo systemctl enable containerd

```

---

### Phase 3: Cài đặt Kubeadm, Kubelet, Kubectl (Chạy trên CẢ 2 NODE)

Đây là 3 công cụ cốt lõi. Chúng ta sẽ dùng repository phiên bản v1.30 (mới và ổn định).

```bash
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

# Tải Public Signing Key của Google (Repository mới)
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# Add Repository vào apt
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list

# Cài đặt các package
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl

# Khóa phiên bản lại để không bị update tự động khi chạy apt upgrade (gây lỗi lệch version)
sudo apt-mark hold kubelet kubeadm kubectl

```

---

### Phase 4: Khởi tạo Cluster (CHỈ CHẠY TRÊN MASTER NODE)

Đây là lúc Kubeadm cấu hình API Server, Controller, Scheduler và Database nội bộ (etcd).
*Thay `<MASTER_IP>` bằng IP của máy Master (ví dụ: `192.168.x.100`).*

```bash
sudo kubeadm init \
  --apiserver-advertise-address=<MASTER_IP> \
  --pod-network-cidr=192.168.0.0/16

```

* **`apiserver-advertise-address`**: Chỉ định IP mà K8s API sẽ lắng nghe (rất quan trọng trên máy có nhiều card mạng).
* **`pod-network-cidr`**: Dải IP ảo sẽ cấp cho các ứng dụng (Pod). Calico CNI mặc định dùng dải `192.168.0.0/16`.

Quá trình này mất khoảng 2-3 phút. Khi xong, nó sẽ in ra màn hình hướng dẫn và **một đoạn mã `kubeadm join...**`. Hãy copy đoạn mã đó ra Notepad.

Thiết lập quyền truy cập API cho tài khoản hiện tại (thay vì phải dùng root):

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

```

---

### Phase 5: Cài đặt Network Plugin CNI (CHỈ CHẠY TRÊN MASTER NODE)

Dù cluster đã chạy, các Node vẫn đang ở trạng thái `NotReady`. Bạn cần cài Calico để lo việc cấp IP và định tuyến mạng cho các Pod.

```bash
# Cài đặt Tigera Operator (Trình quản lý tự động của Calico)
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/tigera-operator.yaml

# Cài đặt các Custom Resources định nghĩa mạng
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/custom-resources.yaml

```

Bạn gõ lệnh `kubectl get pods -n calico-system -w` để theo dõi. Khi nào các pod chuyển sang `Running` là xong.

---

### Phase 6: Thêm Worker Node vào Cluster (CHỈ CHẠY TRÊN WORKER NODE)

Quay trở lại VM Worker. Dán câu lệnh `kubeadm join` mà bạn đã lưu ở Phase 4 vào terminal và chạy với quyền `sudo`. Nó sẽ trông giống như sau:

```bash
sudo kubeadm join <MASTER_IP>:6443 --token <token_cua_ban> \
        --discovery-token-ca-cert-hash sha256:<chuoi_hash_cua_ban>

```

Kubeadm trên Worker sẽ liên hệ với Master, xác thực qua token, kéo chứng chỉ bảo mật (TLS) về và tự động chạy dịch vụ kubelet để bắt đầu nhận lệnh từ Master.

---

### Phase 7: Kiểm tra thành quả (Chạy trên MASTER NODE)

Cuối cùng, gõ lệnh sau để kiểm tra:

```bash
kubectl get nodes

```

Bạn sẽ thấy cả 2 nodes (`k8s-master` và `k8s-worker-1`) hiển thị với STATUS là **Ready**. Chúc mừng bạn, bạn đã có một Cluster K8s tiêu chuẩn, sẵn sàng để setup GitOps và deploy Postgres/Dify ở các bước tiếp theo!
