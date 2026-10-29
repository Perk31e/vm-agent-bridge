# vm-agent-bridge

**AI 에이전트가 게스트 비밀번호를 한 번도 보지 않고도 실험용 VM을 제어하게 하는 방법.**

AI 코딩 에이전트(Claude Code, Codex, Cursor, Copilot 등)는 "이 스크립트를 VM에 복사해서 실행하고,
결과를 가져오고, 재부팅하고, 다시 확인해" 같은 일을 아주 잘합니다.
문제는 인증입니다. 모든 하이퍼바이저 CLI는 게스트 계정의 비밀번호를 요구하는데,
그 비밀번호가 에이전트의 채팅창, 프롬프트, 도구 호출을 한 번이라도 통과하면
내가 통제할 수 없는 대화 기록에 남습니다.

vm-agent-bridge는 그 문제를 푸는 작고 단순한 패턴입니다.

1. **사용자**가 자기 터미널에서, 자기가 고른(그리고 셋업 스크립트가 검증한) 디렉토리에,
   OS 자격 증명 저장소(Windows DPAPI, macOS 키체인, Linux Secret Service)로 게스트 자격 증명을 한 번 저장합니다.
2. **에이전트**는 얇은 래퍼(`run`, `push`, `pull`, `reboot`, `status`)만 호출합니다.
   래퍼가 자격 증명을 읽어 하이퍼바이저와 통신합니다. 에이전트는 파일을 읽지도, 비밀번호를 치지도, 출력에서 보지도 않습니다.
3. 바로 붙여 넣을 수 있는 [`PROMPT.md`](PROMPT.md)가 에이전트에게 규칙과 실제로 동작하는 패턴을 알려줍니다
   (핵심: 하이퍼바이저 CLI는 인라인 인수를 깨뜨리므로, 스크립트를 복사해 넣고 *그것을* 실행합니다).

이 패턴은 실제 디버깅 세션에서 나왔습니다. 에이전트가 VMware 게스트에 Windows 커널 디버거(KDNET)를
연결시키지 못했고, 해결하려면 게스트 *안에서* 수십 개의 명령을 실행해야 했습니다.
[docs/case-study-kdnet.md](docs/case-study-kdnet.md) 참고.

> 범위: 본인 PC에 있는 본인 소유의 실험/테스트 VM. 원격 관리 제품이 아니며 그러려고 하지도 않습니다.

## 지원 백엔드

| 백엔드 | 호스트 | 자격 증명 전달 경로 | 상태 |
|---|---|---|---|
| VMware Workstation / Fusion (`vmrun`) | Windows, macOS, Linux | 래퍼 → `vmrun -gu/-gp` | **검증됨** (Windows 호스트, Windows 11 게스트) |
| VirtualBox (`VBoxManage guestcontrol`) | Windows, macOS, Linux | 래퍼 → `--passwordfile` (잠긴 cred 디렉토리의 임시 파일) | 참조 구현, 미검증 |
| Hyper-V (PowerShell Direct) | Windows | `Invoke-Command -VMName -Credential` (평문 노출 없음) | 참조 구현, 미검증 |
| libvirt / QEMU (`virsh` + qemu-guest-agent) | Linux | 불필요 (게스트 에이전트가 root로 실행) | 참조 구현, 미검증 |

백엔드별 세부 사항과 주의점: [docs/backends.md](docs/backends.md).

## 빠른 시작 (Windows 호스트, VMware)

```powershell
# 1. 셋업은 반드시 사용자가 직접 실행합니다 (에이전트에게 맡기지 마세요).
#    자격 증명 보관 위치를 묻고, 디렉토리를 검증하고, ACL을 잠그고,
#    Windows 표준 자격 증명 대화상자를 띄워 DPAPI로 저장하고,
#    비밀이 아닌 config.json을 쓰고, 무해한 게스트 호출 한 번으로 검증합니다.
.\setup\windows\New-GuestCredential.ps1 -Backend vmware `
    -Vm "C:\Virtual Machines\Win11\Win11.vmx" -Profile user

