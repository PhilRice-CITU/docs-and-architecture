# Rice Grain Evaluation System — Technical Master Plan
**Version:** 1.0 | **Status:** Draft for Team Review | **Date:** 2026

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [System Architecture Diagram](#2-system-architecture-diagram)
3. [Phase 1 — Dataset Rebuild & Annotation Pipeline](#3-phase-1--dataset-rebuild--annotation-pipeline)
4. [Phase 2 — Model Architecture & Retraining](#4-phase-2--model-architecture--retraining)
5. [Phase 3 — IoT Device Architecture](#5-phase-3--iot-device-architecture)
6. [Phase 4 — Cloud Backend & API](#6-phase-4--cloud-backend--api)
7. [Phase 5 — Dashboard Frontend](#7-phase-5--dashboard-frontend)
8. [End-to-End Data Pipeline](#8-end-to-end-data-pipeline)
9. [Grading Output Specification](#9-grading-output-specification)
10. [Phased Rollout Timeline](#10-phased-rollout-timeline)
11. [Open Decisions & Risk Register](#11-open-decisions--risk-register)

---

## 1. Project Overview

### What We Are Building
An automated rice grain quality evaluation system consisting of:
- A **physical edge device** (Linux/Raspberry Pi with camera + touchscreen) that captures images of a rice sample
- A **cloud AI pipeline** that receives those images, runs a trained computer vision model, and produces a structured quality grade
- A **web dashboard** where operators log in, select their device by serial code, and view scan results in real time

### Core Quality Metrics (Model Outputs)
| Metric | Description | Output Type |
|---|---|---|
| **Chalkiness %** | % of grain area that is opaque/white (chalky) vs. translucent | Float, 0–100 |
| **Broken Grain %** | % of grains that are fractured below ½ original length | Float, 0–100 |
| **Foreign Matter %** | % of non-grain material in sample (husks, stones, debris) | Float, 0–100 |
| **Grain Shape Class** | Morphological classification: Extra Long / Long / Medium / Short / Round | String enum |
| **Overall Grade** | Composite score derived from above metrics per NSQS / ISO 7301 | Integer, 0–100 |

### Why We Are Retraining
The existing model was trained on a **small, low-diversity image dataset** — limited lighting conditions, limited camera angles, and insufficient annotation coverage of edge-case defects (e.g. partially chalky grains, partial breakage). The retraining goal is to:
- Replace the old dataset with a larger, properly annotated dataset built in Roboflow
- Improve per-grain instance segmentation so metrics are measured at the grain level, not inferred from the whole image
- Standardize training data quality with a controlled, reproducible annotation workflow

---

## 2. System Architecture Diagram

```
┌────────────────────────────────────────────────────────────────────────┐
│                         EDGE DEVICE (Pi)                               │
│                                                                        │
│  ┌──────────┐    ┌─────────────┐    ┌──────────────┐                  │
│  │  Camera  │───▶│  Capture &  │───▶│  HTTP POST   │                  │
│  │(12MP, 2x)│    │  Pre-process│    │  (2 images + │                  │
│  └──────────┘    └─────────────┘    │  serial code)│                  │
│                                     └──────┬───────┘                  │
│  ┌──────────┐    ┌─────────────┐           │                          │
│  │Touchscreen│   │ Wi-Fi Mgr / │           │                          │
│  │   UI     │   │  Scanner UI │           │                          │
│  └──────────┘    └─────────────┘           │                          │
└────────────────────────────────────────────│───────────────────────── ┘
                                             │ HTTPS multipart/form-data
                                             ▼
┌────────────────────────────────────────────────────────────────────────┐
│                        CLOUD BACKEND (FastAPI)                         │
│                                                                        │
│  ┌─────────────┐    ┌──────────────┐    ┌───────────────────────────┐ │
│  │ POST /scans │───▶│ Upload imgs  │───▶│   AI Inference Service    │ │
│  │             │    │  to S3/R2    │    │                           │ │
│  └─────────────┘    └──────────────┘    │  ┌───────────────────┐   │ │
│                                         │  │  YOLOv8-seg model │   │ │
│  ┌──────────────┐                       │  │  (self-hosted or  │   │ │
│  │ GET /scans   │◀──────────────────────│  │   via Roboflow    │   │ │
│  │ (by serial)  │    scores + summary   │  │   Inference API)  │   │ │
│  └──────────────┘                       │  └───────────────────┘   │ │
│                                         └───────────────────────────┘ │
│  ┌──────────────────────────────────────────────────────────────────┐ │
│  │  PostgreSQL  │  scan records, device registry, user accounts     │ │
│  └──────────────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────────────┘
                                             │
                                             ▼
┌────────────────────────────────────────────────────────────────────────┐
│                       FRONTEND (Next.js Dashboard)                     │
│                                                                        │
│   Login → Enter Serial Code → View Real-Time Results & History        │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Phase 1 — Dataset Rebuild & Annotation Pipeline

### 3.1 The Core Problem With the Current Dataset

The existing model's weakness is **data quality, not architecture**. Specifically:
- Images were captured under inconsistent lighting (shadows, glare)
- Grain samples were not standardized in size or spread density
- Annotation was inconsistent — chalky regions were approximated at the bounding-box level, not pixel-level masks
- The dataset lacked diversity in grain varieties and defect severity levels

### 3.2 New Image Capture Standard (for Dataset Collection)

Before annotating, we must define a **controlled capture protocol** that the IoT device will also replicate in production. This eliminates domain shift between training data and live inference.

| Parameter | Specification |
|---|---|
| **Background** | Matte black or matte white acrylic tray (uniform, non-reflective) |
| **Lighting** | Diffused LED ring light, consistent color temperature (5000–6500K) |
| **Camera height** | Fixed at 25–30cm above the sample tray |
| **Sample density** | Single grain layer only — grains must not overlap |
| **Sample size** | 10–20g per scan (≈ 200–500 grains depending on variety) |
| **Image resolution** | Minimum 4000×3000px (12MP+) |
| **Shots per sample** | 2 images: one from directly overhead, one at slight angle (15°) |
| **File format** | JPEG, quality 95+, no lossy compression artifacts |

> **Note for team:** The IoT device housing should enforce the camera height and lighting automatically — this is a hardware design requirement, not just a software one.

### 3.3 Roboflow Annotation Workflow

Roboflow is our primary tool for dataset curation, labeling, augmentation, and version management.

**Workspace Setup:**
```
Roboflow Workspace: rice-eval-system
└── Project: rice-grain-detection
    ├── Type: Instance Segmentation (not Object Detection)
    │         We need pixel-level masks for chalkiness measurement
    └── Classes (see 3.4 below)
```

**Why Instance Segmentation, not Detection?**
Bounding boxes are insufficient for this domain. To measure chalkiness %, we need to know the exact pixel area of each grain and the exact pixel area of the chalky region within it. This requires polygon/mask-level annotation.

### 3.4 Annotation Classes

| Class Name | Label Color | Description |
|---|---|---|
| `grain_whole` | Green | Full, unbroken grain — translucent or chalky |
| `grain_broken` | Red | Fractured grain, less than half original length |
| `grain_tip` | Orange | Broken grain fragment, tip only |
| `chalky_region` | Yellow | Opaque white region inside a `grain_whole` |
| `foreign_matter` | Purple | Non-grain objects: husk, stone, dark spot, dust |

**Annotation Rules (to be documented in Roboflow project description):**
1. Every visible grain receives either a `grain_whole` or `grain_broken` label
2. `chalky_region` is a **nested annotation inside** a `grain_whole` — it is the opaque portion only
3. When in doubt about breakage threshold, annotate as `grain_broken` if < 2/3 original grain length
4. `foreign_matter` is annotated even if partially occluded by grains
5. Grains at the very edge of the frame (>50% out of frame) are skipped

### 3.5 Dataset Volume Targets

| Split | Image Count | Grain Instances (est.) |
|---|---|---|
| Training | 800 | ~200,000 |
| Validation | 150 | ~37,000 |
| Test | 100 | ~25,000 |
| **Total** | **1,050** | **~262,000** |

> **Current status:** We are targeting a 5× increase over the previous dataset size. The team should prioritize variety diversity — at least 5–6 rice varieties (jasmine, koshihikari, arborio, basmati, etc.) and multiple chalkiness severity levels.

### 3.6 Roboflow Augmentation Pipeline

Augmentations are applied in Roboflow **at export time** to generate a 3×-expanded training set. These must mirror real-world variation while not creating unrealistic artifacts.

**Enabled Augmentations:**
| Augmentation | Settings | Reason |
|---|---|---|
| Horizontal flip | 50% chance | Grain orientation is symmetric |
| Rotation | ±15° | Tray may not be perfectly aligned |
| Brightness | ±20% | Lighting variation between devices |
| Saturation | ±15% | Color temperature variation |
| Blur (Gaussian) | 0–1.5px | Slight focus inconsistency |
| Crop | 0–10% | Camera framing variance |
| Grayscale | 10% chance | Robustness — some edge devices may capture in lower color fidelity |

**Disabled Augmentations (do NOT enable):**
- Heavy shear / perspective distortion — grains have a fixed aspect ratio; heavy distortion creates unrealistic shapes
- Noise injection above 2% — creates false chalky-looking pixels
- Cutout / mosaic — interferes with per-grain instance boundaries

### 3.7 Dataset Export Format

Export from Roboflow in **YOLOv8 format** (segmentation variant). The export package will contain:
```
dataset/
├── train/
│   ├── images/     *.jpg
│   └── labels/     *.txt  (YOLO polygon format)
├── valid/
│   ├── images/
│   └── labels/
├── test/
│   ├── images/
│   └── labels/
└── data.yaml       # class names, paths
```

---

## 4. Phase 2 — Model Architecture & Retraining

### 4.1 Recommended Model: YOLOv8-seg (Instance Segmentation)

**Why YOLOv8-seg over alternatives:**

| Option | Pros | Cons | Decision |
|---|---|---|---|
| YOLOv8-seg | Fast, well-documented, excellent for dense object counting, runs on Pi | Needs fine-tuning for chalky region nesting | **✅ Selected** |
| Mask R-CNN | High mask quality | Slow inference, heavy, not Pi-friendly | ❌ |
| GPT-4o Vision | Zero training needed, good at describing | Can't count 300 individual grains reliably, API cost per scan, no fine-tuning control | ❌ for primary |
| YOLOv8-classify | Fast | Image-level only — can't measure per-grain | ❌ |

**Model variant:** `yolov8m-seg` (medium) — balance of accuracy and inference speed. Upgrade to `yolov8l-seg` if mAP is insufficient after training.

### 4.2 Two-Stage Inference Architecture

Because `chalky_region` is a sub-annotation **inside** a grain, we use a two-stage approach:

```
Image Input
    │
    ▼
┌─────────────────────────────────┐
│  Stage 1: Grain Detector        │
│  YOLOv8m-seg                    │
│  Classes: grain_whole,          │
│           grain_broken,         │
│           grain_tip,            │
│           foreign_matter        │
│                                 │
│  Output: instance masks +       │
│          bounding boxes         │
└────────────────┬────────────────┘
                 │
                 ▼
┌─────────────────────────────────┐
│  Stage 2: Chalky Region         │
│  Detector (per-grain crop)      │
│  YOLOv8s-seg (lightweight)      │
│  Classes: chalky_region,        │
│           normal_region         │
│                                 │
│  Input: cropped grain ROI       │
│  Output: chalky pixel mask      │
└────────────────┬────────────────┘
                 │
                 ▼
┌─────────────────────────────────┐
│  Metric Computation Layer       │
│  (pure Python / NumPy)          │
│                                 │
│  chalkiness_pct = chalky_px /   │
│                   grain_px      │
│  broken_pct = broken_count /    │
│               total_count       │
│  foreign_pct = foreign_px /     │
│                frame_px         │
│  shape_class = aspect_ratio     │
│                classifier       │
└─────────────────────────────────┘
```

> **Alternative to Stage 2 if complexity is a concern:** Train a single model on both grain masks and chalky region masks simultaneously using Roboflow's nested annotation support. Test both approaches and pick whichever achieves better chalkiness mAP on the validation set.

### 4.3 Training Configuration

```yaml
# train_config.yaml
model: yolov8m-seg.pt        # pretrained COCO weights as starting point
data:  dataset/data.yaml

epochs:       150
imgsz:        1280            # high resolution critical for small grains
batch:        8               # adjust for your GPU VRAM
optimizer:    AdamW
lr0:          0.001
lrf:          0.01            # final LR = lr0 * lrf
momentum:     0.937
weight_decay: 0.0005
patience:     30              # early stopping

# Augmentation overrides (Albumentations inside YOLO)
hsv_h: 0.015
hsv_s: 0.4
hsv_v: 0.3
flipud: 0.0       # grains don't need vertical flip
fliplr: 0.5
mosaic: 0.5       # reduce from 1.0 — grain density matters
```

### 4.4 Evaluation Metrics for Model Sign-Off

The model is not considered ready for production until it meets all of the following on the **held-out test set**:

| Metric | Minimum Threshold |
|---|---|
| `mAP50` (all classes) | ≥ 0.85 |
| `mAP50-95` (all classes) | ≥ 0.65 |
| `grain_whole` mask mAP50 | ≥ 0.90 |
| `grain_broken` mask mAP50 | ≥ 0.82 |
| `chalky_region` mask mAP50 | ≥ 0.78 |
| Chalkiness % MAE vs manual count | ≤ 3.0 percentage points |
| Broken grain % MAE vs manual count | ≤ 2.5 percentage points |
| Inference time (Pi 4B, 1 image) | ≤ 8 seconds |

### 4.5 Model Versioning & Registry

All trained model weights are stored and versioned:
- **During training:** Use Roboflow Training or Weights & Biases (wandb) for run tracking
- **Model artifacts:** Store `.pt` weight files in S3/R2 with version tags (e.g. `rice-eval-v2.1-best.pt`)
- **Deployment:** The backend API loads the model from a configured S3 path at startup — swapping versions requires only an environment variable change and a restart, no code change

```
S3 Bucket: rice-eval-models/
├── v1.0/  weights-original.pt    ← existing model (archived)
├── v2.0/  best.pt                ← retraining result
└── latest → symlink / env var
```

---

## 5. Phase 3 — IoT Device Architecture

### 5.1 Hardware Bill of Materials

| Component | Specification | Role |
|---|---|---|
| **SBC** | Raspberry Pi 4B (4GB RAM) or Pi 5 | Main compute unit |
| **Camera** | Raspberry Pi HQ Camera + 16mm lens | Captures 2x 12MP images |
| **Touchscreen** | Official 7" DSI touchscreen (800×480) | Operator UI |
| **Lighting** | Programmable LED ring (5000K, PWM-controlled via GPIO) | Consistent illumination |
| **Storage** | 32GB+ Class A2 microSD | OS + application |
| **Enclosure** | Custom 3D-printed / CNC housing | Holds camera at fixed height, holds sample tray |
| **Connectivity** | Built-in Wi-Fi (802.11ac) + optional USB Ethernet | Network |
| **Power** | USB-C PD 3A supply | Stable power — avoid brownouts |

### 5.2 Software Stack (On-Device)

| Layer | Technology | Purpose |
|---|---|---|
| **OS** | Raspberry Pi OS Lite 64-bit | Minimal, stable base |
| **Display Server** | X11 + Openbox | Kiosk window manager |
| **App Framework** | Python 3.11 + Tkinter or PyQt6 | Touch UI |
| **Camera Library** | Picamera2 | Camera control, image capture |
| **Network Management** | NetworkManager + nmcli | Wi-Fi scanning and connection |
| **HTTP Client** | requests (Python) | POST images to cloud API |
| **Process Manager** | systemd | Auto-launch on boot, restart on crash |

### 5.3 On-Device Application Flow

```
Boot
 │
 ├─▶ systemd launches app in full-screen kiosk mode
 │
 ├─▶ Check internet connectivity (ping 8.8.8.8)
 │       │
 │       ├── Offline ──▶ Show Wi-Fi Manager Screen
 │       │                   │ Scan networks (nmcli)
 │       │                   │ User selects SSID, enters password
 │       │                   │ nmcli connect
 │       │                   └── On success ──▶ Main Scanner Screen
 │       │
 │       └── Online ──▶ Main Scanner Screen
 │
 └─▶ Main Scanner Screen
         │
         │ [Operator places rice sample in tray]
         │
         ├─▶ User taps SCAN button
         │
         ├─▶ LED ring activates
         ├─▶ Camera captures Image 1 (overhead, 12MP)
         ├─▶ 500ms delay
         ├─▶ Camera captures Image 2 (same position)
         ├─▶ LED ring deactivates
         │
         ├─▶ UI shows "Uploading…" status
         │
         ├─▶ HTTP POST to /api/scans
         │   ├── image_1: [jpeg bytes]
         │   ├── image_2: [jpeg bytes]
         │   └── device_serial: [read from /proc/cpuinfo]
         │
         ├── Success ──▶ Show "Scan submitted! ID: XXXX"
         └── Failure ──▶ Show error + retry button
```

### 5.4 Device Provisioning (One-Command Setup)

The device is provisioned via a single bash script hosted on GitHub. On a fresh Pi OS install:

```bash
curl -sSL https://raw.githubusercontent.com/org/repo/main/edge/setup.sh | bash
```

The script handles:
1. System package update
2. Install: Python 3.11, Picamera2, NetworkManager, X11, Openbox, unclutter
3. Enable camera overlay in `/boot/config.txt`
4. Clone application repo to `/opt/iot-scanner/`
5. Create Python virtual environment + install requirements
6. Set API endpoint URL (prompted during install)
7. Configure Openbox autostart for kiosk mode
8. Install and enable systemd service (`iot-scanner.service`)
9. Optionally reboot

### 5.5 Device Identity

Each device is uniquely identified by its **CPU serial number**, read from `/proc/cpuinfo` at runtime. This serial is sent with every scan POST request and is used to:
- Auto-register the device in the database on first scan
- Associate all scan history with that specific unit
- Allow the web dashboard user to select their device by serial

No manual pairing or QR code required — device registers itself on first successful scan.

---

## 6. Phase 4 — Cloud Backend & API

### 6.1 Tech Stack

| Component | Technology | Hosting |
|---|---|---|
| **API Framework** | FastAPI (Python) | Railway or Render |
| **AI Inference** | YOLOv8 (Ultralytics) | Same server or dedicated GPU instance |
| **Database** | PostgreSQL 16 | Railway managed DB |
| **File Storage** | AWS S3 or Cloudflare R2 | Image storage |
| **Model Registry** | S3 bucket (versioned) | Weight file storage |
| **Containerization** | Docker | Consistent deploy |

### 6.2 Key API Endpoints

| Method | Endpoint | Description |
|---|---|---|
| `POST` | `/api/scans` | Receive images + serial, upload to S3, trigger AI inference |
| `GET` | `/api/scans?device_serial=X` | Fetch scan history for a device |
| `GET` | `/api/scans/{scan_id}` | Fetch single scan result |
| `POST` | `/api/auth/register` | Create user account |
| `POST` | `/api/auth/login` | Return JWT token |
| `GET` | `/api/devices` | List devices owned by authenticated user |
| `PATCH` | `/api/devices/{id}` | Set human-readable label for a device |

### 6.3 Inference Execution Strategy

The POST request from the Pi **must return immediately** (the device should not wait 10–30 seconds for model inference). Strategy:

```
POST /api/scans
  │
  ├─▶ Save images to S3             (synchronous, ~1–2s)
  ├─▶ Create scan record in DB      (status = "pending")
  ├─▶ Return 202 Accepted + scan_id (immediate response to device)
  │
  └─▶ [Background Task]
        ├─▶ Load images from S3
        ├─▶ Run Stage 1: Grain detection (YOLOv8-seg)
        ├─▶ Run Stage 2: Chalkiness detection (per-grain crop)
        ├─▶ Compute all metrics (NumPy)
        ├─▶ Update scan record in DB (status = "complete", scores = {...})
        └─▶ Dashboard auto-refreshes via polling or WebSocket
```

### 6.4 Database Schema (Core Tables)

```sql
users        (id, email, password_hash, created_at)
devices      (id, serial_code, label, owner_id→users, registered_at)
scans        (id, device_id→devices, image_1_url, image_2_url,
              ai_scores JSONB, ai_summary TEXT, model_version VARCHAR,
              status VARCHAR, created_at)
```

`ai_scores` JSONB structure:
```json
{
  "overall_grade":    87,
  "chalkiness_pct":   12.4,
  "broken_pct":       3.1,
  "foreign_matter_pct": 0.5,
  "grain_shape":      "Long",
  "grain_count":      342,
  "model_version":    "v2.0"
}
```

---

## 7. Phase 5 — Dashboard Frontend

### 7.1 Tech Stack

| Component | Technology |
|---|---|
| Framework | Next.js 14 (App Router) |
| Language | TypeScript |
| Styling | Tailwind CSS |
| Auth | NextAuth.js (Credentials provider + JWT) |
| Data Fetching | SWR (polling for pending scans) |
| Deployment | Vercel |

### 7.2 Key Pages & Features

| Page | Features |
|---|---|
| `/login` | Email + password authentication |
| `/dashboard` | Device selector by serial code, live scan feed |
| `/scan/[id]` | Full result view: both images, annotated overlay, metric breakdown |
| `/devices` | List of registered devices, ability to rename them |

### 7.3 Real-Time Result Display

After a scan is submitted, the dashboard polls `GET /api/scans/{scan_id}` every 3 seconds until `status === "complete"`. The UI shows a live progress indicator during inference. This avoids the complexity of WebSockets for v1.

---

## 8. End-to-End Data Pipeline

This is the complete journey from physical rice sample to dashboard result:

```
1. PHYSICAL SAMPLE
   Operator places rice sample in the device tray

2. IMAGE CAPTURE  [On-Device]
   └─▶ Picamera2 captures 2x 12MP JPEG images
   └─▶ Images stored temporarily in /tmp/scan_captures/

3. TRANSMISSION  [On-Device → Cloud]
   └─▶ HTTP POST multipart/form-data
       ├── image_1.jpg
       ├── image_2.jpg
       └── device_serial: "10000000abcdef12"

4. INGESTION  [FastAPI Backend]
   └─▶ Validate request
   └─▶ Auto-register device if new
   └─▶ Upload images to S3 → get permanent URLs
   └─▶ Create scan record (status: pending)
   └─▶ Return scan_id to device (202 Accepted)

5. AI INFERENCE  [Background Task, Cloud]
   └─▶ Stage 1: YOLOv8m-seg detects all grain instances + foreign matter
   └─▶ Stage 2: YOLOv8s-seg detects chalky regions per grain crop
   └─▶ Metric computation:
       ├── Count total grains, broken grains, foreign matter instances
       ├── Calculate pixel ratios for % metrics
       └── Classify grain shape from median aspect ratio

6. PERSISTENCE  [PostgreSQL]
   └─▶ Update scan record with ai_scores JSONB + status: complete

7. DISPLAY  [Next.js Dashboard]
   └─▶ User selects device serial
   └─▶ SWR fetches scan list (polling until complete)
   └─▶ Renders ScanCard with grade, metrics, annotated image preview
```

---

## 9. Grading Output Specification

The system outputs a final **Overall Grade (0–100)** based on a weighted composite of the detected metrics. Weights should be validated against your target rice quality standard (NSQS, ISO 7301, or internal spec).

**Proposed Weighting:**

| Metric | Weight | Direction |
|---|---|---|
| Chalkiness % | 35% | Lower = better |
| Broken grain % | 30% | Lower = better |
| Foreign matter % | 20% | Lower = better |
| Grain shape uniformity | 15% | Higher uniformity = better |

**Grade Bands:**

| Score | Label | Color |
|---|---|---|
| 85–100 | Premium | 🟢 Green |
| 70–84 | Grade A | 🟡 Yellow |
| 50–69 | Grade B | 🟠 Orange |
| 0–49 | Reject | 🔴 Red |

> **Action item for team:** Confirm grading weights with your rice industry standard or client specification before training the scoring layer.

---

## 10. Phased Rollout Timeline

### Phase 1 — Dataset & Annotation  *(Weeks 1–4)*
- [ ] Define and document capture protocol (lighting, height, sample size)
- [ ] Set up Roboflow workspace and project (Instance Segmentation type)
- [ ] Collect 1,050+ raw images under controlled conditions
- [ ] Annotate all images in Roboflow following the annotation rules in §3.4
- [ ] QA review: second annotator validates 20% random sample
- [ ] Configure augmentation pipeline in Roboflow
- [ ] Export dataset in YOLOv8 format, version-tag as `v2.0-raw`

### Phase 2 — Model Retraining  *(Weeks 3–6, overlaps)*
- [ ] Set up training environment (GPU machine or cloud: RunPod, Colab Pro, Lambda)
- [ ] Baseline: re-evaluate current model on new test images to quantify improvement gap
- [ ] Train Stage 1 model (grain detection) on new dataset
- [ ] Evaluate against sign-off metrics (§4.4)
- [ ] Train Stage 2 model (chalkiness detection) on grain crops
- [ ] Integrate two-stage pipeline + metric computation layer
- [ ] Run full pipeline evaluation: compare computed % vs manual count on 50 samples
- [ ] Package model weights, upload to S3 model registry

### Phase 3 — Backend API  *(Weeks 5–8)*
- [ ] Scaffold FastAPI project structure
- [ ] Implement `POST /api/scans` with S3 upload + background inference task
- [ ] Integrate YOLOv8 inference pipeline into backend
- [ ] Set up PostgreSQL schema + Alembic migrations
- [ ] Implement auth endpoints (register/login)
- [ ] Containerize with Docker
- [ ] Deploy to Railway, test with Postman/curl

### Phase 4 — IoT Device  *(Weeks 7–10)*
- [ ] Design and build device enclosure (camera height, lighting mount, sample tray)
- [ ] Write and test `setup.sh` provisioning script on a fresh Pi
- [ ] Build Wi-Fi Manager UI
- [ ] Build Scanner UI with camera integration
- [ ] Test end-to-end: device → backend → database
- [ ] Field test with 20+ real scans, validate results

### Phase 5 — Frontend Dashboard  *(Weeks 9–11)*
- [ ] Scaffold Next.js project
- [ ] Implement login + auth
- [ ] Build device selector + scan feed page
- [ ] Build scan detail page with annotated image overlay
- [ ] Deploy to Vercel, connect to production API

### Phase 6 — Integration Testing & Launch  *(Week 12)*
- [ ] Full end-to-end test: physical sample → device → cloud → dashboard
- [ ] Accuracy validation: 100 samples compared to lab manual grading
- [ ] Performance test: inference time, concurrent scan handling
- [ ] Documentation: user manual for device operators
- [ ] Handoff to stakeholders

---

## 11. Open Decisions & Risk Register

### Decisions Needed From Team

| # | Decision | Options | Owner | Deadline |
|---|---|---|---|---|
| D1 | Confirm grading standard to use | NSQS / ISO 7301 / Internal spec | Product | Week 1 |
| D2 | Single-stage vs two-stage inference | One combined model vs Stage 1 + Stage 2 | ML Team | Week 3 |
| D3 | GPU inference: self-hosted vs Roboflow API | Self-hosted (lower latency/cost) vs Roboflow hosted API (easier) | DevOps | Week 5 |
| D4 | Cloud provider | Railway + Vercel vs AWS full stack | DevOps | Week 5 |
| D5 | Enclosure manufacturing method | 3D print vs CNC vs off-the-shelf | Hardware | Week 2 |

### Risk Register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Chalky region annotation is subjective between annotators | High | High | Write precise annotation guide with image examples; use second-reviewer QA pass |
| Model underperforms on new rice varieties not in training set | Medium | High | Ensure variety diversity in dataset; plan for periodic retraining |
| Pi inference too slow (>10s per image) | Medium | Medium | Use quantized `int8` model; fall back to cloud inference if needed |
| Image quality varies between device units (lighting drift) | Medium | High | Calibrate lighting per unit; include calibration step in setup script |
| Grains overlap in sample tray | High | Medium | Define max sample weight in operator instructions; enclosure tray design should spread grains |

---

*This document is a living spec. Update version number and date when sections change.*
*For questions, ping the team lead before making architectural changes.*