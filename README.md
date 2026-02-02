# mac-on-firecracker

Apple Silicon Mac에서 [Firecracker](https://github.com/firecracker-microvm/firecracker) MicroVM을 실행하는 가이드 및 스크립트.

## Lima가 필요한 이유

[Firecracker는 Linux의 KVM](https://github.com/firecracker-microvm/firecracker/blob/main/docs/getting-started.md#prerequisites)을 필요로 하기 때문에 macOS에서 직접 실행할 수 없습니다. 하지만 **macOS 15 + Apple Silicon (M3 이상)** 환경에서는 [Lima](https://lima-vm.io/)의 **중첩 가상화(nested virtualization)** 기능을 사용해 Linux VM 안에서 KVM을 활성화할 수 있습니다.

```
┌─────────────────────────────────────┐
│  macOS (Host)                       │
│  └── Lima (L1 Ubuntu VM)            │
│       └── Firecracker (L2 MicroVM)  │
└─────────────────────────────────────┘
```

## 요구사항

- **Apple Silicon Mac** M3 이상
- **macOS 15 (Sequoia)** 이상
- **[Lima](https://lima-vm.io/)** 2.0 이상

```bash
brew install lima
```

---

## 시작하기

두 가지 Phase로 구성됩니다:

| 경로 | 목표 | 난이도 |
|------|------|--------|
| **Phase 1** | Firecracker 기본 이해, MicroVM 실행 |
| **Phase 2** | MicroVM 내 컨테이너 실행 (firecracker-containerd) |

### Phase 1 vs Phase 2 핵심 차이

- **Phase 1**: Firecracker MicroVM을 직접 실행 (고정된 rootfs.ext4 부팅)
  - 비유: USB에 Linux 넣고 부팅하는 것
  - 새 소프트웨어 추가 시 rootfs 재빌드 필요
  - 중첩 가상화와 VM 위에서 Firecracker가 정상 동작하는지 검증하는 용도

- **Phase 2**: MicroVM 안에서 **OCI 컨테이너** 실행 (Docker 이미지 사용)
  - 비유: Docker로 alpine, nginx 등 실행하는 것
  - AWS Lambda, Fargate가 사용하는 방식

```
[공통 설정] ──┬──▶ [Phase 1] 기본 MicroVM 실행
              │
              └──▶ [Phase 2] MicroVM 내 컨테이너
```

**Phase 1과 Phase 2는 독립적**입니다. 서로 다른 디렉토리를 사용하므로 Phase 1을 먼저 해도 Phase 2에 영향 없습니다.

---

## 공통 설정 (필수)

Phase 1, Phase 2 모두 이 단계가 필요합니다.

### Step 1: 스크립트 권한 부여 (Mac 터미널)

```bash
chmod +x scripts/microvm/*.sh scripts/containerd/*.sh
```

### Step 2: Lima VM 생성 및 시작 (Mac 터미널)

```bash
limactl start --name fc-lab firecracker-lab.yaml
```

### Step 3: Lima 셸 진입

```bash
limactl shell fc-lab
```

### Step 4: Firecracker 설치 (Lima 셸)

```bash
./scripts/microvm/install-firecracker.sh
```

**여기까지 완료하면 Phase 1 또는 Phase 2를 선택하세요.**

---

## Phase 1: 기본 MicroVM 실행

Firecracker의 기본 동작을 이해하기 위한 단계입니다. 단순한 Linux VM을 MicroVM으로 실행합니다.

### Step 5: 커널·rootfs 다운로드 (Lima 셸)

```bash
./scripts/microvm/setup-microvm-images.sh
```

### Step 6: MicroVM 실행 (Lima 셸)

```bash
./scripts/microvm/start-microvm.sh
```

> 종료: MicroVM 안에서 `poweroff` 입력

### 한 줄 실행 (설치 완료 후)

Mac 터미널에서 바로 MicroVM까지 기동:
```bash
./scripts/microvm/start-from-host.sh
```

Lima 셸에서 바로 MicroVM 실행:
```bash
./scripts/microvm/start-microvm.sh
```

### Phase 1 스크립트 요약

| 스크립트 | 실행 위치 | 설명 |
|----------|-----------|------|
| `install-firecracker.sh` | Lima 셸 | Firecracker 바이너리 설치, `/dev/kvm` 권한 설정 |
| `setup-microvm-images.sh` | Lima 셸 | 커널·루트fs 다운로드, `vm_config.json` 생성 |
| `start-microvm.sh` | Lima 셸 | Firecracker MicroVM 실행 |
| `start-from-host.sh` | Mac 터미널 | Lima 기동 + MicroVM 실행 (한 번에) |

---

## Phase 2: MicroVM 내 컨테이너 실행

firecracker-containerd를 사용하면 MicroVM 내에서 Docker 이미지를 컨테이너로 실행할 수 있습니다.

```
┌─────────────────────────────────────────────────────┐
│  macOS (Host)                                       │
│  └── Lima (L1 Ubuntu VM)                            │
│       ├── firecracker-containerd (데몬)              │
│       └── Firecracker (L2 MicroVM)                  │
│            └── fc-agent → runC → Container          │
└─────────────────────────────────────────────────────┘
```

### 전제조건

- **공통 설정 (Step 1~4) 완료**
- Phase 1의 Step 5, 6은 **불필요** (Phase 2는 자체 커널/rootfs 사용)

### Step 5: firecracker-containerd 설치 (Lima 셸)

```bash
./scripts/containerd/install-fc-containerd.sh
```

### Step 6: CNI 플러그인 설치 (Lima 셸)

```bash
./scripts/containerd/setup-cni.sh
```

### Step 7: firecracker-containerd 데몬 시작 (Lima 셸, 터미널 1)

```bash
./scripts/containerd/start-fc-containerd.sh
```

이 터미널은 데몬이 점유합니다. 새 터미널을 열어 다음 단계를 진행하세요.

### Step 8: 컨테이너 실행 (Lima 셸, 터미널 2)

```bash
limactl shell fc-lab
./scripts/containerd/run-container.sh
```

정상 동작 시 MicroVM 내부의 컨테이너 셸이 열립니다:

```
/ # uname -a
Linux microvm 6.1.155 #1 SMP Tue Nov 18 09:22:35 UTC 2025 aarch64 Linux
```

### Phase 2 스크립트 요약

| 스크립트 | 실행 위치 | 설명 |
|----------|-----------|------|
| `install-fc-containerd.sh` | Lima 셸 | containerd + firecracker-containerd 빌드 및 설치 |
| `setup-cni.sh` | Lima 셸 | CNI 플러그인 설치 (tc-redirect-tap 포함) |
| `build-fc-rootfs.sh` | Lima 셸 | fc-agent 포함 rootfs 이미지 빌드 (선택) |
| `start-fc-containerd.sh` | Lima 셸 | firecracker-containerd 데몬 시작 |
| `run-container.sh` | Lima 셸 | MicroVM 내에서 컨테이너 실행 |

---

## Troubleshooting

### `/dev/kvm` 권한 오류

```
Kvm error: Error creating KVM object: Permission denied (os error 13)
```

**원인**: 현재 셸에 `kvm` 그룹이 반영되지 않음.

**해결**:
```bash
# 방법 1: 현재 셸에 그룹 적용
newgrp kvm

# 방법 2: Lima 셸 다시 접속
exit
limactl shell fc-lab
```

### Phase 2 바이너리를 찾을 수 없음

```
firecracker-containerd: command not found
```

**원인**: 빌드는 완료되었으나 바이너리가 PATH에 설치되지 않음.

**해결**:
```bash
cd ~/firecracker-containerd
sudo cp firecracker-control/cmd/containerd/firecracker-containerd /usr/local/bin/
sudo cp firecracker-control/cmd/containerd/firecracker-ctr /usr/local/bin/
sudo cp runtime/containerd-shim-aws-firecracker /usr/local/bin/
sudo chmod +x /usr/local/bin/firecracker-containerd /usr/local/bin/firecracker-ctr /usr/local/bin/containerd-shim-aws-firecracker
```

### Phase 2 vsock 타임아웃

```
failed to dial the VM over vsock: context deadline exceeded
```

**원인**: fc-agent 바이너리가 동적 링크로 빌드되어 rootfs(Debian 11, glibc 2.31) 내에서 glibc 버전 불일치로 실행 실패. agent가 시작되지 못하면 vsock listen이 안 되어 shim이 타임아웃됨.

**해결**: agent를 static 빌드하고 rootfs를 재생성:
```bash
cd ~/firecracker-containerd/agent
STATIC_AGENT=1 make clean && STATIC_AGENT=1 make agent
cd ~/firecracker-containerd
cp agent/agent tools/image-builder/files_ephemeral/usr/local/bin/
sg docker -c 'STATIC_AGENT=1 make image'
sudo cp tools/image-builder/rootfs.img /var/lib/firecracker-containerd/runtime/default-rootfs.img
```

> 현재 스크립트(`install-fc-containerd.sh`, `build-fc-rootfs.sh`)에는 이미 `STATIC_AGENT=1`이 적용되어 있으므로 스크립트로 설치한 경우 이 문제가 발생하지 않습니다.

자세한 디버깅 과정은 [docs/phase2-vsock-timeout-debugging.md](docs/phase2-vsock-timeout-debugging.md)를 참고하세요.

---

## NextPlan

### Phase 1: 기본 Firecracker (완료)

- [x] Lima + 중첩 가상화로 L1 Ubuntu VM 구성
- [x] Firecracker 바이너리 설치 (ARM64)
- [x] 커널 + rootfs 다운로드 및 MicroVM 실행

### Phase 2: firecracker-containerd (완료)

- [x] containerd + firecracker-containerd 설치 스크립트
- [x] CNI 네트워킹 설정 (tc-redirect-tap)
- [x] fc-agent 포함 rootfs 이미지 빌드 스크립트 (static agent)
- [x] 컨테이너 실행 테스트

### Phase 3: Medusa.js on MicroVM (예정)

- [ ] Medusa.js 3-tier 컨테이너 구동 (medusa, postgres, redis)
- [ ] microVM pause / snapshot / resume 테스트
- [ ] snapshot에서 새 MicroVM 복원 테스트

---

## 참고 자료

- [Firecracker GitHub](https://github.com/firecracker-microvm/firecracker)
- [firecracker-containerd](https://github.com/firecracker-microvm/firecracker-containerd)
- [firecracker-go-sdk](https://github.com/firecracker-microvm/firecracker-go-sdk)
- [Lima](https://lima-vm.io/)

## 라이선스

MIT
