# AI switch — รายงานตรวจสอบ Switch รายวัน

โฟลเดอร์นี้เก็บรายงานการตรวจสอบ switch ทุกช่องทาง (port) ว่ามีอุปกรณ์/สิ่งแปลกปลอมเข้ามาหรือไม่
แต่ละวันจะมีไฟล์ `report-YYYY-MM-DD.md`

## สิ่งที่ต้องตั้งค่าก่อน จึงจะตรวจได้จริง
routine นี้รันใน cloud container จึงมองไม่เห็นเครือข่ายภายใน (LAN) ที่ switch อยู่ ต้องมีอย่างใดอย่างหนึ่ง:
1. **ไฟล์ export จาก switch** commit เข้ามาในโฟลเดอร์ `AI switch/data/` ทุกวัน เช่น
   `show mac address-table`, `show interfaces status`, `show port-security`, `show logging`, `show arp`
2. หรือ **switch/management IP ที่เข้าถึงได้จากอินเทอร์เน็ต** (SSH/SNMP/API) + ใส่ credential ผ่าน environment settings (ไม่ใส่ในไฟล์)
3. **baseline** รายการอุปกรณ์ที่อนุญาต: `AI switch/baseline.csv` (port, MAC, ชื่ออุปกรณ์, VLAN)

เมื่อมีข้อมูลแล้ว รายงานจะเทียบ MAC/port กับ baseline และแจ้งเตือน MAC ใหม่, port ที่ขึ้นโดยไม่คาดคิด, port-security violation, VLAN เปลี่ยน, login ผิดปกติใน log
