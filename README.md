# ReMeet สำหรับ macOS

ReMeet อัดเสียงระบบและไมโครโฟน แล้วถอดเสียง แยกผู้พูด และสรุปการประชุมภาษาไทยบนเครื่องหลังหยุดอัด รองรับ macOS 15 ขึ้นไปบน Apple Silicon

## ติดตั้ง

> **Preview 0.1.0** ใช้ลายเซ็น ad hoc และยังไม่ได้ notarize การทดสอบบน macOS พบว่า Gatekeeper ปฏิเสธการเปิดแอปที่ติดตั้งผ่าน Brew ส่งผลให้ Widget ยังไม่ปรากฏในแกลเลอรี ให้รอรุ่นที่เซ็น Developer ID และผ่าน notarization ก่อนใช้งานแอปและ Widget

สำหรับรุ่นที่ผ่าน notarization แล้ว ใช้คำสั่งนี้

```sh
brew install --cask Salah1St/tap/remeet
```

Cask ติดตั้ง ReMeet.app, CLI และ FFmpeg ตัวถอดเสียง ตัวแยกผู้พูด และตัวสรุปอยู่ในแอป เปิด ReMeet จาก Applications แล้วดาวน์โหลดโมเดลใน Settings หรือใช้ `remeet setup` โมเดลจะดาวน์โหลดอัตโนมัติเมื่อเริ่มประมวลผลครั้งแรกด้วย หลังดาวน์โหลดเสร็จ ReMeet ประมวลผลแบบออฟไลน์ได้

## อัดเสียงและนำเข้า

1. เปิด ReMeet แล้วคลิกไอคอนรูปคลื่นในเมนูบาร์ ปุ่มเฟืองเปิด Settings สำหรับเลือกภาษาที่พูด
2. กดเริ่มอัด ครั้งแรกให้สิทธิ์ Microphone และ Screen & System Audio Recording ใน System Settings → Privacy & Security ตามที่ macOS แสดง
3. กดพักหรืออัดต่อได้ เมื่อกดหยุด ReMeet จะประมวลผลและแสดงลิงก์ไปยังผลลัพธ์
4. ใช้ปุ่มนำเข้าไฟล์สำหรับเสียงที่อัดไว้แล้ว เช่น M4A หรือ WAV

เพิ่ม Widget จาก Notification Center → Edit Widgets → ReMeet โหมด **After Stop** เป็นค่าเริ่มต้น ป้าย **Live · เร็ว ๆ นี้** แสดงตำแหน่งของโหมดคำบรรยายสำหรับรุ่นถัดไป

```sh
remeet record --language th     # Ctrl+C เพื่อหยุดและประมวลผล
remeet process ./meeting.m4a --language auto
remeet resume "/path/to/session-folder"
```

`record` ใช้ ReMeet.app เป็นตัวอัดเดียวกับเมนูบาร์และ Widget ส่วน `process` รับไฟล์เสียงในเครื่อง ใช้ `remeet --help` ดูคำสั่งทั้งหมด

## ผลลัพธ์

เปิดโฟลเดอร์ผลลัพธ์จากแอป หรือไปที่ `~/Library/Application Support/ReMeet/Recordings` แต่ละการประชุมมีโฟลเดอร์แยก

- `transcript-<DDMMYYYY>.txt` มีเวลาอ้างอิงจากต้นไฟล์เสียง ชื่อสมมติ และคำพูด ชื่อสมมติใช้ซ้ำกับกลุ่มเสียงเดิมในไฟล์ หากแยกเสียงได้ไม่ชัดจะแสดงว่า “ผู้พูดไม่ชัด”
- `ai-summary.md` เป็นสรุปภาษาไทย พร้อมมติ งานที่ต้องทำ และเวลาอ้างอิงจากบทถอดเสียง หากสรุปขัดข้องให้ใช้ `remeet resume` กับโฟลเดอร์เดิม

## Build และเผยแพร่

```sh
./scripts/build.sh
./scripts/render-cask.sh Salah1St/remeet 0.1.0 dist/ReMeet-0.1.0-arm64.zip
```

Build ปกติใช้ลายเซ็น ad hoc สำหรับทดสอบ ส่วนการเผยแพร่ที่ผ่าน Gatekeeper ใช้ Developer ID และ notarization ตามตัวเลือกใน `scripts/build.sh` และ workflow `release.yml` สถานะ Widget แบบแชร์กับแอปใช้ App Group ที่ผูกกับ Team ID ของลายเซ็น Developer ID ใน build ad hoc ปุ่ม Widget เปิดแอปให้ยืนยันการควบคุม และสถานะสดดูได้จากเมนูบาร์

ตัวประมวลผลในแอปใช้ [whisper.cpp](https://github.com/ggml-org/whisper.cpp), [llama.cpp](https://github.com/ggml-org/llama.cpp) และ [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)
