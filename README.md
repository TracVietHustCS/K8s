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
confi
```

---

### Phase 2: Cài đặt Container Runtime - Containerd (Chạy trên CẢ 2 NODE)

K8s không tự chạy container, nó ra lệnh cho một phần mềm bên dưới (Container Runtime) làm việc đó. Ở chuẩn Production hiện nay, chúng ta dùng **`containerd`**.

```bash
# Cài đặt containerd
sudo apt-get update
sudo apt-get install -y containerd
vi c
# Tạo thư mục config cho containerd
sudo mkdir -p /etc/containerd

# Sinh file cấu hình mặc định
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null

```

**Cấu hình Cgroup Driver (RẤT QUAN TRỌNG):**
Linux quản lý tài nguyên CPU/RAM bằng `cgroups`. Ubuntu dùng `systemd` làm quản lý gốc. Kubelet mặc định cấu hình dùng `systemd`. Bạn phải chỉnh `containerd` cũng dùng `systemd`, nếu không sẽ xảy ra tình trạng "trống đánh xuôi kèn thổi ngược" khiến Node bị treo.
Trên Ubuntu/CentOS hiện đại: Hệ điều hành sử dụng systemd làm trình quản lý cgroup gốc (gọi là cgroup driver).

Vấn đề: Khi bạn chạy K8s, có hai thực thể cùng muốn quản lý tài nguyên của container:

Kubelet: (Thành phần của K8s trên Node) Mặc định nó muốn dùng systemd.

Container Runtime (containerd): Nếu để mặc định (false), nó sẽ dùng driver riêng của nó là cgroupfs.

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

```
echo 'deb [signed-by=...] https://pkgs.k8s.io/... /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
echo 'deb ...': Tạo ra một dòng văn bản chứa địa chỉ URL của kho phần mềm Kubernetes.

[signed-by=...]: Đây là đoạn quan trọng nhất. Nó bảo với hệ thống rằng: "Này apt, khi ông tải phần mềm từ cái link này, ông phải dùng đúng cái chìa khóa tui vừa để trong /etc/apt/keyrings/ để mở nhé!".
```

sudo tee /etc/apt/sources.list.d/kubernetes.list:

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
sudo kubeadm init \
  --apiserver-advertise-address=192.168.1.130 \
  --pod-network-cidr=192.168.0.0/16

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


Chào bạn, bước sang giai đoạn này, chúng ta chính thức biến một cụm K8s "trắng" thành một nền tảng sẵn sàng chạy ứng dụng.

Ở môi trường Cloud (AWS EKS, Google GKE), khi bạn tạo K8s, họ đã "lắp sẵn" cho bạn ổ cứng (AWS EBS) và Load Balancer. Nhưng với `kubeadm` trên máy ảo (bare-metal), cụm của bạn hiện tại **không biết cách tự cấp phát ổ cứng** và **không có cổng nào mở ra ngoài ở port 80/443**.

Dưới đây là tài liệu hướng dẫn cấu hình chuẩn Production cho bare-metal để giải quyết 2 vấn đề trên.

---

### Phần 1: Cài đặt Dynamic Storage Provisioner (Giải quyết bài toán Database)

**Tại sao phải cần?**
Khi deploy Postgres, nó sẽ yêu cầu một ổ cứng (Persistent Volume Claim - PVC) ví dụ: *"Cho tôi 10GB đĩa"*. Nếu không có Storage Provisioner, request này sẽ treo vĩnh viễn ở trạng thái `Pending`.

**Giải pháp:** Sử dụng **Rancher Local Path Provisioner**. Đây là giải pháp tiêu chuẩn, cực kỳ ổn định cho homelab. Nó tự động tạo các thư mục trên ổ cứng của Worker VM và "biến" chúng thành Persistent Volume (PV) cấp cho Pod.

**Thực thi (Chạy trên MASTER NODE):**

1. Cài đặt Local Path Provisioner từ manifest chính thức:

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.28/deploy/local-path-storage.yaml

```

2. Đặt nó làm StorageClass mặc định của toàn cụm. (Điều này giúp cấu hình GitOps sau này cực nhàn, bạn không cần phải khai báo tên StorageClass trong mọi file YAML nữa):

```bash
kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

```

3. Kiểm tra thành quả:

```bash
kubectl get storageclass
# Bạn sẽ thấy: local-path (default)   rancher.io/local-path ...

```

---

### Phần 2: Cài đặt Ingress Controller - Traefik (Giải quyết bài toán Network)

