# AI switch — รายงานตรวจสอบ Switch รายวัน

โฟลเดอร์นี้เก็บรายงานการตรวจสอบ switch ทุกช่องทาง (port) ว่ามีอุปกรณ์/สิ่งแปลกปลอมเข้ามาหรือไม่
แต่ละวันจะมีไฟล์ `report-YYYY-MM-DD.md`

## เครือข่ายเป้าหมาย
- Switch และอุปกรณ์ทั้งหมดอยู่ในวง **192.168.1.0/24** (ข้อมูลจากผู้ใช้ 2026-11-18)
- เป็น private IP จึงเข้าจาก cloud ไม่ได้ ทดสอบแล้ว (192.168.1.1, .254) ถูกปฏิเสธการเชื่อมต่อจาก sandbox ของ cloud

## วิธีติดตั้งบน Windows (ทำครั้งเดียว)
อุปกรณ์: Cisco switch `192.168.1.254` และเครื่อง Windows ที่อยู่ในวง 192.168.1.x

1. ติดตั้ง [Git for Windows](https://git-scm.com/download/win) แล้ว clone repo และสลับไป branch รายงาน:
   ```powershell
   git clone https://github.com/kkk21122/nextcloud-docker.git C:\aiswitch\nextcloud-docker
   cd C:\aiswitch\nextcloud-docker; git checkout ccr-5a92b4e7-htpqjz
   ```
   (ต้อง push ขึ้น GitHub ได้ เช่น login ผ่าน Git Credential Manager ตอน push ครั้งแรก)
2. เปิด switch ให้รับ SSH (ถ้ายังไม่ได้เปิด) ใน config mode:
   ```
   ip domain-name local
   crypto key generate rsa modulus 2048
   ip ssh version 2
   username aiswitch privilege 15 secret <รหัสผ่าน>
   line vty 0 15
    login local
    transport input ssh
   ```
   แนะนำให้สร้าง user แยกไว้สำหรับงานนี้
3. เปิด **PowerShell แบบ Run as Administrator** แล้วรัน:
   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass
   & "C:\aiswitch\nextcloud-docker\AI switch\scripts\Setup-SwitchCheck.ps1" -RepoPath C:\aiswitch\nextcloud-docker
   ```
   สคริปต์จะถาม user/password ของ switch (เก็บแบบเข้ารหัสไว้ในเครื่อง ไม่ขึ้น GitHub), สร้าง `baseline.csv`, และตั้ง Task Scheduler ให้รันทุกวันเวลา 07:13
4. เปิด `AI switch\baseline.csv` เติมชื่ออุปกรณ์ในคอลัมน์ `Device` ลบรายการที่ไม่ควรมีออก แล้ว commit + push

## สิ่งที่ตรวจทุกวัน
| # | รายการ | วิธี |
|---|---|---|
| 1 | MAC ไม่รู้จักบน switch | `show mac address-table` เทียบ baseline |
| 2 | อุปกรณ์ไม่รู้จักในวง IP | ping ทั้งวง 192.168.1.1-254 + ARP table |
| 3 | Port ใหม่ที่ up | `show interfaces status` |
| 4 | MAC ย้าย port (spoofing) | เทียบ port กับ baseline |
| 5 | หลาย MAC ใน access port เดียว | แอบต่อ hub/switch/AP |
| 6 | Port err-disabled | `show interfaces status` |
| 7 | Security event ใน log | `show logging`: port-security, login fail, BPDU guard, DHCP snooping, MAC flap |
| 8 | Config เปลี่ยน | hash ของ `show running-config` เทียบกับเมื่อวาน |

Routine บน Claude จะอ่าน `report-*.md` ล่าสุดทุกวัน และแจ้งเตือนเข้ามือถือเมื่อสถานะเป็น ALERT/ERROR หรือรายงานไม่มาส่ง

## ทางเลือกอื่น (ถ้าไม่ใช้สคริปต์)

routine นี้รันใน cloud container จึงมองไม่เห็นเครือข่ายภายใน (LAN) ที่ switch อยู่ ต้องมีอย่างใดอย่างหนึ่ง:
1. **ไฟล์ export จาก switch** commit เข้ามาในโฟลเดอร์ `AI switch/data/` ทุกวัน เช่น
   `show mac address-table`, `show interfaces status`, `show port-security`, `show logging`, `show arp`
2. หรือ **switch/management IP ที่เข้าถึงได้จากอินเทอร์เน็ต** (SSH/SNMP/API) + ใส่ credential ผ่าน environment settings (ไม่ใส่ในไฟล์)
3. **baseline** รายการอุปกรณ์ที่อนุญาต: `AI switch/baseline.csv` (port, MAC, ชื่ออุปกรณ์, VLAN)

เมื่อมีข้อมูลแล้ว รายงานจะเทียบ MAC/port กับ baseline และแจ้งเตือน MAC ใหม่, port ที่ขึ้นโดยไม่คาดคิด, port-security violation, VLAN เปลี่ยน, login ผิดปกติใน log
