# RedxKey Bean Doser for Decaid

A Decaid plugin that drives RedxKey bean dosing modules over BLE. Each module
holds one bean hopper and appears in Decaid as a sensor with a `dispense`
command.

## How it works

- Matched by an advertised name that contains `RedXKey`, compared without case.
- Decaid scans for modules and connects them. The connection stays open, and a
  dispense writes two bytes on it:
  1. the weight in tenths of a gram, one byte, to `C8D1D213-E353-4C68-A9F6-91EB50B95F8C`;
  2. after 300 ms, `0x01` to `2A92B06A-461E-4EA3-B294-5D1A7E351825`.
  Both are on service `57D25503-8AE4-47B1-9631-D10DD513A095`.
- One dispense is 0.1 to 25.5 g. Other amounts are refused before anything is
  written.

## Dispensing

```
POST /api/v1/sensors/<percent-encoded id>/execute
{"commandId": "dispense", "params": {"grams": 18.5}}
```

The result's `result` is one of:

| Result | Meaning | Retry |
|---|---|---|
| `ok` | Both bytes were written | — |
| `failed` | The weight write failed, so start was never sent | Safe |
| `uncertain` | The start write was sent and then failed. The module may have dispensed | Not automatically. Check the cup first |

The sensor snapshot carries `state` (`idle`, `dispensing`, `error`,
`uncertain`), `lastGrams` and `dispenseCount`.

The Liquid Aqua skin shows connected modules in its device sheet and has a
dispense sheet with a gram amount per module.

## Settings

| Setting | Default | Meaning |
|---|---|---|
| `writeMode` | `withResponse` | `withoutResponse` if the module rejects acknowledged writes. |

## Limits

- Decaid keeps at most 4 BLE devices per plugin connected at once, so at most 4
  modules can dispense together.
- The official app connects, writes and disconnects for every dispense. This
  plugin writes on a connection that stays open. Whether the module accepts a
  second dispense on the same connection has not been tested on real hardware.
- No real hardware has been tested with this plugin yet.

## Install

Install it from the Decaid plugin page with **Install plugin → GitHub
Release**, **ZIP file** or **Folder snapshot**. A GitHub release must be
tagged `v<version>` matching `manifest.json`, with one `.zip` asset holding
`manifest.json` and `plugin.js`.

## Test

`test/redxkey_host_test.dart` runs the plugin on Decaid's own plugin engine
with a fake BLE transport. Copy it into a Decaid checkout at `test/plugins/`
and run:

```powershell
$env:Path = "C:\flutter\bin;<decaid>\build\windows\x64\runner\Debug;$env:Path"
flutter test test/plugins/redxkey_host_test.dart --dart-define=REDXKEY_DIR=<this folder>
```

On Windows, `quickjs_c_bridge.dll` from a Decaid Windows build must be on the
path.

---

# 한국어

RedxKey 원두 계량 모듈을 Decaid에서 쓰는 플러그인입니다. 모듈 하나가 원두 통
하나이고, Decaid에는 `dispense`(배출) 명령이 있는 센서로 나타납니다.

- 광고 이름에 `RedXKey`가 들어간 기기를 찾습니다(대소문자 무시).
- Decaid가 연결을 맡고, 배출할 때 열린 연결에 무게(0.1 g 단위 1바이트)와
  시작 신호 `0x01`을 차례로 씁니다. 한 번에 0.1~25.5 g입니다.
- 결과가 `uncertain`이면 시작 신호를 보낸 뒤 실패한 것이라 실제로 배출됐을 수
  있습니다. 자동으로 다시 배출하지 말고 컵을 먼저 확인하세요.
- 한 번에 연결해 둘 수 있는 모듈은 최대 4개입니다.
- 공식 앱은 배출할 때마다 연결하고 끊지만, 이 플러그인은 연결을 유지한 채
  씁니다. 실제 모듈로는 아직 확인하지 않았습니다.
- Liquid Aqua 스킨의 연결 화면에서 모듈을 연결하고, 배출 화면에서 모듈별 그램을
  정해 배출할 수 있습니다.
