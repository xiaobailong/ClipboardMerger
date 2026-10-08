# 本项目专属签名材料（只放 Profile）

**只有这个 README 会进 git**：`harmony/.gitignore` 里是 `/signature/*`（全部忽略）+ `!/signature/README.md`（只放行本文件）。

| 放这里 | 说明 |
| --- | --- |
| `*.p7b` | **Profile**：AGC「Profile 管理」下载的调试/发布 Profile。它绑死包名 `com.example.clipboardmerger` + 你的证书 + 调试设备 UDID 列表，所以**不能跨项目复用** |
| `entry-default-signed.hap` | 本地签名产物（临时文件，可随时删） |

| **不放**这里 | 去哪 |
| --- | --- |
| `.p12` 私钥 / `.cer` 证书 / 密码 | `D:\Tools\DevTools\hmos\signature\`（公共证书目录，可给多个鸿蒙 App 复用；规则见那里的 `README.md`） |

**为什么分开**：证书 = 开发者身份（可复用多 App）；Profile = 绑包名 + 设备（项目专属）。

DevEco「自动签名」会把材料直接写进本目录（`*.p12/*.cer/*.p7b`），一样能用；
用它生成的那套时，建议把 `.p12/.cer` 顺手拷一份到公共证书目录，下一个项目就能直接复用（Profile 仍需按新包名重新申请）。