**Tại sao phải cần?**
Mặc định, K8s giấu mọi ứng dụng bên trong mạng nội bộ của nó. Để người dùng bên ngoài truy cập vào Frontend, Backend, hay Dify bằng tên miền (domain) qua port `80` (HTTP) hoặc `443` (HTTPS), bạn cần một "Người gác cổng" - đó chính là **Ingress Controller**.

**Thực thi:**

#### Bước 2.1: Cài đặt công cụ quản lý package Helm

Traefik và 99% các ứng dụng phức tạp sau này đều được đóng gói bằng Helm. Bạn hãy cài Helm lên Master Node:

```bash
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
sudo ./get_helm.sh

```

#### Bước 2.2: Chuẩn bị file cấu hình (Values) cho Traefik

**Lưu ý cực kỳ quan trọng cho Homelab:** Vì bạn không có Cloud Load Balancer, cách tốt nhất để mở port 80 và 443 cho Traefik trên bare-metal là sử dụng `hostPort`. Nó sẽ gắn trực tiếp cổng 80/443 của Traefik vào card mạng của Worker VM.

Tạo một file tên là `traefik-values.yaml` trên Master Node và dán nội dung sau vào:

```yaml
ports:
  web:
    port: 8000
    hostPort: 80      # Mở port 80 trực tiếp trên IP của Worker VM
  websecure:
    port: 8443
    hostPort: 443     # Mở port 443 trực tiếp trên IP của Worker VM
service:
  type: NodePort      # Bỏ qua LoadBalancer mặc định vì ta không dùng Cloud

```

#### Bước 2.3: Deploy Traefik bằng Helm

Chạy các lệnh sau để tải và cài đặt Traefik:

```bash
# Thêm kho lưu trữ của Traefik
helm repo add traefik https://traefik.github.io/charts
helm repo update

# Tạo một namespace riêng để dễ quản lý
kubectl create namespace traefik

# Cài đặt Traefik với file cấu hình ta vừa tạo
helm install traefik traefik/traefik -n traefik -f traefik-values.yaml

```

#### Bước 2.4: Kiểm tra thành quả

Chạy lệnh kiểm tra Pod của Traefik:

```bash
kubectl get pods -n traefik

```

Nếu Pod báo trạng thái `Running`, hãy mở trình duyệt web trên máy tính cá nhân của bạn và gõ IP của **Worker VM** (Ví dụ: `http://192.168.1.101`).
Nếu bạn nhận được thông báo lỗi `404 page not found` màu trắng đơn giản -> **Chúc mừng, bạn đã cấu hình thành công!** Traefik đã nhận được request nhưng nó báo 404 vì bạn chưa có ứng dụng nào (Frontend/Backend) để nó trỏ tới.

---

Đến đây, nền móng (Storage & Network) của cụm K8s đã hoàn thiện 100%. Mọi thứ đã sẵn sàng để tiếp nhận ứng dụng.

Bước tiếp theo trong bản đồ của chúng ta là **Dựng nguồn sự thật - Gitea Server**. Bạn muốn cài Gitea thẳng vào trong cụm K8s này (tối ưu tài nguyên), hay dựng trên một VM riêng biệt (tối ưu an toàn, K8s lỗi thì code vẫn còn)?
<img width="1024" height="559" alt="image" src="https://github.com/user-attachments/assets/d9e440f4-353d-4fca-9ab5-ca7948d32873" />


Your Kubernetes control-plane has initialized successfully!

To start using your cluster, you need to run the following as a regular user:

  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config

Alternatively, if you are the root user, you can run:

  export KUBECONFIG=/etc/kubernetes/admin.conf

You should now deploy a pod network to the cluster.
Run "kubectl apply -f [podnetwork].yaml" with one of the options listed at:
  https://kubernetes.io/docs/concepts/cluster-administration/addons/

Then you can join any number of worker nodes by running the following on each as root:

kubeadm join 192.168.1.130:6443 --token h8gw1u.keuvore02617jmw0 \
        --discovery-token-ca-cert-hash sha256:96bbaf04a65db274c2eeb31c2a96fe40806b0fd9b9c24bef5f71cae4ec5e3be3

        sudo kubeadm join <MASTER_IP>:6443 --token <token_cua_ban> \
        --discovery-token-ca-cert-hash sha256:<chuoi_hash_cua_ban>


flux bootstrap git \
  --url=http://123.16.178.213:2001/gitea/viet_admin/k8s-gitops.git \
  --branch=main \
  --path=clusters/my-cluster \
  --username=viet_admin \
  --password=670883e823e23c6e4ef5a7f09713fb746354f9e2 \
  --insecure-skip-tls-verify

  sync fluxcd ngay lap tuc: kubectl annotate externalsecret python-db-ext-secret -n backend force-sync=$(date +%s) --overwrite