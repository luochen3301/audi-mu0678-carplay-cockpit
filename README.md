# MHI2 AltScreen SD-card kit (Audi MU0678)

**中文** | [English](#english)

用 **M.I.B. + SD 卡**（不需要 OBD、网线或 SSH）在 Audi MHI2 车机上安装
[joeyQuery/MHI2-altScreen](https://github.com/joeyQuery/MHI2-altScreen) 的
**"CarPlay 地图显示在虚拟座舱（Virtual Cockpit）"**，并附带"双导航"（开导航时仪表不再变成指南针页）。

> ⚠️ **只适用于 `MHI2_ER_AUG22_P3241` / MU0678**。所有安装脚本在写入任何东西之前都会核对固件版本和关键文件的指纹，
> 不一致就拒绝安装、不改车机。修改车机有风险，后果自负。本项目与 Audi、VW、Harman、Apple 无关。

## 现状

| 功能 | 状态 |
|---|---|
| CarPlay 地图显示在仪表（hook r60） | ✅ 实车可用 |
| v1.1：修复"开机一段时间后才第一次插手机，仪表黑屏" | ✅ 实车验证 |
| 双导航（M.I.B. NavActiveIgnore，开导航时仪表保持 CarPlay 地图） | ✅ 实车验证（Siri、CarPlay 通话正常） |
| 方向盘滚轮缩放仪表地图（DSITracer） | 🚧 研究中，只有只读收集脚本 |
| 导航时帧率 16–21 fps（不导航 29–30） | 🔎 已定位原因，见 [docs/findings.md](docs/findings.md) |

目前只在**一台车**上实测过（A4 B9，与原作者的测试车固件完全相同）。

## 会改车机的什么

| 包 | 车机上的改动 | 卸载 |
|---|---|---|
| `altscreen`（地图） | 新增 `/mnt/app` 下的 hook、`vc_render`、8 个小配置文件、原厂配置备份和安装记录；`smartphone_integrator.json` 的 CarPlay 环境变量里**加 8 行** | 先放回原厂配置，再删文件 |
| `navignore`（双导航） | 只新增 1 个文件 `/mnt/app/eso/hmi/lsd/jars/NavActiveIgnore.jar`；`lsd.sh` **不改**（原厂脚本本来就加载 `jars/` 里的 jar） | 删除该文件；也可以直接用 M.I.B. 菜单的 "Remove dual navigation" |
| `*-collect` | 不改车机，只把文件拷到 SD 卡 | — |

安装脚本的共同规则：**先全部检查再写**；每个文件先写成临时文件、校验后再改名到位；最关键的开关最后一步才改；
每次运行的日志写到 SD 卡上。详见 [docs/safety.md](docs/safety.md)。

## 怎么用

完整步骤：[docs/安装指南.md](docs/安装指南.md)。概要：

1. 在 SD 卡上装好 **M.I.B. V3.6.0** 并激活绿色工程菜单。
2. 运行**只读收集脚本**，把车上的原厂文件拿回电脑（这些文件只留在你自己电脑上的 `car-data/`）。
3. 在电脑上下载原作者的文件、用你自己的原厂文件生成安装包：

   ```bash
   bash tools/fetch_upstream.sh
   python tools/make_hook_v11.py inputs/libaltscreen111.so inputs/libaltscreen111-v11.so
   python inputs/make_patched_carplay_json.py car-data/altscreen_collect/001/files/mnt__system__etc__eso__production__smartphone_integrator.json inputs/smartphone_integrator.json.patched
   python tools/build_install_package.py --hook inputs/libaltscreen111-v11.so --upgrade-from inputs/libaltscreen111.so \
       --vcrender inputs/vc_render --stock car-data/altscreen_collect/001/files/mnt__system__etc__eso__production__smartphone_integrator.json \
       --patched inputs/smartphone_integrator.json.patched --libairplay car-data/altscreen_collect/001/files/mnt__app__eso__lib__libairplay.so \
       --src-sd src-sd --out build/sd
   ```

   每一步都核对固定的 SHA-256，对不上就停。
4. 把 `build/.../mod/` 拷进 SD 卡的 `mod/`，在车上：绿色菜单 → **m.i.b → Advanced Settings → Run individual script**。

## 测试

```bash
bash tests/run_all.sh
```

在电脑上模拟车机文件系统运行真实的安装脚本（dash 和 bash 都跑）：正常安装、重复安装、升级、卸载、
各种拒绝安装的情况、复制失败/校验失败/改名失败，并检查车机文件是否逐字节恢复原样。
需要原厂文件的测试在没有 `car-data/` 时会显示 **SKIP**，不算失败。

## 这个仓库**不包含**的东西

- **车机原厂文件**（`lsd.jxe`、`lsd.sh`、`libairplay.so`、原厂配置）：Audi/Harman 的版权，请用收集脚本从自己的车上取。
- **你的车机数据**：M.I.B. 备份（EEPROM、FEC、shadow）、日志（含设备标识）。`.gitignore` 已排除 `car-data/`。
- **原作者的二进制**（hook r60、`vc_render`）：用 `tools/fetch_upstream.sh` 从原作者仓库按固定版本下载并校验。
- **M.I.B. 的 `navignore_audi.jar`**：从你自己的 M.I.B. 3.6.0 卡（`mod/java/`）拷到 `inputs/navignore/`。

## 发现与说明

[docs/findings.md](docs/findings.md)：黑屏问题的原因和修复、帧率问题的原因、双导航 jar 与本固件的逐成员核对、
J9 ROM 镜像（`lsd.jxe`）格式笔记、DSITracer（滚轮缩放）研究笔记。

## 致谢与许可

- 地图功能、hook、`vc_render`、配置值全部来自 [joeyQuery/MHI2-altScreen](https://github.com/joeyQuery/MHI2-altScreen)；本仓库只是 SD 卡安装方式、测试和少量修复。
- 双导航 jar 来自 [M.I.B. – More Incredible Bash](https://github.com/Mr-MIBonk/M.I.B._More-Incredible-Bash)（不随本仓库分发）。
- 更多见 [CREDITS.md](CREDITS.md)。许可：**GPL-3.0-or-later**（与原项目一致），见 [LICENSE](LICENSE)。

---

## English

SD-card installers (run from the **M.I.B.** green engineering menu — no OBD, cable or SSH) for
[joeyQuery/MHI2-altScreen](https://github.com/joeyQuery/MHI2-altScreen) — the CarPlay map on the Audi Virtual Cockpit —
plus "dual navigation" (M.I.B. NavActiveIgnore) so the cockpit keeps the CarPlay map while a CarPlay route is active.

- **Only for `MHI2_ER_AUG22_P3241` / MU0678.** Every installer checks the train and pinned SHA-1s of the files it depends on
  before writing anything, and refuses otherwise. Tested on one car (A4 B9) with firmware identical to upstream's test car.
- **v1.1** patches 3 bytes of the r25 autostart script embedded in the r60 hook so the first phone connection made
  after the car's navigation is ready also gets a UI re-acquire (otherwise the cockpit stays black that session).
- **Dual navigation** adds one file (`lsd/jars/NavActiveIgnore.jar`); the stock `lsd.sh` already loads every jar there.
  The jar's two classes were checked member by member against this firmware's `lsd.jxe` with the J9 ROM image tools in `tools/jxe/`.
- Not included: OEM files, unit backups/logs, upstream binaries (fetched and hash-checked by `tools/fetch_upstream.sh`),
  the M.I.B. jar. Tests skip what they cannot run without your own collected files.
- Details: [docs/findings.md](docs/findings.md), [docs/safety.md](docs/safety.md). License: GPL-3.0-or-later.