# 관리자 작업용 두 번째 프로필 (선택)
.\setup\windows\New-GuestCredential.ps1 -Backend vmware `
    -Vm "C:\Virtual Machines\Win11\Win11.vmx" -Profile admin

# 2. PROMPT.md를 에이전트 지시문(CLAUDE.md, .cursorrules 등)에 붙여 넣습니다.

# 3. 이제 에이전트는 이렇게 일합니다:
.\backends\vmware\vmrun-guest.ps1 status
.\backends\vmware\vmrun-guest.ps1 job .\examples\collect-nic-info.ps1
.\backends\vmware\vmrun-guest.ps1 job .\my-admin-task.ps1 -Profile admin
.\backends\vmware\vmrun-guest.ps1 reboot
```

가장 많이 쓰게 될 명령은 `job`입니다. `.ps1`/`.sh`를 게스트의 공용 작업 폴더에 복사하고,
모든 출력을 로그로 리디렉션하는 작은 런처를 생성해 실행하고, 로그를 가져와 출력합니다.
따옴표 문제도, 사라지는 출력도 없습니다.

## 공통 인터페이스

모든 백엔드 스크립트는 같은 다섯 동사(와 `job`, `raw`)를 제공합니다.

| 동사 | 동작 |
|---|---|
| `status [-Profile p]` | VM이 켜져 있는지, 게스트 에이전트가 동작하는지, 자격 증명이 인증되는지 |
| `push <host> <guest>` | 파일을 게스트로 복사 |
| `pull <guest> <host>` | 파일을 게스트에서 가져오기 |
| `run <guest-script> [-NoWait]` | 이미 게스트 안에 있는 스크립트 실행 |
| `reboot` | 게스트 정상 재시작 |
| `job <host-script>` | push + 런처 생성 + run + 로그 pull을 한 번에 |
| `raw <args...>` | 자격 증명을 주입해 하이퍼바이저 CLI로 그대로 전달 |

`-Profile user`가 기본값이고, `-Profile admin`(또는 셋업 때 정의한 이름)으로 다른 자격 증명을 선택합니다.

## 파일 위치

| 항목 | 기본 위치 | 비밀? |
|---|---|---|
| 자격 증명 파일 / 키체인 항목 | **셋업 때 사용자가 선택.** 추천: `%LOCALAPPDATA%\vm-agent-bridge\creds` (Windows), `~/.config/vm-agent-bridge/creds` (Unix) | **예** |
| `config.json` (백엔드, VM 식별자, cred 디렉토리, 프로필 → 사용자명/참조) | `%LOCALAPPDATA%\vm-agent-bridge\config.json` 또는 `~/.config/vm-agent-bridge/config.json`, `VM_AGENT_BRIDGE_CONFIG`로 재정의 | 아니오 |
| 게스트 작업 폴더 | `C:\Users\Public\vm-agent-bridge` (Windows 게스트), `/tmp/vm-agent-bridge` (Linux 게스트) | 아니오 |

셋업 스크립트는 Git 리포지토리 안, 클라우드 동기화 폴더(OneDrive, Dropbox, Google Drive, iCloud) 안,
본인 소유가 아닌 디렉토리를 거부하고, 상속 권한을 제거해 본인과 SYSTEM만 읽을 수 있게 만듭니다.
각 규칙의 이유: [docs/credential-model.md](docs/credential-model.md).

## 솔직한 한계

- `vmrun`과 `VBoxManage`는 비밀번호를 자기 명령줄이나 파일로 받습니다. 래퍼가 실행되는 동안
  로컬 관리자는 프로세스 목록에서 그것을 읽을 수 있습니다. 이 패턴은 **에이전트와 그 대화 기록**으로부터
  보호하는 것이고, 침해된 호스트로부터 보호하는 것이 아닙니다. Hyper-V PowerShell Direct에는 이런 노출이 없습니다.
- 에이전트는 래퍼를 통해 게스트를 완전히 제어합니다. 게스트 계정 권한을 그에 맞게 설계하세요
  (일상 작업은 비관리자 프로필, 관리자 프로필은 필요할 때만).
- VMware/Windows 경로만 끝까지 실제로 실행해 봤습니다. 나머지는 공식 CLI 문서를 기준으로 작성했고
  그렇게 표시했습니다. 검증하셨다면 이슈나 PR을 열어 주세요.

## 라이선스

MIT. [LICENSE](LICENSE) 참고.
