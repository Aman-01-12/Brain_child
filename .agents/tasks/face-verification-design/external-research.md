# External Research Memo — Face-Matching Identity Verification for Secure Interview Mode

**Prepared for:** the design + architecture document for candidate-identity verification in secure interview mode.
**Scope:** verified external facts only. No design decisions are made here.
**All sources checked:** 30 October 2026 unless a different date is stated inline.
**Environment context established during research:** current macOS release line is macOS 27 ("Golden Gate", released September 2026); macOS 26 "Tahoe" is at 26.7.x and macOS 15 "Sequoia" at 15.8.x, both still receiving security updates ([Apple — About the security content of macOS Tahoe 26.3](https://support.apple.com/en-us/126348), checked 2026-10-30; [9to5Mac — macOS 27.0.1 / 26.7.1 / 15.8.1 release](https://9to5mac.com/2026/09/28/apple-releases-macos-27-0-1-golden-gate-plus-macos-tahoe-26-7-1-and-macos-sequoia-15-8-1/), 2026-09-28, secondary). A deployment target of macOS 15.6 therefore has to run correctly on three major OS generations.

A consolidated **"Unverified / could not confirm"** list appears at the end (§12). Content from sources was rephrased for compliance with licensing restrictions.

---

## 1. Apple Vision framework — face capabilities on current macOS

### 1.1 The headline finding: there is no face-recognition API in Vision

**The premise that `VNGenerateFaceprintRequest` / `VNFaceprint` exists as public API is false.** I enumerated the complete symbol list of the current Vision framework documentation (the macOS 27 SDK docs) directly from Apple's documentation JSON. The framework exposes 66 top-level symbols. Exactly four relate to faces or feature prints:

| Symbol | Purpose |
| --- | --- |
| `DetectFaceRectanglesRequest` | face bounding boxes |
| `DetectFaceLandmarksRequest` | eyes, nose, mouth landmarks |
| `DetectFaceCaptureQualityRequest` | a single quality float |
| `GenerateImageFeaturePrintRequest` | **generic whole-image** feature print, not face-specific |

Source: [Apple — Vision framework](https://developer.apple.com/documentation/vision) (symbol inventory extracted from the documentation data endpoint `developer.apple.com/tutorials/data/documentation/vision.json`), checked 2026-10-30.

The legacy Objective-C/Swift surface (112 `VN*` symbols) likewise contains no faceprint type: only `VNDetectFaceRectanglesRequest`, `VNDetectFaceLandmarksRequest`, `VNDetectFaceCaptureQualityRequest`, `VNFeaturePrintObservation`, `VNGenerateImageFeaturePrintRequest` and the two landmark-point helper functions. Source: [Apple — Original Objective-C and Swift API](https://developer.apple.com/documentation/vision/original-objective-c-and-swift-api), checked 2026-10-30. A targeted search of that page for the string "Faceprint" returns zero matches.

**`VNFaceObservation` carries no identity information.** Its documented members are: `landmarks`, `roll`, `yaw`, `pitch`, `faceCaptureQuality`, and two initialisers. There is no embedding, descriptor, or template property. Available since macOS 10.13. Source: [Apple — VNFaceObservation](https://developer.apple.com/documentation/vision/vnfaceobservation), checked 2026-10-30.

Apple does run on-device face recognition in Photos, and has published research describing it, but it is not exposed as an API: [Apple Machine Learning Research — Recognizing People in Photos Through Private On-Device Machine Learning](https://machinelearning.apple.com/research/recognizing-people-photos) (2022), checked 2026-10-30.

### 1.2 What the available requests actually return

**`VNDetectFaceRectanglesRequest`** — macOS 10.13+. Returns faces as rectangular bounding boxes with origin and size. Revisions 1, 2, 3 exist. ([Apple docs](https://developer.apple.com/documentation/vision/vndetectfacerectanglesrequest), checked 2026-10-30)

**`VNDetectFaceLandmarksRequest`** — macOS 10.13+. By default locates all faces first, then analyses each for facial features; you can instead supply pre-computed `VNFaceObservation` objects via `inputFaceObservations`. Revisions 1, 2, 3; a `constellation` property selects the landmark set. ([Apple docs](https://developer.apple.com/documentation/vision/vndetectfacelandmarksrequest), checked 2026-10-30)

**`VNDetectFaceCaptureQualityRequest`** — macOS 10.15+. Populates `VNFaceObservation.faceCaptureQuality` with a float in a documented range; higher values correspond to better lit, sharper, and more centrally positioned faces. If the request is not run or fails, the property is `nil`. Revisions 1 and 2. ([Apple docs](https://developer.apple.com/documentation/vision/vndetectfacecapturequalityrequest), checked 2026-10-30)

Note the documented nuance confirmed by an Apple engineer in the developer forums: both the rectangles request and the capture-quality request return `VNFaceObservation`s with pitch/yaw/roll, but `faceCaptureQuality` is populated only by the capture-quality request ([Apple Developer Forums thread 727899](https://developer.apple.com/forums/thread/727899), checked 2026-10-30 — forum, not formal documentation).

**Pitch availability caveat:** `pitch` on `VNFaceObservation` was added later than `roll`/`yaw`; community reports indicate it is only populated by some requests/revisions ([Apple WWDC21 session 10040 "Detect people, faces, and poses using Vision"](https://developer.apple.com/videos/play/wwdc2021/10040/) describes contiguous pitch/yaw/roll metrics as new in iOS/tvOS 15 and macOS 12; [Stack Overflow 77363872](https://stackoverflow.com/questions/77363872/getting-continuous-head-pose-information-from-vision-framework) reports pitch missing with landmarks revision 3 — secondary). Treat pitch as needing empirical confirmation on the target OS.

### 1.3 The generic feature print is not a face template

`VNGenerateImageFeaturePrintRequest` (macOS 10.15+) produces `VNFeaturePrintObservation`, which exposes `data`, `elementCount`, `elementType`, and `computeDistance(_:to:)`. The documented semantics of distance are only directional: shorter distances indicate greater similarity. ([Apple — VNFeaturePrintObservation](https://developer.apple.com/documentation/vision/vnfeatureprintobservation) and [computeDistance(_:to:)](https://developer.apple.com/documentation/vision/vnfeatureprintobservation/computedistance(_:to:)), checked 2026-10-30)

The modern Swift equivalents, `GenerateImageFeaturePrintRequest` and `FeaturePrintObservation` with `distance(to:) throws -> Double`, are **macOS 15.0+ / iOS 18.0+** — i.e. exactly the project's deployment floor. ([Apple docs: [GenerateImageFeaturePrintRequest](https://developer.apple.com/documentation/vision/generateimagefeatureprintrequest), [FeaturePrintObservation](https://developer.apple.com/documentation/vision/featureprintobservation), [distance(to:)](https://developer.apple.com/documentation/vision/featureprintobservation/distance(to:))], checked 2026-10-30)

This API describes whole-image similarity (it is the API behind "find visually similar photos"). It is not trained for, documented for, or scoped to face identity. Using it to compare two cropped faces is an off-label use with no accuracy claim behind it.

### 1.4 Accuracy figures, thresholds, stated limitations: Apple is silent

I found **no** Apple documentation that states:

- any FMR/FNMR, accuracy, or error-rate figure for any Vision face request;
- any recommended or example threshold for `computeDistance` / `distance(to:)`;
- any statement that Vision is, or is not, intended for identity verification;
- any statement about demographic performance of the face requests;
- any stability guarantee for feature-print values across OS releases.

**The silence is itself the finding.** Apple's own framework abstract describes Vision as being for "object detection, text recognition, and image segmentation" ([Vision overview](https://developer.apple.com/documentation/vision), checked 2026-10-30) — identity verification is not among the advertised uses, and no "do not use for identity" warning exists either. Contrast this with AWS, which publishes an explicit human-review recommendation (§3.1) and a threshold recommendation (§11.2).

### 1.5 Feature-print stability across OS versions — the template-caching risk

Apple versions the feature-print algorithm explicitly:

- `VNGenerateImageFeaturePrintRequestRevision1` — macOS 10.15+
- `VNGenerateImageFeaturePrintRequestRevision2` — **macOS 14.0+** ([Apple docs](https://developer.apple.com/documentation/vision/vngenerateimagefeatureprintrequestrevision2), checked 2026-10-30)
- The modern `GenerateImageFeaturePrintRequest.Revision` enum (macOS 15.0+) exposes **only `revision2`** ([Apple docs](https://developer.apple.com/documentation/vision/generateimagefeatureprintrequest/revision-swift.enum), checked 2026-10-30)

So the revision available through the new API on macOS 15 is a single fixed value today, but the mechanism for Apple to ship `revision3` is built in and has been used before.

Apple's own developer forums confirm that observations from different request revisions are not comparable ([Apple Developer Forums thread 732876](https://developer.apple.com/forums/thread/732876), checked 2026-10-30 — forum, not formal documentation). Independent reports describe computed distances changing materially between iOS 16 and iOS 17, breaking previously calibrated thresholds ([Stack Overflow 77185128](https://stackoverflow.com/questions/77185128/is-vnfeatureprintobservation-and-vision-distance-computation-different-for-two), 2023, secondary) and distances between byte-identical images not being zero ([Apple Developer Forums thread 721760](https://developer.apple.com/forums/thread/721760), checked 2026-10-30 — forum).

**Conclusion:** any stored Apple feature print must be treated as valid only for the exact revision that produced it, and must be re-derivable from a retained source image — or re-enrolment must be triggered on OS upgrade. Apple provides no stability guarantee.

### 1.6 macOS availability specifically

All four face/feature-print requests list macOS in their platform availability (10.13 for rectangles and landmarks; 10.15 for capture quality and legacy feature print; 15.0 for the modern Swift feature-print API). Apple states Vision is available on tvOS, iOS and macOS and takes advantage of Apple Silicon on the Mac ([Apple WWDC22 session 10024 "What's new in Vision"](https://developer.apple.com/videos/play/wwdc2022/10024/), checked 2026-10-30). macOS availability is not the constraint; the absence of a recognition API is.

### 1.7 What this means for the design

**Apple Vision cannot perform the face match.** It can do the supporting work well — detect that exactly one face is present, measure capture quality, and give head pose for framing gates — but the identity comparison must come from somewhere else (a bundled open model, or a cloud API). Any design that assumed an Apple on-device faceprint needs to be rewritten. Vision is still the right choice for the pre-flight quality/pose/single-face gate because it is free, first-party, on-device, and already available at the macOS 15.6 floor.

---

## 2. Core ML / open-model alternatives

### 2.1 Licensing — the decisive constraint

**InsightFace / ArcFace (`deepinsight/insightface`).** The split is explicit and it is a hard blocker for commercial use:

- Code: MIT, no restriction on academic or commercial use.
- Training data and **the models trained with that data: non-commercial research purposes only.**
- The README states that both manually downloaded models from the GitHub repo and auto-downloaded models from the Python library follow the non-commercial-research-only policy.
- A 2025-11-24 update directs anyone wanting to license the open-sourced recognition models (`buffalo_l` is named) to contact `recognition-oss-pack@insightface.ai`.

Source: [deepinsight/insightface README](https://github.com/deepinsight/insightface/blob/master/README.md), fetched 2026-10-30. Restated in bold in the model-zoo documentation: the pretrained models are for non-commercial research purposes only, covering both automatic and manual downloads ([insightface python-package model_zoo.md](https://github.com/deepinsight/insightface/blob/master/python-package/docs/model_zoo.md), fetched 2026-10-30). InsightFace sells commercial licences for these packages separately ([insightface.ai model licensing](https://www.insightface.ai/solutions/face-recognition-licensing), checked 2026-10-30).

**DeepFace (`serengil/deepface`).** The wrapper library is MIT ([LICENSE](https://github.com/serengil/deepface/blob/master/LICENSE), fetched 2026-10-30). But DeepFace is a *wrapper*: its README lists the external models it pulls in (VGG-Face, FaceNet 128d/512d, OpenFace, DeepID, ArcFace, Dlib, SFace, GhostFaceNet, Buffalo_L) and the detectors (RetinaFace, MTCNN, YuNet, YOLO/Ultralytics, MediaPipe, CenterFace), and states that licence types are inherited and must be checked for production use ([DeepFace README, Licence section](https://github.com/serengil/deepface/blob/master/README.md), fetched 2026-10-30).

Two inherited problems that matter: Buffalo_L is the non-commercial InsightFace package, and YOLO/Ultralytics is AGPL-3.0 unless commercially licensed. **DeepFace is not a drop-in production dependency** — it is a research convenience layer whose licence posture depends entirely on which backend you select, and its default stack includes non-commercially-licensed weights.

**Commercially usable alternatives I verified:**

| Model | Code licence | Weights | Size | Published accuracy |
| --- | --- | --- | --- | --- |
| **SFace** (OpenCV Zoo) | Apache 2.0 | ONNX shipped in repo under same licence | 38.7 MB fp32 / 9.9 MB int8 | 0.9940 (0.9942 block-quant, 0.9932 quant) on the repo's own eval |
| FaceNet (`davidsandberg/facenet`) | MIT | TF checkpoints trained on VGGFace2/CASIA-WebFace | — | — |
| facenet-pytorch (`timesler`) | MIT | Inception-ResNet-v1 on VGGFace2/CASIA-WebFace | — | — |

Sources: [OpenCV Zoo SFace LICENSE](https://github.com/opencv/opencv_zoo/blob/main/models/face_recognition_sface/LICENSE) (Apache 2.0) and [SFace README](https://github.com/opencv/opencv_zoo/blob/main/models/face_recognition_sface/README.md), both fetched 2026-10-30; model file sizes measured from the repo's Git-LFS objects on 2026-10-30. [davidsandberg/facenet LICENSE](https://github.com/davidsandberg/facenet/blob/master/LICENSE.md) and [facenet-pytorch LICENSE](https://github.com/timesler/facenet-pytorch/blob/master/LICENSE.md), both MIT, fetched 2026-10-30.

SFace model files encode MobileFaceNet instances trained with the SFace loss, converted to ONNX from the original codebase; the repo notes it currently supports 5-landmark warping. The README does not name the benchmark for the 0.9940 figure — treat it as the repo's own evaluation harness, not an independently audited LFW number (see §12).

**Caveat on FaceNet weights:** the code licences are MIT, but the published checkpoints were trained on VGGFace2 and CASIA-WebFace, which carry their own dataset terms. I did not verify the current terms of those datasets (see §12).

### 2.2 Published accuracy, and the vendor's own demographic numbers

InsightFace publishes per-demographic accuracy for its own packages. This table is unusually useful because it is a vendor self-report of a demographic differential, and it includes an Indian subset:

| Package | Recognition model | Pack size | MR-ALL | African | Caucasian | South Asian | East Asian | LFW | CFP-FP | AgeDB-30 | IJB-C(E4) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `buffalo_l` | ResNet50 @ WebFace600K | 326 MB | 91.25 | 90.29 | 94.70 | **93.16** | **74.96** | 99.83 | 99.33 | 98.23 | 97.25 |
| `buffalo_s` | MobileFaceNet @ WebFace600K | 159 MB | 71.87 | 69.45 | 80.45 | **73.39** | **51.03** | 99.70 | 98.00 | 96.58 | 95.02 |
| `antelopev2` | ResNet100 @ Glint360K | 407 MB | — | — | — | — | — | — | — | — | — |
| `buffalo_sc` | MobileFaceNet @ WebFace600K | 16 MB | same as `buffalo_s` | | | | | | | | |

Source: [insightface python-package model_zoo.md](https://github.com/deepinsight/insightface/blob/master/python-package/docs/model_zoo.md), fetched 2026-10-30.

**The metric matters, so here it is precisely.** For the multi-racial (MR) sets, the InsightFace benchmark measures **TAR on an all-to-all 1:1 protocol at FAR below 1e-6**. The MR test set holds 242,143 identities and 1,624,305 images; the "Indian" subset (reported as "South Asian" in the model-zoo table) has 35,086 identities, 237,080 images, 688,259 positive pairs and ~56.2 billion negative pairs. Source: [insightface MFR challenge README](https://github.com/deepinsight/insightface/blob/master/challenges/mfr/README.md), fetched 2026-10-30.

Read as error rates at FMR = 1e-6, `buffalo_l` gives roughly **6.8% FNMR on Indian faces, 5.3% on Caucasian, 9.7% on African, and 25.0% on East Asian.** Note how far these are from the 99.83% LFW figure — LFW is saturated and tells you nothing operationally useful.

For reference on the heavier end, ArcFace ResNet100 is 65.13 M parameters and 24.21 GFLOPs at 112×112 RGB input ([getchui/deep_learning_inference_framework_benchmarks](https://github.com/getchui/deep_learning_inference_framework_benchmarks), checked 2026-10-30, secondary); the ONNX Model Zoo `arcfaceresnet100-8.onnx` artefact is 261 MB (measured 2026-10-30 from [onnxmodelzoo/arcfaceresnet100-8](https://huggingface.co/onnxmodelzoo/arcfaceresnet100-8)).

### 2.3 Inference on Apple Silicon and on a small server

**ONNX Runtime has a Core ML execution provider that supports macOS.** Requirements: iOS 13+ or macOS 10.15+; Apple recommends devices with a Neural Engine for best performance. Official macOS Python wheels include the Core ML EP, and the official macOS arm64 C/C++/Java/Node.js packaging jobs also build with `--use_coreml`. Custom local builds do **not** include it unless `--use_coreml` is passed. The EP must be explicitly registered when creating the session; `ModelFormat=MLProgram` requires Core ML 5 (macOS 12+), `MLComputeUnits` selects CPU/ANE/GPU/ALL. There is a `ModelCacheDirectory` option because first-run subgraph compilation to Core ML can be slow — the docs warn it can cost minutes for a complicated model, and that ONNX Runtime does not invalidate the cache when the model changes. Source: [ONNX Runtime — CoreML Execution Provider](https://onnxruntime.ai/docs/execution-providers/CoreML-ExecutionProvider.html), checked 2026-10-30.

The supported-operator tables on that page are finite and per-format. A face-recognition backbone must be checked op-by-op: ops outside the list fall back to CPU, which silently removes the ANE benefit.

InsightFace's own current Python package advertises automatic Core ML/CUDA/CPU provider selection with reusable Core ML compilation caches ([deepinsight/insightface README](https://github.com/deepinsight/insightface), checked 2026-10-30) — useful as evidence that the Core ML path is a trodden one, though the weights remain non-commercial.

**Latency:** I did not find an authoritative, current, Apple-Silicon-specific latency benchmark for a face-embedding model from a primary source, and I did not run one. Treat latency as something to measure on the target hardware rather than a number to quote (see §12). The structural facts that do hold: a 112×112 single-face embedding is a tiny workload compared with the video encode/decode the app is already doing; a MobileFaceNet-class model (16–40 MB) is a different order of cost from a ResNet100 (261–407 MB), and model size drives app-bundle size and cold-start compile time as much as it drives inference time.

### 2.4 What this means for the design

**If this ships commercially, InsightFace/ArcFace pretrained weights and DeepFace's default stack are off the table** — the licence is non-commercial-research-only and InsightFace sells the commercial licence separately. The commercially-clean on-device option I verified is **SFace from OpenCV Zoo (Apache 2.0, 38.7 MB fp32 / 9.9 MB int8, ONNX, runs under ONNX Runtime's Core ML EP on the macOS 15.6 floor)**. If the project remains an unreleased university project, InsightFace `buffalo_l` is usable for the prototype but must be flagged as a commercial blocker in the design doc, not silently inherited.

---

## 3. AWS Rekognition — CompareFaces and Face Liveness

### 3.1 CompareFaces: shape, semantics, and AWS's own human-review warning

`CompareFaces` compares the largest face in the source image against each of the up-to-100 largest faces detected in the target image. If the source holds multiple faces, the service picks the largest.

**Request** (`SourceImage`, `TargetImage` as base64 bytes or S3 object refs; `SimilarityThreshold`; `QualityFilter`):

- `SimilarityThreshold` — Float, valid range 0–100, optional. The minimum match confidence for a match to appear in `FaceMatches`. **Default behaviour: only faces at similarity ≥ 80% are returned.**
- `QualityFilter` — `NONE | AUTO | LOW | MEDIUM | HIGH`, default `NONE`. Filtered faces are not compared. Using quality filtering requires face model version 3 or higher.

**Response:** an array of face matches ordered by descending similarity. Each match carries a bounding box, facial landmarks, pose (pitch/roll/yaw), quality (brightness and sharpness), and a confidence value for the bounding box containing a face — plus the `Similarity` score itself. The operation also returns `UnmatchedFaces` with the same per-face detail, and information about the source face. If no faces are found in either image it returns `InvalidParameterException`. **It is a stateless operation — data returned does not persist.**

**AWS's own caution, quoted in substance:** `CompareFaces` uses probabilistic machine-learning algorithms. AWS recommends comparing the target against multiple source images to reduce false negatives, and — this is the load-bearing sentence — states that if you plan to use `CompareFaces` to make a decision affecting an individual's rights, privacy, or access to services, the result should be passed to a human for review and further validation before action is taken.

Source: [AWS — CompareFaces API Reference](https://docs.aws.amazon.com/rekognition/latest/APIReference/API_CompareFaces.html), checked 2026-10-30.

### 3.2 Image size and format limits (set quotas, not adjustable)

- Maximum image as **raw bytes passed to an API: 5 MB**.
- Maximum image **stored as an S3 object: 15 MB**.
- Supported formats: **PNG and JPEG only.**
- Minimum image dimensions: 80 px in both height and width.
- A face must be no smaller than **40×40 px within a 1920×1080 image**; larger images need a proportionally larger minimum face.
- Passing image bytes is not supported when calling via the AWS CLI (SDKs are fine).

Source: [AWS — Guidelines and quotas in Amazon Rekognition](https://docs.aws.amazon.com/rekognition/latest/dg/limits.html), checked 2026-10-30.

Separately, AWS's input-image recommendations for face comparison: pitch under 30° down and under 45° up, yaw under 45° either direction, no roll restriction; both eyes open and visible; full head and shoulders rather than a tight face crop; colour images; flat lighting; high-contrast background; neutral expression with mouth closed for high-precision applications. Rekognition can recognise faces as small as 50×50 px up to 1920×1080 resolution. Source: [AWS — Recommendations for facial comparison input images](https://docs.aws.amazon.com/rekognition/latest/dg/recommendations-facial-input-images.html), checked 2026-10-30.

### 3.3 Face Liveness: what it does, and the SDK wall

Face Liveness verifies that a user is physically present in front of a camera, detecting both attacks presented *to* the camera (printed photos, digital photos, digital video, 3D masks) and attacks that *bypass* the camera (pre-recorded or deepfake video). The user takes a short selfie video following prompts.

**Outputs per check:**
- a confidence score 0–100 (higher = more confidence the subject is live);
- one high-quality **reference image** extracted from the video, usable for face comparison or search;
- up to **four audit images** from the selfie video, for an audit trail;
- for low-confidence sessions, one or more **feedback codes**: `FACE_NOT_VISIBLE`, `FACE_OBSTRUCTION_DETECTED`, `LOW_VIDEO_QUALITY_DETECTED`, `FACE_NOT_ALIGNED`, `EYES_CLOSED_DETECTED`, `LOW_LIGHTING_DETECTED`, `HIGH_LIGHTING_DETECTED`. A session can return several at once and they are unordered.

**Session-based flow — three API operations:**
1. `CreateFaceLivenessSession` — starts the session, returns a `SessionId`, and sets `ChallengePreference`.
2. `StartFaceLivenessSession` — called *by the Amplify `FaceLivenessDetector` component*, opens an event stream.
3. `GetFaceLivenessSessionResults` — returns score, reference image, audit images, SDK type used, and feedback codes.

**Two challenge modes:** `FaceMovementAndLightChallenge` (face into an on-screen oval, then a sequence of coloured lights on screen; AWS calls this the best setting for accuracy) and `FaceMovementChallenge` (oval only, no light sequence; faster, less accurate). AWS tells customers to decide between them based on expected attack types and desired false-accept/false-reject rates, after testing on their own content, and adds that **application owners should implement controls to secure the device the video stream is sent from.**

The oval position, shape, size, the coloured lights, the countdown time and the face-fit time are **not customisable** — AWS states these were fixed based on large-scale internal studies for accuracy and latency balance. Theme, colour, language, text and font are customisable.

**End-to-end latency as documented by AWS:** best case 5 s, average ~7 s, worst case 11 s.

**PAD conformance:** AWS states Face Liveness passed iBeta Presentation Attack Detection Level 1 and Level 2 conformance testing with a perfect PAD score, iBeta testing being conducted in accordance with ISO/IEC 30107-3 and iBeta being NIST/NVLAP-accredited for that standard.

**Opt-out of training use:** image and video inputs can be excluded from service-improvement use via an AWS Organizations AI-services opt-out policy.

Sources: [AWS — Detecting face liveness](https://docs.aws.amazon.com/rekognition/latest/dg/face-liveness.html) and [AWS — Face Liveness FAQ](https://docs.aws.amazon.com/rekognition/latest/dg/face-liveness-faq.html), both checked 2026-10-30.

#### The macOS blocker

**Face Liveness cannot be used without the Amplify SDK.** The FAQ answers this directly: the Amplify SDK is required to use the Rekognition Face Liveness feature. The documented client components are **AWS Amplify SDK for React (web), Swift (iOS), and Android**, each providing a `FaceLivenessDetector`. The pricing page describes it as addable to "React web, native iOS, and native Android applications."

**There is no native macOS client SDK for Face Liveness.** The Swift component is the iOS component. No AWS documentation I found lists macOS as a supported Face Liveness client platform. For a native macOS app the only routes are (a) embed a WKWebView running the React component, or (b) drop Face Liveness and build challenge-response in-house. Note also the FAQ's remark that the mobile SDKs auto-adjust screen brightness while the web SDK cannot, so a WKWebView route inherits the web SDK's weaker position.

Sources: [AWS — Detecting face liveness](https://docs.aws.amazon.com/rekognition/latest/dg/face-liveness.html), [Face Liveness FAQ](https://docs.aws.amazon.com/rekognition/latest/dg/face-liveness-faq.html), [Amazon Rekognition pricing](https://aws.amazon.com/rekognition/pricing/), all checked 2026-10-30.

### 3.4 Region availability, including India

**Rekognition Image** has been available in Asia Pacific (Mumbai), `ap-south-1`, since August 2018 ([AWS What's New — Rekognition in Seoul and Mumbai](https://aws.amazon.com/about-aws/whats-new/2018/08/amazon-rekognition-is-now-available-in-the-asia-pacific-seoul-and-asia-pacific-mumbai-regions/), 2018-08, checked 2026-10-30).

**Face Liveness** is currently available in: US East (N. Virginia), US West (Oregon), Europe (Ireland), **Asia Pacific (Tokyo, Mumbai)**, South America (São Paulo), Asia Pacific (Malaysia), Asia Pacific (Thailand). AWS notes that if your S3 bucket is in a different region from the Face Liveness region, you must take the images as raw bytes rather than via S3. Source: [AWS — Face Liveness FAQ](https://docs.aws.amazon.com/rekognition/latest/dg/face-liveness-faq.html), checked 2026-10-30.

**India is covered for both.** `ap-south-1` is a data-residency-friendly choice for a DPDP-primary deployment.

### 3.5 Current pricing (ap-south-1 / Mumbai, from the AWS Price List API)

Queried from the authoritative AWS Price List offer file for `AmazonRekognition` in `ap-south-1` on **2026-10-30** (`https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonRekognition/current/ap-south-1/index.json`):

| Item | Tier | Price |
| --- | --- | --- |
| Rekognition Image API (includes `CompareFaces`) | first 1 M images/month | **$0.00125 / image** ($1.25 per 1,000) |
| | 1 M – 5 M | $0.0010 / image |
| | 5 M – 35 M | $0.00075 / image |
| | 35 M + | $0.0003125 / image |
| **Face Liveness** (`operation: StartFaceLivenessSession`, `usagetype: APS3-StreamingCalls`) | 0 – 500 K checks/month | **$0.018 / check** |
| | 500 K – 3 M | $0.015 / check |
| | 3 M + | $0.012 / check |
| Face Vector Storage | — | $0.012 per 1,000 faces/month |

For comparison, Face Liveness in `us-east-1` on the same date: $0.015 / $0.0125 / $0.010 per check across the same tiers. This matches the worked examples on the public pricing page, which uses $0.015 for the first 500,000 N. Virginia checks ([Amazon Rekognition pricing](https://aws.amazon.com/rekognition/pricing/), checked 2026-10-30).

**Per-verification cost in Mumbai:** a single `CompareFaces` call costs $0.00125. Add a Face Liveness session and the cost per candidate becomes roughly **$0.019** — about 15× the cost of the match alone. Liveness, not matching, is where the cloud bill lives.

### 3.6 What this means for the design

Rekognition `CompareFaces` is cheap, available in Mumbai, well documented, and ships with AWS's own written recommendation to route rights-affecting results to a human — which is a direct argument for the three-outcome design. **Face Liveness, however, is effectively unavailable to a native macOS client** without embedding a web view, which turns the strongest available anti-spoof control into an awkward dependency and pushes the design toward in-house challenge-response.

---

## 4. Azure AI Face — access gating

### 4.1 Current status: gated, and gated on a criterion this project cannot meet

Microsoft's current legal/responsible-AI page states, in substance:

- Microsoft facial-recognition services are **Limited Access**, to help prevent misuse in line with Microsoft's AI Principles and facial-recognition principles.
- Customers and partners wanting the **Limited Access features of the Face API, which include Face identification and Face verification, must register by submitting a registration form.**
- **Face Detection is available without registration.**
- The Limited Access features are available only on **Standard (S0) and Enterprise (E0)** tiers — **not** on the Free (F0) tier.
- Access is at **Microsoft's sole discretion** based on eligibility criteria and a vetting process.
- **Face API is available only to "customers managed by Microsoft," defined as customers and partners working directly with Microsoft account teams.**
- Face API is only available for certain use cases; the customer must select the intended use case at registration, and Microsoft may require periodic reverification.
- Since the 11 June 2020 announcement, Azure Face recognition is strictly prohibited for use by or for U.S. police departments.

Source: [Microsoft — Limited Access features of Face](https://learn.microsoft.com/en-us/legal/cognitive-services/computer-vision/limited-access-identity), fetched 2026-10-30 (primary — Microsoft's own legal documentation).

Corroborated across Microsoft's product documentation: Face service access is limited based on eligibility and usage criteria to support responsible-AI principles, and is only available to Microsoft-managed customers and partners, with access requested via the Face Recognition intake form ([Microsoft — What is the Azure AI Face service?](https://learn.microsoft.com/en-us/azure/cognitive-services/computer-vision/overview-identity/) and [Quickstart: Use the Face service](https://learn.microsoft.com/en-us/azure/ai-services/face/quickstarts-sdk/identity-client-library), checked 2026-10-30).

The broader Limited Access framework states that these services require registration and that only Microsoft-managed customers — those working directly with Microsoft account teams — are eligible, with use confined to the registered use case ([Microsoft — Limited Access features for Azure AI services](https://learn.microsoft.com/en-us/azure/ai-services/cognitive-services-limited-access), checked 2026-10-30).

### 4.2 The one back door, and why it doesn't help here

Microsoft provides a **limited access token** mechanism: an approved ISV can issue tokens letting its client companies use normally-gated Face features without each going through the formal approval process. But only ISVs that themselves pass the gating requirements get this capability, and approval requests go to `azureface@microsoft.com`. Source: [Microsoft — Use limited access tokens (Face)](https://learn.microsoft.com/en-us/azure/ai-services/computer-vision/how-to/identity-access-token), checked 2026-10-30.

So the back door requires being an approved ISV — the same gate, one level up.

### 4.3 Realistic obtainability for this product

Judged against Microsoft's own stated criterion — availability restricted to customers and partners **working directly with Microsoft account teams**, at Microsoft's sole discretion — a Shri Mata Vaishno Devi University student project has no path to Face identification or Face verification. There is no self-service route, and Microsoft's community answers confirm that access is controlled per Azure subscription/tenant through registration and vetting, with no documented self-service way to move an existing approval between subscriptions ([Microsoft Q&A 5832690](https://learn.microsoft.com/en-us/answers/questions/5832690/face-api-verification-approval-not-working-on-my-s), 2026, Microsoft-hosted but community-answered).

**I cannot verify a specific approval outcome** — only that the stated criterion excludes unmanaged customers (see §12).

### 4.4 What this means for the design

**Treat Azure Face verification as unavailable.** Do not list it as an option in the architecture document except as an explicitly rejected alternative with this gating cited. Azure Face *Detection* remains ungated, but detection is the one thing Apple Vision already does locally for free.

---

## 5. Liveness and presentation-attack detection

### 5.1 The correct vocabulary: ISO/IEC 30107-3

**The current edition is ISO/IEC 30107-3:2023 (Edition 2, published January 2023, 39 pages)**, superseding the 2017 first edition. It establishes principles and methods for assessing PAD mechanism performance, how to report test results, and a classification of known attack types (Annex A). Explicitly **out of scope**: standardising specific PAD mechanisms, detailed countermeasure/algorithm/sensor information, and overall system-level security or vulnerability assessment. Critically: **the attacks it considers take place at the biometric capture device during presentation; any other attack is out of scope.** Source: [ISO/IEC 30107-3:2023](https://www.iso.org/standard/79520.html), checked 2026-10-30.

That scope limit is the single most important sentence in the standard for this design: **a virtual camera is not a presentation attack.** It is an injection attack, outside 30107-3 entirely — so an iBeta Level 1/2 PAD certification says nothing about it.

**The two metrics, as defined in the standard** (restated from the standard editor's NIST-hosted presentation):

- **APCER — Attack Presentation Classification Error Rate:** the proportion of attack presentations incorrectly classified as bona fide presentations, at the component level, in a specific scenario. When testing against multiple PAI species, the highest APCER (that of the most successful PAI) is the one to use.
- **BPCER — Bona Fide Presentation Classification Error Rate:** the proportion of bona fide presentations incorrectly classified as attack presentations, at the component level, in a specific scenario.

Source: [Christoph Busch (ISO/IEC 30107-3 editor) — "The ISO/IEC 30107-3 standard for testing of Presentation Attack Detection", hosted by NIST](https://www.nist.gov/system/files/documents/2020/09/15/12_buschthieme-ibpc-pad-160504.pdf), checked 2026-10-30.

NIST's own plain-language gloss is the one worth borrowing for the design doc: **BPCER is the inconvenience rate for legitimate users; APCER is the rate at which fraud succeeds. BPCER states the convenience of a system, APCER its security.** The standard's definition of a presentation attack is "the presentation of an artefact or of human characteristics to a biometric capture subsystem in a fashion intended to interfere with system policy." Source: [NIST IR 8491 — FATE Part 10](https://doi.org/10.6028/NIST.IR.8491), September 2023, checked 2026-10-30.

The two operating points NIST reports, and which the design should adopt as its vocabulary:

- **APCER @ BPCER = 0.01** — convenience-focused: undetected attacks when false rejection of genuine users is held to 1%.
- **BPCER @ APCER = 0.01** — security-focused: genuine users falsely flagged when the attack miss rate is held to 1%.

### 5.2 What passive liveness on a single RGB webcam frame actually achieves

**NIST IR 8491 (FATE Part 10, September 2023)** is the authoritative measurement. It evaluated **82 prototype algorithms from 45 developers** on conventional 2D still and video face imagery, against ~**20,000 attack presentations and ~21,000 bona fide presentations across 9 PA categories**, offline on NIST-sequestered data. Every PAI used was documented in the public domain, so developers could have defended against them.

**What it explicitly did NOT evaluate:** approaches based on 3D, near-infrared illumination, real-time human interaction with a camera (including challenge-response), variable illumination, or automated adjustment of the imaging system. And — directly relevant here — **the report is silent on non-presentation attacks, including injection attacks.**

**Headline findings:**
- PAD accuracy varies widely across algorithms, use cases (impersonation vs. evasion), and PA types, with **only a small percentage of evaluated algorithms showing notable detection capability.**
- Well supported across multiple developers: **photo print/replay attacks, protective face masks, and flexible silicone face masks.**
- **Other PA types produced high detection error rates with every tested implementation.**
- Many algorithms do better on a **video sequence than on a single still** from the same capture event.
- Simple sum-rule **fusion of scores across multiple algorithms beat the single best algorithm** in all impersonation categories and most evasion categories.

**Top-performer numbers, impersonation task, stills** (Table 1):

| PA Type | Description | APCER @ BPCER = 0.01 | BPCER @ APCER = 0.01 |
| --- | --- | --- | --- |
| Type 8 | Photo print/replay attack | **0.0** (alice-001, idemia-011, idrnd-000, idrnd-001) | 0.0001 (idrnd-001) |
| Type 8 (zoomed) | Photo print/replay, zoomed | 0.005 (idrnd-001) | 0.006 (idrnd-001) |
| Type 3 | Flexible silicone face mask | **0.0** (stcon-001) | 0.0003 (stcon-001) |
| Type 7 | (undisclosed) | 0.012 (cyberlink-002) | 0.012 (cyberlink-002) |
| Type 1 | (undisclosed) | 0.07 (kakao-001) | 0.069 (iproov-000) |
| Type 4 | (undisclosed) | **0.13** (cyberlink-002) | **0.200** (aware-001) |

**Evasion task, stills** (Table 2) is worse: PA Type 4 best-in-class APCER @ BPCER = 0.01 is **0.62**, i.e. the best algorithm tested missed 62% of those attacks while rejecting only 1% of genuine users.

Source: [NIST IR 8491 — FATE Part 10: Performance of Passive, Software-Based Presentation Attack Detection (PAD) Algorithms](https://doi.org/10.6028/NIST.IR.8491) (PDF: [tsapps.nist.gov](https://tsapps.nist.gov/publication/get_pdf.cfm?pub_id=956456)), September 2023, checked 2026-10-30.

### 5.3 What a single 2D webcam frame genuinely cannot establish

Stated plainly, grounded in the sources above:

1. **It cannot establish that the frame came from the camera.** 30107-3's scope stops at the capture device; NIST IR 8491 is explicitly silent on injection. A frame delivered by a virtual camera is indistinguishable at the pixel level from one delivered by hardware, because it *is* just pixels (§6).
2. **It cannot establish temporal liveness.** A single frame has no motion, no blink, no pulse, no response to a stimulus. The only signals available are texture, moiré, specularity, colour statistics, and depth cues inferred from a 2D projection.
3. **It cannot reliably detect the harder attack classes.** NIST measured best-in-class APCER of 0.13 (impersonation) and 0.62 (evasion) at BPCER = 0.01 for at least one attack type, across 82 algorithms.
4. **It cannot establish that the person is unaided or alone.** Framing, pose and quality are all it sees.
5. **It performs measurably better on video than on a single still**, per NIST — so single-frame passive PAD is the weakest configuration available.

What it *can* do: reliably catch the cheap attacks — a held-up printed photo or a phone screen replayed to the camera — at essentially zero APCER with 1% BPCER, per NIST Table 1. That is a real and worthwhile control. It is just not identity assurance.

### 5.4 Active challenge-response: why randomisation and timing bounds matter

The threat model is pre-recorded replay. If the challenge is fixed or predictable, an attacker records the correct response once and replays it. Two properties defeat that:

- **Challenge randomisation** — the specific challenge is drawn server-side, per session, from a space large enough that a pre-recorded library cannot cover it. AWS's design is instructive: in `FaceMovementAndLightChallenge` the SDK displays a *sequence of coloured lights* on screen and streams the selfie video to the cloud, and AWS fixes the oval geometry and light sequence precisely because they are what deliver accuracy, refusing to let customers customise them ([AWS — Detecting face liveness](https://docs.aws.amazon.com/rekognition/latest/dg/face-liveness.html) and [Face Liveness FAQ](https://docs.aws.amazon.com/rekognition/latest/dg/face-liveness-faq.html), checked 2026-10-30). A screen-light sequence works as a challenge because the reflection off the subject's face is a function of a secret the attacker learns only at challenge time.
- **Timing bounds** — the response must arrive inside a window too short for a human or a tool to synthesise it. AWS similarly refuses to let customers change the countdown and face-fit times, stating they were pre-determined from large-scale studies across thousands of users to balance accuracy against latency, and reports end-to-end latency of 5 s best / ~7 s average / 11 s worst. Those numbers set a realistic expectation for any in-house equivalent.

The limit of this approach is also documented: a challenge-response protocol validates the *content* of the stream, and an injection attacker who can render a live face-swap in real time can satisfy the challenge. This is exactly what the published red-team work demonstrates (§6.5).

### 5.5 Current state of commercial and open PAD options

- **Commercial, cloud:** AWS Rekognition Face Liveness, iBeta PAD Level 1 and 2 conformant to ISO/IEC 30107-3, $0.018/check in Mumbai, but no native macOS client (§3).
- **Commercial, measured independently:** NIST IR 8491 names the vendors whose algorithms topped each category — among them idrnd, idemia, alice, stcon, kakao, cyberlink, iproov, aware, onfido, rankone. NIST's FATE PAD track exists as an ongoing evaluation with a published API ([FRVT/FATE PAD API v1.5, 1 February 2023](https://pages.nist.gov/frvt/api/FRVT_pad_api.pdf), checked 2026-10-30); note that as of the FRTE status page, **"Except PAD, all FRTE tracks are open"** — i.e. the PAD track was closed to new submissions as of the page's 2026-10-06 update ([NIST FRTE 1:1 Verification](https://pages.nist.gov/frvt/html/frvt11.html), checked 2026-10-30).
- **Open source:** DeepFace can optionally use the Silent-Face-Anti-Spoofing model for real/fake determination, whose licence is inherited and must be checked ([DeepFace README](https://github.com/serengil/deepface/blob/master/README.md), fetched 2026-10-30). InsightFace ships liveness as a separate optional add-on that must be enabled explicitly ([insightface model_zoo.md](https://github.com/deepinsight/insightface/blob/master/python-package/docs/model_zoo.md), fetched 2026-10-30) — and inherits the non-commercial model licence.
- **Research direction on injection specifically:** session-metadata-based detection of video injection, trained on metadata from authentic-user sessions ([arXiv 2512.10653](https://arxiv.org/html/2512.10653v1), checked 2026-10-30, preprint).

### 5.6 What this means for the design

Use **APCER/BPCER at a stated operating point** as the design's vocabulary, never "accuracy". Expect passive single-frame PAD to stop printed photos and screen replays and little else, and prefer short video over a single still. If an active challenge is built in-house, the two non-negotiable properties are server-side randomisation of the challenge and a hard response-time bound — and the design must state openly that neither defeats a real-time injection attacker.

---

## 6. Virtual camera detection on macOS

### 6.1 Short answer

**No. An app cannot reliably determine that the selected `AVCaptureDevice` is a software/virtual camera rather than physical hardware.** This is not a gap in the API that careful engineering can close — Apple's camera-extension architecture is *designed* so that virtual cameras are indistinguishable from real ones through AVFoundation, and the properties one would use as heuristics are writable by the extension author.

### 6.2 The architectural change: DAL plug-ins → Core Media I/O camera extensions

Apple's documentation states that camera extensions are a new type of system extension available in **macOS 12.3 and later**, providing a simple, secure model for high-performance camera drivers, packaged and installed with your app including via the App Store. Source: [Apple — Creating a camera extension with Core Media I/O](https://developer.apple.com/documentation/coremediaio/creating-a-camera-extension-with-core-media-i-o), checked 2026-10-30.

Apple introduced them at WWDC 2022 as "our modern replacement for legacy DAL plug-ins", describing the extensions as secure, fast, and **fully compatible with any app that uses a camera input** ([Apple WWDC22 session 10022 — "Create camera extensions with Core Media IO"](https://developer.apple.com/videos/play/wwdc2022/10022/), checked 2026-10-30). Community/vendor sources date the DAL deprecation announcement to WWDC 2022 with removal in macOS 14, and OBS's own tracking issue states the DAL plug-in path was deprecated in macOS 12.3 and removed in macOS 14 ([obs-studio PR 7777](https://github.com/obsproject/obs-studio/pull/7777); [CoreMediaIO-DAL-Example README](https://github.com/zhangyihu2018/CoreMediaIO-DAL-Example), both checked 2026-10-30, secondary).

**What the change gained for detection: almost nothing. What it gained for the attacker: compatibility.** Under the DAL model, virtual cameras were loaded as plug-ins into the client process and were frequently invisible to AVFoundation — which is why developers historically could not see OBS via `AVCaptureDevice.DiscoverySession` even though Chrome and Zoom could ([Apple Developer Forums thread 683814](https://developer.apple.com/forums/thread/683814); [Stack Overflow 68161335](https://stackoverflow.com/questions/68161335/macos-accessing-a-virtual-cameras-obs-as-avfoundation-capturedevice), both checked 2026-10-30, secondary). Under the extension model, Apple's documentation states the opposite outcome explicitly: camera extensions are fully compatible with AVFoundation capture APIs, so you can access an extension as an `AVCaptureDevice` and use it like any other device — and you retrieve your own extension *as well as any others on the system* by querying the external device type. Source: [Apple — Creating a camera extension with Core Media I/O](https://developer.apple.com/documentation/coremediaio/creating-a-camera-extension-with-core-media-i-o), checked 2026-10-30.

The architecture change made virtual cameras *more* uniformly visible and *more* uniformly indistinguishable.

### 6.3 Every candidate property, verified against Apple's docs

| Property | macOS availability | What Apple documents | Detection value |
| --- | --- | --- | --- |
| `deviceType` | 10.15+ (`DeviceType` struct) | Device-type constants for discovery sessions | **Low.** Virtual cameras appear as `.external`. The `DeviceType` enum's camera constants are the built-ins, `continuityCamera`, `deskViewCamera`, the depth cameras, plus `external` / `externalUnknown` under "External devices". There is no software-camera constant. |
| `transportType` | 10.7+ | "The transport type of the device, such as USB or PCI. The value is an IOKit framework transport type constant." | **Defeatable — see §6.4.** |
| `modelID` | 10.7+ | An identifier unique to all devices of the same model, persistent across connections and across different systems | **Defeatable.** Writable by the extension. |
| `uniqueID` | 10.7+ | Persists on one system across connections, app restarts and reboots | **Useful for pinning, not for classifying.** Tells you *which* device, not *what kind*. |
| `manufacturer` | 10.9+ | For all Apple devices the value is a fixed Apple string; **third-party manufacturers may supply no identifying text, in which case the value is an empty string** | **Low.** Apple's own documentation says the field is routinely empty for legitimate third-party hardware, so an empty or arbitrary string proves nothing. |
| `isContinuityCamera` | **13.0+** | Whether the device is a Continuity Camera (iPhone rear camera system used as an external webcam on macOS) | **Narrow but real.** Positively identifies one specific legitimate case. Does not identify software cameras. |
| `isVirtualDevice` | **NOT available on macOS** (iOS 13+, iPadOS 13+, Mac Catalyst 14+, tvOS 17+) | "whether the device consists of two or more **physical** devices" — examples given are the dual camera and the TrueDepth camera | **None.** Wrong platform *and* wrong meaning: it denotes a composite of multiple physical cameras, not a software camera. This property is a trap for anyone skim-reading the API. |

Sources, all [developer.apple.com](https://developer.apple.com/documentation/avfoundation/avcapturedevice) and all checked 2026-10-30: [AVCaptureDevice.DeviceType](https://developer.apple.com/documentation/avfoundation/avcapturedevice/devicetype-swift.struct), [transportType](https://developer.apple.com/documentation/avfoundation/avcapturedevice/transporttype), [modelID](https://developer.apple.com/documentation/avfoundation/avcapturedevice/modelid), [uniqueID](https://developer.apple.com/documentation/avfoundation/avcapturedevice/uniqueid), [manufacturer](https://developer.apple.com/documentation/avfoundation/avcapturedevice/manufacturer), [isContinuityCamera](https://developer.apple.com/documentation/avfoundation/avcapturedevice/iscontinuitycamera), [isVirtualDevice](https://developer.apple.com/documentation/avfoundation/avcapturedevice/isvirtualdevice), [external](https://developer.apple.com/documentation/avfoundation/avcapturedevice/devicetype-swift.struct/external), [externalUnknown](https://developer.apple.com/documentation/avfoundation/avcapturedevice/devicetype-swift.struct/externalunknown) (macOS 10.15, **deprecated 14.0**), [continuityCamera](https://developer.apple.com/documentation/avfoundation/avcapturedevice/devicetype-swift.struct/continuitycamera) (macOS 14.0+).

**Deployment-target note:** `.externalUnknown` is deprecated as of macOS 14.0 and `.external` / `.continuityCamera` were introduced in macOS 14.0. At a macOS 15.6 floor, use `.external` and `.continuityCamera`. (The widely reported runtime warning about `AVCaptureDeviceTypeExternal` being deprecated for Continuity Cameras, and the need for the `NSCameraUseContinuityCameraDeviceType` Info.plist key, is corroborated in [opencv issue 26305](https://github.com/opencv/opencv/issues/26305), 2024, secondary — worth checking empirically on the target OS.)

### 6.4 Why `transportType` and `modelID` heuristics are defeated by design

A plausible-sounding heuristic is: read `transportType`, and reject anything reporting the virtual transport. The constant exists — I confirmed from the macOS SDK headers on this machine (2026-10-30) that `CoreAudio`'s transport-type constants include `kAudioDeviceTransportTypeVirtual = 'virt'`, alongside `'bltn'` (built-in), `'usb '`, `'thun'`, `'blue'`, `'ccwd'` / `'ccwl'` (Continuity Capture wired/wireless) and others. Empirically, on this Mac the built-in camera reports `transportType` `0x626c746e` = `'bltn'`, `manufacturer` `"Apple Inc."`, `modelID` `"FaceTime HD Camera"`, `deviceType` `AVCaptureDeviceTypeBuiltInWideAngleCamera` (measured with a Swift `AVCaptureDevice.DiscoverySession` probe, 2026-10-30).

**The heuristic fails because the extension author chooses the value.** Apple's Core Media I/O API exposes these as *writable* properties on the extension's own device:

- `CMIOExtensionDeviceProperties.transportType` — declared `@nonobjc var transportType: Int? { get set }`, abstract: "The transport type of the device, such as USB or HDMI." macOS 12.3+.
- `CMIOExtensionDeviceProperties.model` — declared `var model: String? { get set }`, abstract: "A device model string." macOS 12.3+.
- Corresponding property keys `CMIOExtensionProperty.deviceTransportType` and `CMIOExtensionProperty.deviceModel`.

Sources: [Apple — CMIOExtensionDeviceProperties](https://developer.apple.com/documentation/coremediaio/cmioextensiondeviceproperties), [transportType](https://developer.apple.com/documentation/coremediaio/cmioextensiondeviceproperties/transporttype-96gm), [model](https://developer.apple.com/documentation/coremediaio/cmioextensiondeviceproperties/model), [CMIOExtensionProperty.deviceTransportType](https://developer.apple.com/documentation/coremediaio/cmioextensionproperty/devicetransporttype), all checked 2026-10-30.

A virtual camera can therefore declare `transportType` = USB and `model` = "FaceTime HD Camera". An attacker with any intent at all will. The same applies to `localizedName` — Apple's own extension guide highlights customising the device name string because it is what appears in camera-picker UI.

### 6.5 Are system extensions enumerable? Partially — and it does not solve the problem

`OSSystemExtensionManager` (macOS 10.15+) exposes `shared` and `submitRequest(_:)` only; its documented purpose is **activation and deactivation** of system extensions, with a delegate for results, user-authorisation prompts, and version conflicts. There is **no documented enumeration API**. Source: [Apple — OSSystemExtensionManager](https://developer.apple.com/documentation/systemextensions/ossystemextensionmanager), checked 2026-10-30.

What *is* visible to the user: macOS surfaces installed camera extensions in System Settings. OBS's own troubleshooting documentation instructs users to go to System Settings → Privacy & Security → Security (macOS 13 and 14) or **System Settings → General → Login Items & Extensions → Camera Extensions (macOS 15 and later)** to allow the extension ([OBS — Virtual Camera Troubleshooting](https://obsproject.com/kb/virtual-camera-troubleshooting), checked 2026-10-30). An admin must explicitly allow a camera extension before the system will use it, and only apps residing in `/Applications` can activate one — both per Apple's extension guide. These are meaningful friction, not a programmatic signal available to a sandboxed app.

Three practical heuristics remain, and each is defeatable:

1. **Enumerate and require a built-in or Continuity camera.** Discover devices and reject anything that is `.external` and not `isContinuityCamera`. Defeat: run the attack on a Mac mini / Mac Studio / Mac Pro with no built-in camera, where every legitimate camera is external — so this heuristic also *excludes legitimate desktop-Mac users*, a large false-reject population.
2. **Pin `uniqueID` across the session** and alarm on mid-interview device switches. Defeat: select the virtual camera before the session starts. This catches switching, not initial substitution.
3. **Shell out to `systemextensionsctl list` and look for known virtual-camera bundle IDs.** Defeat: (a) a blocklist of known IDs is trivially evaded by any unlisted or renamed extension; (b) it will not run from an App Sandbox; (c) it is a signature-based control in a space where new extensions are cheap to build — Apple ships an Xcode Camera Extension template that produces a fully functional virtual camera out of the box.

### 6.6 Does Apple expose any attestation of camera authenticity?

**No.** I found no Apple API that attests to the provenance or authenticity of a camera's frames.

What Apple does offer, and what it actually proves:

- **App Attest / `DCAppAttestService`** — available **macOS 11.0+** (so fine at the 15.6 floor). It lets you assert to your server the legitimacy of a particular instance of your app; the app needs a registered app ID. Apple frames the threat model as modified copies of your app sending valid-looking requests to your server. Sources: [Apple — DCAppAttestService](https://developer.apple.com/documentation/devicecheck/dcappattestservice), checked 2026-10-30; [Apple WWDC21 session 10244 — "Mitigate fraud with App Attest and DeviceCheck"](https://developer.apple.com/videos/play/wwdc2021/10244/) and [WWDC26 session 201](https://developer.apple.com/videos/play/wwdc2026/201/), checked 2026-10-30.
- **Managed Device Attestation** — iOS 16 / iPadOS 16.1 / **macOS 14** / tvOS 16 or later; MDM-based, giving strong evidence about device properties for trust evaluation rather than self-reported data. Source: [Apple — Managed Device Attestation for Apple devices](https://support.apple.com/en-gb/guide/deployment/dep28afbde6a/web), checked 2026-10-30.

App Attest proves *your unmodified app on a genuine Apple device sent this request*. It does not prove the camera the user selected is physical hardware. An unmodified, correctly-attested app reading a virtual camera produces a perfectly valid attestation over fraudulent pixels. Managed Device Attestation requires MDM enrolment of the candidate's personal machine, which is not available in an interview context.

### 6.7 The attack is real and documented

The MITRE ATLAS case study **AML.CS0033, "Live Deepfake Image Injection to Evade Mobile KYC Verification"**, documents an iProov red-team demonstration of face-swapped imagery injection that successfully evaded live face-recognition authentication together with **both passive and active liveness verification** on mobile devices. The published scenario uses widely available face-swap tools plus virtual-camera software to inject deepfake imagery into onboarding journeys, bypassing liveness checks in a test environment and completing verification under a false identity. Sources: MITRE ATLAS case study AML.CS0033 as summarised by [startupdefense.io](https://www.startupdefense.io/mitre-atlas-case-studies/aml-cs0033-live-deepfake-image-injection-to-evade-mobile-kyc-verification) and [SecurityBrief](https://securitybrief.co.uk/story/mitre-flags-deepfake-kyc-threat-using-face-swap-tools), both checked 2026-10-30 (secondary — I could not fetch the ATLAS page itself, see §12). The related case study **AML.CS0034** covers ProKYC, a tool that generates both fake identity documents and deepfake selfie videos to defeat facial recognition and liveness checks ([startupdefense.io](https://www.startupdefense.io/mitre-atlas-case-studies/aml-cs0034-prokyc-deepfake-tool-for-account-fraud-attacks), checked 2026-10-30, secondary).

Independent journalism corroborates the mechanism and its commoditisation: an MIT Technology Review investigation describes a Telegram marketplace selling ready-made tools to defeat the facial liveness checks used by banks, crypto exchanges and payment apps, and notes that rather than using a live phone camera feed, these hacks typically deploy a virtual camera, letting the user replace the video stream with other video or photos of a real or deepfake person ([MIT Technology Review, 15 April 2026](https://www.technologyreview.com/2026/04/15/1135898/cyberscammers-bypassing-bank-telegram/), checked 2026-10-30).

Vendor threat-intelligence figures exist and are directionally consistent, but come from a PAD vendor and should be cited as such if used at all: native virtual-camera attacks reported up 2,665% and face-swap attacks up 300% year over year ([iProov Threat Intelligence Report 2025 press release](https://www.iproov.com/press/annual-identity-verification-threat-intelligence-report/), checked 2026-10-30, **vendor source**).

### 6.8 What this means for the design

**Do not architect around virtual-camera detection; it cannot be made reliable, and the heuristics that exist carry a real false-reject cost on desktop Macs with no built-in camera.** Treat camera-source signals as weak risk inputs that feed a human-review flag, never as a pass/fail gate. The honest control set is: pin `uniqueID` for the session and flag mid-session device changes; record the device's name/type/transport in the audit trail as evidence for a human reviewer; prefer built-in or Continuity cameras where available without hard-requiring them; use App Attest for app-integrity assurance while stating plainly in the design doc that it says nothing about camera provenance.

---

## 7. India — Digital Personal Data Protection Act 2023 and the DPDP Rules 2025

### 7.1 Current status: the Rules ARE notified, with a phased commencement

The DPDP Act, 2023 (Act 22 of 2023) received Presidential assent and was published on **11 August 2023**. Draft Rules were published for consultation on **3 January 2025** (G.S.R. 02(E)).

**MeitY notified the final Digital Personal Data Protection Rules, 2025 on 13 November 2025, via G.S.R. 846(E).** The commencement provision is Rule 1 and it is explicit:

| Rules | In force |
| --- | --- |
| Rules 1, 2 and 17–21 | **On the date of publication — 13 November 2025** |
| Rule 4 (Consent Manager registration) | **One year after publication — 13 November 2026** |
| **Rules 3, 5–16, 22 and 23** | **Eighteen months after publication — 13 May 2027** |

Source: Digital Personal Data Protection Rules, 2025, G.S.R. 846(E), Ministry of Electronics and Information Technology, Gazette of India Extraordinary Part II §3(i), New Delhi, 13 November 2025 — [official PDF](https://du991dnb5pm56.cloudfront.net/documents/dpdpa/DPDP_Rules_2025_English_only.pdf), downloaded and text-extracted 2026-10-30 (primary — the gazette text itself).

The Act's own text: [DPDP Act 2023 gazette PDF, MeitY](https://www.meity.gov.in/static/uploads/2024/06/2bf1f0e9f04e6fb4f8fef35e82c42aa5.pdf), downloaded and text-extracted 2026-10-30 (primary).

**What this means for timing:** the substantive operating obligations for a product like this — notice (Rule 3), reasonable security safeguards (Rule 6), breach intimation (Rule 7), erasure timelines (Rule 8), DPO contact publication (Rule 9), children's verifiable consent (Rules 10–12), data-principal rights mechanisms (Rule 14), and cross-border transfer limits (Rule 15) — **all commence on 13 May 2027.** Three notifications accompanied the Rules establishing and constituting the Data Protection Board of India (G.S.R. 843(E) through 845(E)) ([Grant Thornton India summary](https://www.grantthornton.in/globalassets/1.-member-firms/india/assets/pdfs/flyers/dpdp-rules-nov-2025.pdf), checked 2026-10-30, secondary — used only for the G.S.R. numbering of the companion notifications).

### 7.2 There is NO sensitive or biometric category

**This is the single most important DPDP finding and it is verifiable by absence.** I searched the full extracted text of the DPDP Act, 2023 for "biometric" and for "sensitive": **zero occurrences of either word.**

The Act defines personal data uniformly: *"personal data" means any data about an individual who is identifiable by or in relation to such data* (§2(t)). There is no tiering, no special category, no heightened lawful-basis requirement for biometrics. A face template is personal data, full stop, governed by exactly the same consent and notice rules as an email address.

Source: DPDP Act 2023 §2(t), [MeitY gazette PDF](https://www.meity.gov.in/static/uploads/2024/06/2bf1f0e9f04e6fb4f8fef35e82c42aa5.pdf), text-extracted and searched 2026-10-30.

This is a sharp structural divergence from GDPR Article 9 (§8) and from Illinois BIPA (§9) — and it is the opposite of the usual assumption that India is the lighter jurisdiction *in every respect*. On penalties, India is heavier than BIPA per-incident.

### 7.3 Consent (Act §6) and notice (Rules, Rule 3)

**Consent (§6):** must be **free, specific, informed, unconditional and unambiguous, with a clear affirmative action**, signifying agreement to processing for the specified purpose, and **limited to such personal data as is necessary for that specified purpose**. The Act's own illustration makes the minimisation bite: a telemedicine app that asks for both service data and the phone contact list gets valid consent only for the service data, because the contact list is not necessary for the service.

Any part of consent that infringes the Act or any other law is **invalid to that extent** (§6(2)) — the illustration is a consent bundle that includes waiving the right to complain to the Board; the waiver is invalid.

Consent requests must be in **clear and plain language**, with the option to access the request in English or any language in the Eighth Schedule to the Constitution, and must give DPO (or authorised person) contact details (§6(3)).

**Withdrawal (§6(4)–(6)):** the data principal may withdraw at any time, **with the ease of withdrawal comparable to the ease with which consent was given.** Consequences of withdrawal are borne by the data principal, and withdrawal does not retroactively invalidate prior lawful processing. On withdrawal, the fiduciary must — within a reasonable time — cease processing and cause its processors to cease.

**Notice (Rule 3, in force 13 May 2027):** the notice must be presented and understandable **independently of any other information**; must give in clear and plain language a fair account sufficient for specific and informed consent, including **at minimum (i) an itemised description of the personal data and (ii) the specified purpose(s) plus a specific description of the goods/services or uses enabled**; and must give the communication link and a description of other means by which the principal can withdraw consent (with comparable ease), exercise rights, and complain to the Board.

Source: DPDP Act 2023 §6; DPDP Rules 2025 Rule 3 — both from the primary gazette texts cited in §7.1, read 2026-10-30.

### 7.4 Legitimate uses (§7) — and an important gap for *candidates*

§7 lists "legitimate uses" permitting processing without consent. §7(i) covers processing **"for the purposes of employment or those related to safeguarding the employer from loss or liability, such as prevention of corporate espionage, maintenance of confidentiality of trade secrets, intellectual property, classified information or provision of any service or benefit sought by a Data Principal who is an employee."**

**My reading, flagged as interpretation and not verified case law:** an interview candidate is not an employee, and the clause's examples are oriented to the employment relationship and to employees. Relying on §7(i) for candidate face verification is therefore a stretch. The safer construction is that **candidate verification requires consent under §6.** This should be put to a lawyer, not resolved in an architecture document (see §12).

### 7.5 Data-principal rights (Act §§11–14) — and the Article 22 gap

- **§11 — Right to access information about personal data.** On request, the principal may obtain a summary of the personal data being processed and the processing activities; the identities of all other data fiduciaries and processors with whom data has been shared, with a description of what was shared; and other prescribed information. Carve-out: the sharing-disclosure limb does not apply where data was shared with another fiduciary legally authorised to obtain it, pursuant to a written request for prevention/detection/investigation of offences or cyber incidents, or prosecution/punishment of offences.
- **§12 — Right to correction and erasure.** Rights to correction, completion, updating and erasure of personal data for which consent was given. On a correction/completion/updating request the fiduciary **shall** correct inaccurate or misleading data, complete incomplete data, and update data. On an **erasure** request the fiduciary **shall erase**, *unless* retention is necessary for the specified purpose or for compliance with any law in force.
- **§13 — Right of grievance redressal.**
- **§14 — Right to nominate.**

**There is no Article-22 equivalent.** I searched the full Act text and the full Rules text for "automated" and "profiling": "automated" appears only in the definitions (§2(b) defining "automated", and §2(x) defining "processing" as a wholly or partly automated operation); **"profiling" does not appear at all, and there is no right not to be subject to a solely automated decision, and no right to human intervention.**

Source: DPDP Act 2023 §§11–14 and §2; searched across the full extracted Act and Rules text, 2026-10-30.

Rule 14 (in force 13 May 2027) requires fiduciaries to publish the means by which principals exercise their rights.

### 7.6 Data-fiduciary security obligations (Rule 6) — a concrete checklist

Rule 6 requires, **at minimum**:

(a) appropriate data-security measures such as **encryption, obfuscation, masking, or virtual tokens mapped to the personal data**;
(b) appropriate access control over the computer resources used by the fiduciary or its processor;
(c) **visibility on access to personal data through appropriate logs, monitoring and review**, to enable detection, investigation and remediation of unauthorised access;
(d) reasonable measures for continued processing if confidentiality, integrity or availability is compromised — e.g. data backups;
(e) **retention of such logs and personal data for a period of one year** to enable detection, investigation, remediation and continued processing, unless another law requires otherwise;
(f) appropriate contractual provisions with the data processor requiring reasonable security safeguards;
(g) appropriate technical and organisational measures to ensure effective observance of safeguards.

Source: DPDP Rules 2025, Rule 6, primary gazette text, read 2026-10-30.

### 7.7 Breach notification (Rule 7) — two tracks, and a 72-hour clock

**To each affected data principal:** on becoming aware of any personal data breach, **without delay**, in a concise, clear and plain manner, via her user account or any registered mode of communication: (a) a description of the breach including nature, extent and timing; (b) the consequences likely to arise for *her*; (c) mitigation measures implemented and being implemented; (d) safety measures she may take to protect her interests; (e) business contact information of a person able to respond to her queries.

**To the Board:** (a) **without delay**, a description of the breach including nature, extent, timing, location and likely impact; and (b) **within seventy-two hours** of becoming aware (or a longer period the Board allows on written request): updated and detailed description; the broad facts, circumstances and reasons; mitigation measures implemented or proposed; any findings on who caused the breach; remedial measures to prevent recurrence; and a report on the intimations given to affected principals.

Note there is **no risk threshold** — the obligation attaches to "any personal data breach", unlike GDPR Article 33's risk-based filter.

Source: DPDP Rules 2025, Rule 7, primary gazette text, read 2026-10-30.

### 7.8 Retention and erasure (Rule 8) — the inconvenient minimum-retention rule

**Rule 8(1)–(2)** impose purpose-expiry erasure, but only on the classes in the **Third Schedule**: e-commerce entities with ≥2 crore registered users in India, online gaming intermediaries with ≥50 lakh registered users, and similarly-sized social-media intermediaries. For those classes, data must be erased when the principal neither returns for the specified purpose nor exercises rights for the scheduled period, and **at least 48 hours before erasure the fiduciary must warn the principal** that erasure is coming unless she logs in or initiates contact. A small interview product is not in the Third Schedule.

**Rule 8(3) is the one that bites, and it applies generally.** Its text: a data fiduciary **shall retain**, in respect of any processing undertaken by it or on its behalf by a processor, **such personal data, associated traffic data and other logs of the processing for a minimum period of one year from the date of such processing**, for the purposes specified in the **Seventh Schedule**, after which it shall cause them to be erased — unless further retention is required by any other law or notified by the Government. The Seventh Schedule (read with Rules 23(1) and 8(3)) enumerates State-access purposes, beginning with use by the State or its instrumentalities in the interest of the sovereignty and integrity of India or the security of the State.

The Rule's own illustrations apply it to ordinary commercial platforms: an e-book platform must retain order details, personal data and processing logs for at least a year from the transaction **even if the customer deletes her account**; and a company using a cloud processor must ensure the processor also retains data and associated logs for at least a year before erasure.

Source: DPDP Rules 2025, Rules 8(1)–(3), Third Schedule, Seventh Schedule — primary gazette text, read 2026-10-30.

**Tension to flag for legal review, not to resolve in the design:** Rule 8(3)'s general minimum-one-year retention of "personal data, associated traffic data and other logs" sits awkwardly against (a) §12(3)'s erasure-on-request right, (b) the privacy-by-design instinct to destroy the face template immediately after the match, and (c) BIPA/CUBI destruction duties (§9) if the product ever serves US users. §12(3) itself carves out retention "necessary for... compliance with any law for the time being in force", which is the likely reconciliation — but whether Rule 8(3) reaches a *biometric template* as opposed to the processing *logs* is a question for counsel (see §12).

### 7.9 Children's data (Act §9, Rules 10 and 12)

A **"child" is an individual who has not completed the age of eighteen years** (§2(f)) — notably higher than GDPR's 13–16 range and than COPPA's 13.

Rule 10 requires the fiduciary to adopt appropriate technical and organisational measures to obtain **verifiable parental consent** before processing a child's personal data; Rule 11 does the equivalent for persons with disability having a lawful guardian; Rule 12 provides exemptions for specified classes of fiduciary (Fourth Schedule Part A) and specified purposes (Part B). These commence 13 May 2027.

Source: DPDP Act 2023 §2(f), §9; DPDP Rules 2025 Rules 10–12 and Fourth Schedule — primary texts, read 2026-10-30.

**Relevance here:** interview candidates aged 17 are plausible in a campus-recruitment context. Verifiable parental consent for a face scan of a 17-year-old candidate is an operationally awkward requirement, and §9 breaches carry a penalty up to ₹200 crore.

### 7.10 Penalty structure (Act, the Schedule, read with §33(1))

| Breach | Maximum penalty |
| --- | --- |
| Failure to take reasonable security safeguards to prevent a personal data breach (§8(5)) | **up to ₹250 crore** |
| Failure to give the Board or affected data principals notice of a breach (§8(6)) | **up to ₹200 crore** |
| Breach of additional obligations in relation to children (§9) | **up to ₹200 crore** |
| Breach of additional obligations of a Significant Data Fiduciary (§10) | up to ₹150 crore |
| Breach of a data principal's duties (§15) | up to ₹10,000 |
| Breach of a voluntary undertaking accepted by the Board (§32) | up to the amount applicable to the underlying breach |

Source: DPDP Act 2023, The Schedule (see §33(1)) — primary gazette text, read 2026-10-30.

The two largest heads are **security safeguards** and **breach notification**, which is a clear signal about where regulatory risk concentrates: not in whether you collect the face, but in how you protect it and whether you report its loss.

### 7.11 Cross-border transfer (Rule 15) and research exemption (Rule 16)

Rule 15 restricts transfer of personal data processed by a data fiduciary outside India (commencing 13 May 2027); Rule 16 exempts processing for research, archiving or statistical purposes where carried on in accordance with the Second Schedule standards. Source: DPDP Rules 2025, Rules 15–16, primary text, read 2026-10-30. I did not extract the full Rule 15 conditions (see §12).

**Design relevance:** sending face images to Rekognition is a cross-border transfer unless the region is `ap-south-1`. Choosing Mumbai removes the question.

### 7.12 What this means for the design

DPDP imposes **consent-based processing with no biometric uplift, no automated-decision right, a 72-hour Board breach clock with no risk threshold, a general minimum-one-year log retention, an 18-year child threshold, and penalties up to ₹250 crore concentrated on security and breach-reporting failures.** The practical consequences: build a standalone, itemised, plain-language consent notice with equally easy withdrawal; keep the biometric in `ap-south-1` or on-device; encrypt or tokenise the template; keep access logs; and get legal advice on the Rule 8(3) / §12(3) retention-versus-erasure interaction rather than guessing.

---

## 8. GDPR — Article 9, Article 22, DPIAs, and European enforcement against proctoring

### 8.1 Article 9: biometric data for unique identification is special-category and prohibited by default

Article 9(1) prohibits processing of, among other categories, **"biometric data for the purpose of uniquely identifying a natural person."** The purpose qualifier matters: face *detection* without identification is not Article 9 data; face *matching against a reference photo to confirm who someone is* is squarely within it.

Article 9(2) lifts the prohibition only on ten enumerated grounds. The ones conceivably relevant here:

- **9(2)(a) explicit consent** — "the data subject has given explicit consent to the processing of those personal data for one or more specified purposes, except where Union or Member State law provide that the prohibition... may not be lifted by the data subject."
- **9(2)(b) employment/social-security obligations** — only "in so far as it is authorised by Union or Member State law or a collective agreement pursuant to Member State law providing for appropriate safeguards."
- **9(2)(f)** establishment, exercise or defence of legal claims.
- **9(2)(g)** substantial public interest, **on the basis of Union or Member State law** that is proportionate, respects the essence of the right, and provides suitable safeguards.

Article 9(4) permits Member States to **maintain or introduce further conditions, including limitations**, specifically on biometric data — so national law can be stricter than the Regulation.

Source: [Article 9 GDPR](https://gdpr-info.eu/art-9-gdpr/), checked 2026-10-30 (reproduction of the official text; the authoritative source is Regulation (EU) 2016/679 on EUR-Lex, which timed out on fetch — see §12).

**Practically, only 9(2)(a) explicit consent is available** to a private recruitment product: 9(2)(b) and 9(2)(g) both require an enabling Member State law that does not exist for interview identity checks, and 9(2)(f) is for litigation, not routine screening.

### 8.2 Why "explicit consent" is contested in a recruitment power imbalance — and now judicially tested

The general objection is that consent must be freely given, and a candidate who will not get the job without consenting is not freely choosing. **This is no longer only an argument: a German appellate court has decided it on these facts.**

Following a lawsuit brought by the Gesellschaft für Freiheitsrechte (GFF) together with a student and the independent association of student bodies against the University of Erfurt, the **Thuringian Higher Regional Court ruled in November 2025 that processing biometric data during proctoring is unlawful because it violates Article 9 GDPR.** The court's reasoning, as reported by the litigating organisation: biometric data may only be processed with consent; because **the students had no real alternative to online exams with proctoring software, they had not effectively consented**; and the court also did not accept that the "substantial public interest" ground was present. The software in question (Wiseflow) used AI including facial recognition and transmitted biometric data to Amazon Web Services. The Erfurt Regional Court had initially dismissed the claim in November 2024 on the basis that the plaintiff had suffered no damage, leaving the lawfulness question open; the appeal reversed that.

Source: [GFF — Monitoring of online examinations](https://freiheitsrechte.org/en/themen/freiheit-im-digitalen-zeitalter/proctoring), fetched 2026-10-30 (the litigating NGO — a party, so a partisan source on characterisation, but a direct report on the outcome of its own case; I could not locate the judgment text, see §12).

The same page records a second GFF action: an emergency application to the Higher Administrative Court of North Rhine-Westphalia against video recording of distance-learning exams at FernUniversität Hagen. The court **dismissed** the urgent application on 4 March 2021 on a balance-of-consequences basis, with its press release stating that the legality of the recording and storage could not be clarified in summary proceedings; it did not decide proportionality and expressed doubts about whether the deletion rules were specific enough.

**The "no real alternative" reasoning transfers directly to interviews.** A candidate who must pass the face check to be interviewed is in the same structural position as a student who must pass it to sit the exam.

### 8.3 Regulatory enforcement: the Italian Garante / Bocconi decision

In **September 2021 the Italian Data Protection Authority fined Università Luigi Bocconi €200,000** over its use of the Respondus remote proctoring software. The EDPB's own summary states the Italian SA found the university had **processed biometric data without a lawful legal basis pursuant to Article 9 GDPR**; the decision also covered insufficient information to students about the processing.

Sources: [EDPB — Italian SA finds monitoring system for online university exams to be in breach of privacy, fines university](https://www.edpb.europa.eu/news/national-news/2021/italian-sa-finds-monitoring-system-online-university-exams-be-breach_en) (EDPB, 2021 — the page rendered as a news index on fetch; the headline and the Article 9 finding are from the indexed summary, checked 2026-10-30) and [EDRi — No biometric surveillance for Italian students during exams](https://edri.org/our-work/no-biometric-surveillance-for-italian-students-during-exams/) (2021, NGO, secondary) which states the €200,000 figure and that the violations included processing biometric data without a legal basis and insufficiently informing students. One secondary industry source reports that subsequent court proceedings recorded the sanction as €150,000 ([constructor.tech](https://constructor.tech/research/how-run-exam-monitoring-italy-without-getting-fined), checked 2026-10-30) — **I could not verify the reduction from a primary source** (see §12).

For the adjacent biometric context, the Dutch SA fined **Clearview AI** for processing biometric data of data subjects in the Netherlands without a legal basis ([EDPB — Dutch Supervisory Authority imposes a fine on Clearview](https://www.edpb.europa.eu/news/national-news/2024/dutch-supervisory-authority-imposes-fine-clearview-because-illegal-data_en), 2024; [US Library of Congress Global Legal Monitor](https://www.loc.gov/item/global-legal-monitor/2024-10-16/netherlands-face-recognition-company-clearview-ai-fined-for-violating-eus-general-data-protection-regulation/), 2024), both checked 2026-10-30.

**The pattern across both the Italian regulator and the German court is consistent: biometric proctoring of people who have no real alternative has failed Article 9 twice, in two Member States, four years apart.**

### 8.4 Article 22: automated decision-making and the right to human intervention

Article 22(1): the data subject has the right not to be subject to a decision **based solely on automated processing**, including profiling, which produces **legal effects** concerning him or her **or similarly significantly affects** him or her.

Article 22(2) exceptions: (a) necessary for entering into or performing a contract between the data subject and the controller; (b) authorised by Union or Member State law with suitable safeguards; (c) based on the data subject's **explicit consent**.

Article 22(3): in the (a) and (c) cases the controller **shall implement suitable measures to safeguard the data subject's rights, freedoms and legitimate interests, at least the right to obtain human intervention on the part of the controller, to express his or her point of view, and to contest the decision.**

Article 22(4): decisions under 22(2) **shall not be based on special categories of Article 9(1) data unless Article 9(2)(a) or 9(2)(g) applies AND suitable safeguards are in place.**

Source: [Article 22 GDPR](https://gdpr-info.eu/art-22-gdpr/), checked 2026-10-30.

**Article 22(4) is the clause that constrains the architecture most tightly.** A face-match decision is a decision based on Article 9(1) special-category data. If it is also solely automated and significantly affects the candidate — automatically terminating an interview for identity failure plainly does — then it is permissible only on explicit consent (9(2)(a)) or substantial public interest (9(2)(g)), *and* with suitable safeguards, which under 22(3) include **at minimum human intervention, the ability to state one's view, and the ability to contest.** Losing a job opportunity to an automated identity rejection is a textbook "similarly significantly affects".

Reading Article 22(4) together with the Erfurt ruling: the one lawful basis Article 22(4) leaves open for a private product (explicit consent) is the very basis a European court has just found ineffective in a no-real-alternative setting. That is a genuine squeeze, and the design should treat the EU as a jurisdiction where this feature may simply not be deployable on an automated-decision basis.

### 8.5 DPIA requirements

A DPIA is mandatory under Article 35(3)(b) for **processing on a large scale of special categories of data** referred to in Article 9(1). Article 35(3)(a) covers systematic and extensive automated evaluation producing legal effects, and 35(3)(c) systematic monitoring of a publicly accessible area. Source: Article 35 GDPR; characterisation corroborated by [a published biometric-DPIA practitioner guide](https://github.com/ThomasMoreAI/legal-skills-open/blob/main/general/data-protection/skills/biometric-dpia/SKILL.md), checked 2026-10-30 (secondary — **I did not fetch Article 35's text from a primary source in this pass; see §12**). Whether candidate verification is "large scale" depends on volume, but combining Article 9 data with automated decisions affecting access to employment makes a DPIA the prudent default regardless.

### 8.6 EDPB guidance relevant to biometric identity checks

- **Guidelines 05/2022 on the use of facial recognition technology in the area of law enforcement** (adopted 12 May 2022). Law-enforcement-scoped, so not directly applicable, but its structure is the EDPB's clearest statement of how it analyses facial recognition: reliability/accuracy and risks to data subjects, processing of special-category data, automated individual decision-making including profiling, and data-subject rights and safeguards. Source: [EDPB Guidelines 05/2022](https://www.edpb.europa.eu/our-work-tools/our-documents/guidelines/guidelines-052022-use-facial-recognition-technology-area_en), checked 2026-10-30.
- **EDPB/EDPS Joint Opinion on the AI Act (June 2021)** called for a general ban on AI for automated recognition of human features in publicly accessible spaces — faces, gait, fingerprints, DNA, voice, keystrokes and other biometric or behavioural signals — in any context, and for a ban on AI using biometrics to categorise individuals by ethnicity, gender, political or sexual orientation, or other grounds on which discrimination is prohibited under Article 21 of the Charter. Source: [EDPB press release](https://www.edpb.europa.eu/news/news/2021/edpb-edps-call-ban-use-ai-automated-recognition-human-features-publicly-accessible_en), 2021, checked 2026-10-30. Not directly applicable (an interview is not a publicly accessible space) but it establishes the regulators' posture.
- **EDPB statement on facial recognition at airports (May 2024)** is the most transferable: the EDPB noted that facial recognition can lead to **false negatives, bias and discrimination**, that misuse of biometric data can cause identity fraud or impersonation, and urged operators to **choose less intrusive ways of achieving the goal where possible.** Source: [EDPB news, 24 May 2024](https://www.edpb.europa.eu/news/news/2024/facial-recognition-airports-individuals-should-have-maximum-control-over-biometric_en), checked 2026-10-30.

**I found no EDPB guidance addressing remote proctoring or recruitment identity checks specifically** (see §12). The "less intrusive alternative" and "false negatives, bias and discrimination" framings are the directly usable material.

### 8.7 What this means for the design

In the EU, the face match is **Article 9(1) special-category data whose only realistic lawful basis is explicit consent — a basis a German appellate court held ineffective in November 2025 precisely because the data subject had no real alternative — and Article 22(4) additionally forbids a solely-automated decision on Article 9 data without that same consent plus human intervention, the right to be heard, and the right to contest.** A mandatory DPIA applies. The architectural consequences are mandatory, not optional: a genuine non-biometric alternative path, a human decision-maker in the loop with authority to override, and a documented contest route. If the product cannot offer a real alternative, it should not run this feature for EU candidates.

---

## 9. US state biometric privacy law

### 9.1 Illinois BIPA (740 ILCS 14) — the statutory duties

BIPA has been in effect since **3 October 2008** and was amended by **Public Act 103-769, effective 2 August 2024**.

**§15(a) — retention and destruction, and the publicity requirement.** A private entity in possession of biometric identifiers or biometric information must **develop a written policy, made available to the public,** establishing a **retention schedule and guidelines for permanently destroying** biometric identifiers and information, with destruction occurring when the initial purpose for collection has been satisfied **or within 3 years of the individual's last interaction with the entity, whichever occurs first.** Absent a valid warrant or subpoena, the entity must comply with its own established retention schedule and destruction guidelines.

**§15(b) — informed written consent before collection.** A private entity may not collect, capture, purchase, receive through trade, or otherwise obtain biometric identifiers or information unless it first (1) **informs the subject in writing that a biometric identifier or information is being collected or stored**; (2) **informs the subject in writing of the specific purpose and the length of term** for which it is being collected, stored and used; and (3) **receives a written release** executed by the subject.

**§15(c) — no sale or profit.** A private entity in possession of biometric identifiers or information **may not sell, lease, trade, or otherwise profit from** a person's biometric identifier or biometric information.

**§15(d) — disclosure limits.** No disclosure, redisclosure or other dissemination unless the subject consents; or the disclosure completes a financial transaction requested or authorised by the subject; or it is required by state/federal law or municipal ordinance; or it is required pursuant to a valid warrant or subpoena.

**§15(e) — standard of care.** The entity must store, transmit and protect biometric identifiers and information using the reasonable standard of care within its industry, and in a manner **the same as or more protective than** how it stores other confidential and sensitive information.

Sources: [740 ILCS 14/15 (Illinois General Assembly)](https://ilga.gov/documents/legislation/ilcs/documents/074000140K15.htm) — **the ILGA site timed out and returned 403 on every fetch attempt from this network on 2026-10-30**, so the statutory text above is reconstructed from the ILGA page's indexed content plus multiple independent legal sources that quote it: [Quarles & Brady, quoting §15(a) verbatim](https://www.quarles.com/newsroom/publications/biometric-information-privacy-update-new-illinois-appellate-ruling-expands-temporal-recovery-period-and-suggests-enhanced-damage-remedy-available) (2021); [Justia — 740 ILCS 14](https://law.justia.com/codes/illinois/chapter-740/act-740-ilcs-14/) (2025 Illinois Compiled Statutes); [Holland & Knight](https://www.hklaw.com/en/insights/publications/2020/09/illinois-appellate-court-rules-that-workers-compensation-act) (2020). All checked 2026-10-30. **Flagged as not primary-verified (see §12) — counsel should read the statute directly.**

Two duties stand out as unusual engineering requirements: **the retention schedule must be *publicly available*** (not merely internal, not merely disclosed to the subject — a 2020 reform bill that would have changed "to the public" to "to the person" did not pass, confirming the public standard is the operative one: [HB 5374, 101st GA](https://my.ilga.gov/ftp/legislation/101/BillStatus/HTML/10100HB5374.html), checked 2026-10-30), and the **3-year-from-last-interaction outer limit** applies regardless of purpose.

### 9.2 Private right of action and statutory damages

BIPA §20 gives **"any person aggrieved"** a private right of action, with liquidated damages of **$1,000 per negligent violation** or **$5,000 per intentional or reckless violation** (or actual damages, whichever is greater), plus **reasonable attorneys' fees and costs** and other relief including injunctions.

Sources: [Holland & Knight](https://www.hklaw.com/en/insights/publications/2020/09/illinois-appellate-court-rules-that-workers-compensation-act) (2020) and [American Bar Association TIPS materials](https://www.americanbar.org/content/dam/aba/administrative/tips/programs/iclc-midyear2024/materials/thurs-ppts.pdf), both checked 2026-10-30.

**BIPA is the only US biometric statute with a private right of action and liquidated damages available without proof of actual loss** — which is why it, and not Texas or Washington, drives US litigation risk. An independent practitioner summary puts it well: what distinguishes BIPA is not the duties but the remedy ([EdLaw — BIPA](https://edlaw.eduverse.com/docs/jurisdiction/nat/us/state/il/bipa/README.md), checked 2026-10-30, secondary).

### 9.3 Per-scan vs per-person: Cothron, then SB 2979

**Cothron v. White Castle System, Inc., 2023 IL 128004 (Illinois Supreme Court, 17 February 2023), decided 4–3:** a BIPA claim under §§15(b) and 15(d) **accrues each time** biometric identifiers or information are collected or disseminated — not only on the first scan and first transmission. Sources: [Jenner & Block client alert](https://www.jenner.com/en/news-insights/publications/client-alert-illinois-supreme-court-rules-that-bipa-claims-accrue-with-scan-or-transmission-of-private-information) (2023); [Berkeley Law case summary PDF quoting the holding](https://www.law.berkeley.edu/wp-content/uploads/2025/03/04-Cothron-v-White-Castle-System-Inc.pdf); [Sidley](https://www.sidley.com/en/insights/newsupdates/2023/02/illinois-supreme-court-clarifies-accrual-for-illinois-biometric-privacy-act-claims) (2023). All checked 2026-10-30. The related Seventh Circuit procedural history is at [Cothron v. White Castle, 7th Cir. (23 August 2023)](https://media.ca7.uscourts.gov/cgi-bin/OpinionsWeb/processWebInputExternal.pl?Path=Y2023/D08-23/C:20-3202:J:Sykes:aut:T:fnOp:N:3093787:S:0&Submit=Display).

**Senate Bill 2979, signed by Governor Pritzker on 2 August 2024 and effective immediately (Public Act 103-769), changed exactly two things:**

1. **It eliminated per-scan damages.** The amendment adds language to §20 providing that a private entity that **more than once collects or discloses the same biometric identifier or biometric information from the same person by the same method of collection** in violation of BIPA has committed a **single violation, for which the aggrieved person is entitled to at most one recovery.** Practically: the limit applies to §15(b) (collection) and §15(d) (disclosure) claims.
2. **It redefined "written release" to include an electronic signature**, defined as an electronic sound, symbol or process attached to or logically associated with a record and executed or adopted by a person with intent to sign the record.

Sources: [Seyfarth Shaw — BIPA legislative update](https://www.seyfarth.com/news-insights/bipa-legislative-update-governor-pritzker-signs-amendment-limiting-damages-to-a-single-recovery-1.html) (2024); [Covington InsidePrivacy](https://www.insideprivacy.com/data-privacy/illinois-enacts-bipa-amendment-limiting-violation-accrual/) (2024); [SHRM](https://www.shrm.org/mena/topics-tools/employment-law-compliance/illinois-governor-signs-bipa-amendment-into-law) (2024); [Greenberg Traurig alert PDF](https://www.gtlaw.com/-/media/files/insights/alerts/2024/08/gt-alert_bipa-update-illinois-limits-liability-and-clarifies-electronic-consent-for-biometric-data-collection.pdf) (2024); [McGuireWoods](https://www.mcguirewoods.com/client-resources/alerts/2024/12/illinois-courts-consider-retroactivity-of-amendment-to-biometric-information-privacy-act/) (2024). All checked 2026-10-30, all law-firm secondary sources rather than the enrolled bill text (see §12).

**What SB 2979 did NOT change:** the per-violation damages amounts ($1,000 / $5,000) are untouched; the §15(a) public-retention-policy duty is untouched; the §15(c) no-profit ban is untouched; the private right of action and fee-shifting are untouched. **The amendment reduced the multiplier, not the duty.** A single non-compliant collection from a single candidate still supports a $1,000–$5,000 claim plus fees, and a class of candidates still multiplies by headcount.

**Retroactivity:** one secondary source reports that the Seventh Circuit held the 2024 damages amendment applies retroactively to pending cases (*Clay v. Union Pacific*) ([recordinglaw.com](https://www.recordinglaw.com/news/bipa-amendment-retroactive-clay-union-pacific-7th-circuit/), checked 2026-10-30). **I did not verify this from the opinion** (see §12). Illinois courts were split on retroactivity in late 2024 ([McGuireWoods](https://www.mcguirewoods.com/client-resources/alerts/2024/12/illinois-courts-consider-retroactivity-of-amendment-to-biometric-information-privacy-act/), 2024).

**Notable settlements/enforcement:** I did not verify specific settlement figures from primary court records in this pass (see §12). The structural point stands without them: BIPA's fee-shifting plus liquidated damages plus class aggregation is what generates the exposure, and that mechanism is unchanged.

### 9.4 Texas — Capture or Use of Biometric Identifier (CUBI), Tex. Bus. & Com. Code §503.001

Verified from the primary statute text, which I fetched in full. **Note it was amended effective 1 January 2026** by Acts 2025, 89th Leg., R.S., Ch. 1174 (H.B. 149) — the Texas AI act — adding AI-related definitions and exemptions.

- **"Biometric identifier"** means a retina or iris scan, fingerprint, voiceprint, or **record of hand or face geometry** (§503.001(a)(2)).
- **§503.001(b):** a person may not capture a biometric identifier **for a commercial purpose** unless the person (1) **informs the individual before capturing** it and (2) **receives the individual's consent** to capture it. Consent need not be written.
- **§503.001(b-1):** the mere existence of an image or media containing biometric identifiers on the internet or another publicly available source does **not** constitute informing or consent, unless the individual themselves made it publicly available.
- **§503.001(c)(1):** no sale, lease or other disclosure except: consent for identification in the event of disappearance or death; completing a financial transaction the individual requested or authorised; required or permitted by federal statute or a non-Public-Information-Act state statute; or to/by a law-enforcement agency for a law-enforcement purpose in response to a warrant.
- **§503.001(c)(2):** must store, transmit and protect from disclosure using **reasonable care**, in a manner **the same as or more protective than** how the person protects any other confidential information it possesses.
- **§503.001(c)(3):** must **destroy the biometric identifier within a reasonable time, but not later than the first anniversary of the date the purpose for collecting it expires** (subject to (c-1) for identifiers tied to documents another law requires be kept longer).
- **§503.001(c-2):** where an employer collected the identifier for security purposes, the collection purpose is **presumed to expire on termination of the employment relationship.**
- **§503.001(d):** civil penalty of **not more than $25,000 per violation**, enforceable only by the **Attorney General**. **No private right of action.**
- **§503.001(e), new in 2026:** exemptions now include (2) training/processing/storage of biometric identifiers involved in developing, training, evaluating, disseminating or offering AI models or systems — **unless a system is used or deployed for the purpose of uniquely identifying a specific individual**; and (3) development or deployment of an AI model or system for purposes including **preventing, detecting, protecting against, or responding to security incidents, identity theft, fraud, harassment, malicious or deceptive activities, or any other illegal activity**, preserving system integrity or security, and investigating/reporting/prosecuting those responsible.

Source: [Tex. Bus. & Com. Code ch. 503 (Texas Legislative Council)](https://tcss.legis.texas.gov/resources/BC/htm/BC.503.htm), fetched 2026-10-30 (primary statute text).

**The 2026 §503.001(e)(3) exemption is worth flagging to counsel:** verifying candidate identity to prevent proxy-candidate fraud arguably reads onto "detecting... fraud... or deceptive activities." But §503.001(e)(2) simultaneously *removes* the AI exemption where a system is deployed "for the purpose of uniquely identifying a specific individual" — which this system unambiguously is. The two subsections pull in opposite directions on these facts and I will not guess which prevails (see §12).

Also note the Texas AG publishes consumer-facing guidance restating the one-year destruction duty ([Texas Attorney General — Biometric Identifier Act](https://www.oag.state.tx.us/consumer-protection/file-consumer-complaint/consumer-privacy-rights/biometric-identifier-act), checked 2026-10-30).

### 9.5 Washington — RCW 19.375

Verified from the primary statute text, which I fetched. Washington's law is structurally different from Illinois and Texas in two ways that materially reduce its reach here.

**The definition of "biometric identifier" expressly excludes photographs and anything derived from them.** RCW 19.375.010(1): a biometric identifier is data generated by automatic measurements of an individual's biological characteristics — fingerprint, voiceprint, eye retinas, irises, or other unique biological patterns or characteristics — used to identify a specific individual; and it **"does not include a physical or digital photograph, video or audio recording or data generated therefrom"**, nor information collected/used/stored for HIPAA health-care treatment, payment or operations.

**The operative duty attaches only to "commercial purpose", which is narrowly defined and excludes security purposes.** RCW 19.375.010(4): "commercial purpose" means a purpose in furtherance of the sale or disclosure to a third party of a biometric identifier **for the purpose of marketing** goods or services unrelated to the initial transaction in which the person first gained possession of the identifier — and **"'commercial purpose' does not include a security or law enforcement purpose."** RCW 19.375.010(8) defines "security purpose" broadly, including purposes in furtherance of protecting the security or integrity of software, accounts, applications, online services, or any person.

**RCW 19.375.020(1):** a person may not **enroll** a biometric identifier in a database for a commercial purpose without first providing notice, obtaining consent, **or providing a mechanism to prevent subsequent use** for a commercial purpose. 19.375.020(2) states that notice is a disclosure — not itself affirmative consent — given through a procedure reasonably designed to be readily available, and that **the exact notice and type of consent required is context-dependent.** 19.375.020(3) restricts sale/lease/disclosure for a commercial purpose absent consent, with exceptions.

**"Enroll"** (19.375.010(5)) means to capture a biometric identifier, convert it into a **reference template that cannot be reconstructed into the original output image**, and store it in a database matching the identifier to a specific individual.

Enforcement is via the Washington Consumer Protection Act (RCW 19.375.030). "Person" excludes government agencies (19.375.010(7)).

Source: [Chapter 19.375 RCW (Washington State Legislature)](https://app.leg.wa.gov/RCW/default.aspx?cite=19.375&full=true), fetched 2026-10-30 (primary statute text).

**Net effect for this product:** a face template derived from a photograph or video frame is arguably outside Washington's definition entirely, and even if within it, identity verification to prevent candidate substitution is a "security purpose" and therefore not a "commercial purpose", so the enrollment duty in 19.375.020(1) would not attach. **Washington is a low-risk jurisdiction here. Illinois is the one that matters.**

### 9.6 Other states have added biometric provisions

Many state comprehensive privacy statutes now classify biometric data used to identify an individual as sensitive data requiring opt-in consent, and several impose data-protection-assessment duties. **I did not enumerate or verify these state by state in this pass (see §12).** The structural point for the design is that Illinois remains the outlier on remedy, and that the comprehensive-privacy-law trend means "biometric = sensitive, requires opt-in consent, requires an assessment" is becoming the baseline US expectation rather than an Illinois peculiarity.

### 9.7 What this means for the design

**The BIPA hard constraints are four concrete engineering requirements, not policy aspirations:** (1) a written notice stating that a biometric identifier is being collected, **the specific purpose, and the specific length of term** of collection/storage/use, plus a **written release** — electronic signature now explicitly acceptable — **obtained before any capture**; (2) a **publicly published** retention schedule and destruction guidelines, with destruction at purpose-satisfaction or 3 years from last interaction, whichever is first; (3) **never sell, lease, trade or otherwise profit from** the biometric, which also rules out using it to train or improve a model as a commercial benefit; (4) storage and transmission at least as protective as the system's other confidential data. The 2024 amendment caps repeat-collection exposure at one recovery per person per method but leaves $1,000/$5,000 per violation plus attorneys' fees intact. Texas adds a one-year-from-purpose-expiry destruction deadline and AG-only enforcement at up to $25,000 per violation; Washington's photograph exclusion and security-purpose carve-out likely place this product outside its scope.

---

## 10. NIST FRVT / FATE — demographic effects

### 10.1 NISTIR 8280 (December 2019) — still the authoritative headline study

**Scale of the study:** NIST processed **18.27 million images of 8.49 million people through 189 mostly commercial algorithms from 99 developers**, using four large operational US government datasets: domestic mugshots; application photographs from a global population of applicants for immigration benefits; visa photographs; and border-crossing photographs of travellers entering the US. The first three have good compliance with image-capture standards; the border-crossing set does not, given constraints on capture duration and environment. Metadata gave sex and age for all sets, race for the mugshots, and country of birth for the others (analysis restricted to 24 countries across 7 global regions).

**The central finding, stated in NIST's own terms:** contemporary face-recognition algorithms exhibit demographic differentials of various magnitudes. **False-positive differentials are much larger than false-negative ones and exist broadly, across many — but not all — algorithms tested. Across demographics, false-positive rates often vary by factors of 10 to beyond 100 times. False negatives tend to be more algorithm-specific and vary often by factors below 3.**

**False positives, in detail:**
- Using the higher-quality application photos, false-positive rates are **highest in West African, East African and East Asian people, and lowest in Eastern Europeans** — generally a large effect, with **a factor of 100 more false positives between countries.**
- **However, with a number of algorithms developed in China this effect is reversed, with low false-positive rates on East Asian faces.** (This is the clearest evidence that the differential is a property of training data, not of faces.)
- With domestic law-enforcement images, the highest false positives are in **American Indians**, with elevated rates in **African American and Asian** populations; the relative ordering depends on sex and varies by algorithm.
- **False positives are higher in women than men, consistently across algorithms and datasets — but this effect is smaller than the effect due to race.**
- **Elevated false positives in the elderly and in children**, larger at the extremes of age and smallest in middle-aged adults.

**False negatives, in detail:**
- With domestic mugshots, false negatives are higher in **Asian and American Indian** individuals, above those for white and African American faces (which give the lowest false-negative rates).
- With **lower-quality border-crossing images**, false negatives are generally higher in **people born in Africa and the Caribbean**, the effect being stronger in older individuals.
- NIST attributes the difference between these two results to **image quality**: the mugshots were collected with a photographic setup specifically standardised to produce high-quality images across races; the border-crossing images deviate from face-image-quality standards.
- In cooperative access-control applications, false negatives can be remedied by second attempts.

**On 1:N versus 1:1:** demographic differentials present in 1:1 verification algorithms are usually, but not always, present in 1:N search algorithms. One important exception: some developers supplied highly accurate identification algorithms for which **false-positive differentials were undetectable.**

**NIST's own implications section — three statements the design should adopt:**
1. Operational systems usually use a single algorithm, and given algorithm-specific variation, **it is incumbent on the system owner to know their algorithm.** Public test data helps, but NIST says it will usually be informative to **measure accuracy of the operational algorithm on the operational image data**, possibly with help from a biometrics testing laboratory.
2. Because different algorithms perform better or worse on different demographics, policy makers, developers and end users should be aware of these differences and use them in decisions.
3. **Reporting of demographic effects has often been incomplete in academic papers and media coverage** — in particular accuracy is discussed without stating whether the quantity of interest is false negatives, false positives, or failure to enrol. **Since most systems are configured with a fixed threshold, it is necessary to report BOTH false-negative and false-positive rates for each demographic group at that threshold. NIST says this is rarely done; most reports concern only false negatives.**

Source: Patrick Grother, Mei Ngan, Kayee Hanaoka, **NISTIR 8280, "Face Recognition Vendor Test (FRVT) Part 3: Demographic Effects"**, December 2019, [DOI 10.6028/NIST.IR.8280](https://doi.org/10.6028/NIST.IR.8280), PDF at [pages.nist.gov/frvt/reports/demographics/nistir_8280.pdf](https://pages.nist.gov/frvt/reports/demographics/nistir_8280.pdf) — downloaded and text-extracted 2026-10-30 (primary). NIST supplements the report with over 1,200 pages of per-algorithm charts across seventeen annexes.

### 10.2 The current NIST position (checked 2026-10-30)

NIST's evaluation programme was renamed: FRVT 1:1 is now **FRTE (Face Recognition Technology Evaluation) 1:1 Verification**, with FATE covering face *analysis*. The programme is live and large: **1,483 algorithms from 455 unique developers evaluated between 2017 and 2026**, with 120 algorithms from 101 developers in 2026 alone (participation statistics last updated **2026-10-06**).

**NIST has not published a replacement headline demographics report.** The current FRTE 1:1 report — dated **2026/10/06**, titled "NISTIR XXXX Draft" — instead handles demographics two ways:
1. It states that many of the hyperlinked **per-algorithm HTML report cards now include seven figures on demographic dependence**, that figures of this kind first appeared in and are documented by NISTIR 8280, and that they quantify **false-negative dependence using "visa-border" comparisons and false-positive dependence using comparisons of "application" photos** of uniform quality similar to visa photos.
2. It contains hundreds of pages headed "FALSE MATCH RATES WITHIN AND ACROSS DEMOGRAPHIC GROUPS" (report pages ~497–509+), plus accuracy for four demographic groups from the newer mugshot database — identified as **black females, black males, white females and white males** — in its Figure 807.

Sources: [NIST FRTE 1:1 Verification programme page](https://pages.nist.gov/frvt/html/frvt11.html) and the [FRTE 1:1 report PDF](https://pages.nist.gov/frvt/reports/11/frvt_11_report.pdf) (89 MB; downloaded and text-extracted 2026-10-30, report timestamp 2026/10/06). Per-algorithm demographic report cards are at e.g. [face.nist.gov/frte/reportcards/11/](https://face.nist.gov/frte/reportcards/11/aware_001.html), checked 2026-10-30.

**On whether the best modern algorithms have narrowed the gap — be precise, because this is easy to overstate in both directions.** What NIST actually says:

- In NISTIR 8280 itself: FRVT evaluation reports show a wide range in accuracy across developers, with the most accurate algorithms producing many fewer errors, and **"these algorithms can therefore be expected to have smaller demographic differentials."** Note the modal verb — NIST frames this as an expectation following from lower overall error, not as a measured claim that differentials have been eliminated.
- NISTIR 8280 also records a measured instance of elimination: some developers' highly accurate **1:N identification** algorithms had **undetectable false-positive differentials.**
- The current FRTE report cards state that for short time-lapses the most accurate algorithms produce very few errors (**FNMR < 0.001**), to the point that bootstrap uncertainty estimates become large — i.e. at the top of the field the demographic signal can be hard to resolve from noise ([face.nist.gov FRTE report card](https://face.nist.gov/frte/reportcards/11/aware_001.html), checked 2026-10-30).

**The honest summary:** NIST's position is that **overall error has fallen dramatically and differentials are smaller in the most accurate algorithms, but differentials remain algorithm-specific, remain measurable, and remain the system owner's responsibility to measure on their own algorithm and their own data.** NIST has not retracted NISTIR 8280 and has not published a finding that the differential is solved. Anyone claiming "modern algorithms fixed bias" is overstating; anyone quoting the 100× figure as the state of the art in 2026 without noting it was a 2019 measurement across 189 algorithms including poor ones is also overstating.

### 10.3 The vendor's own numbers for the model this project would actually use

NIST tests prototypes from commercial labs, not the specific open weights a student project would bundle. For the model actually in play, InsightFace publishes its own per-demographic figures (reproduced in §2.2). At **TAR @ FAR ≤ 1e-6** on the MFR all-to-all 1:1 protocol, `buffalo_l` scores:

| Group | TAR | Implied FNMR at FMR = 1e-6 |
| --- | --- | --- |
| Caucasian | 94.70 | 5.3% |
| **South Asian / Indian** | **93.16** | **6.8%** |
| African | 90.29 | 9.7% |
| **East Asian** | **74.96** | **25.0%** |
| MR-ALL | 91.25 | 8.8% |

Source: [insightface model_zoo.md](https://github.com/deepinsight/insightface/blob/master/python-package/docs/model_zoo.md) with metric definitions from [insightface MFR README](https://github.com/deepinsight/insightface/blob/master/challenges/mfr/README.md), both fetched 2026-10-30.

Two observations the design must not lose: the **spread between best and worst group is ~20 percentage points** in the vendor's own publication, and the **Indian figure — the primary jurisdiction's majority population — implies roughly 1 in 15 genuine candidates falsely rejected** at a strict threshold. That is a false-reject rate no interview product can automatically act on.

### 10.4 Gender Shades — the commercial-classifier context

**Buolamwini & Gebru, "Gender Shades: Intersectional Accuracy Disparities in Commercial Gender Classification", Proceedings of Machine Learning Research vol. 81 (FAT* 2018).** Three commercial gender-classification systems evaluated against a purpose-built dataset: **darker-skinned females were the most misclassified group, with error rates up to 34.7%; the maximum error rate for lighter-skinned males was 0.8%.** MIT's account adds the per-system detail: error rates for light-skinned men were never worse than 0.8%, while for darker-skinned women they exceeded 20% in one system and exceeded 34% in the other two. The thesis version reports that **37%–83% of classification errors came from the misclassification of darker females**, with lighter males contributing least to overall error.

Sources: [MIT Media Lab — Gender Shades publication page](https://www.media.mit.edu/publications/gender-shades-intersectional-accuracy-disparities-in-commercial-gender-classification) (2018); [paper PDF, PMLR v81](http://proceedings.mlr.press/v81/buolamwini18a/buolamwini18a.pdf); [MIT News](https://news.mit.edu/2018/study-finds-gender-skin-type-bias-artificial-intelligence-systems-0212) (12 February 2018); [Gender Shades full thesis](https://media.mit.edu/publications/full-gender-shades-thesis-17). All checked 2026-10-30.

**Scope caveat that must travel with these numbers:** Gender Shades measured **gender classification**, not face *verification*. It is the correct citation for "commercial face-analysis products shipped with severe intersectional disparities and the vendors did not know", and the wrong citation for a 1:1 match error rate. Conflating the two is the most common misuse of this paper. Its enduring contribution to this design is the **intersectional** method — a system can look fine on race-marginal and sex-marginal breakdowns and fail badly at an intersection.

The EDPB independently reached the same concern from the regulatory side, noting that facial recognition can lead to false negatives, bias and discrimination ([EDPB, 24 May 2024](https://www.edpb.europa.eu/news/news/2024/facial-recognition-airports-individuals-should-have-maximum-control-over-biometric_en)), and the German proctoring litigation record cites studies showing higher error rates for Black people and people of colour as a reason such software has a discriminatory effect ([GFF](https://freiheitsrechte.org/en/themen/freiheit-im-digitalen-zeitalter/proctoring), fetched 2026-10-30, NGO/party source).

### 10.5 What this means for the design

**These numbers are the technical justification for the three-outcome decision and the human override, and they should be cited explicitly in the design document rather than asserted.** The load-bearing facts: false-positive differentials across demographics reach factors of 10 to beyond 100 (NISTIR 8280, 189 algorithms); false-negative differentials are smaller, typically under 3×, and worsen sharply with poor image quality — which is exactly what a candidate's home webcam produces; the differential is a property of the specific algorithm and must be measured on the operational algorithm and operational data; and the candidate model's own vendor publishes a ~20-point spread with ~6.8% FNMR on Indian faces at FMR = 1e-6. A system with a single-digit percentage false-reject rate concentrated on specific demographic groups **cannot** be allowed to auto-reject a candidate. NIST's reporting point is also directly actionable: whatever the system logs, it must log **both** FMR-side and FNMR-side outcomes at the chosen threshold, because reporting only one is the documented failure mode.

---

## 11. FAR/FRR threshold practice

### 11.1 How operating points are properly expressed

The correct formulation, and NIST's own convention, is **FNMR at a stated FMR** — not "accuracy". NIST's FRTE 1:1 report states it explicitly: the tables show **false non-match rate (FNMR), the proportion of mated comparisons below a threshold set to achieve the specified false match rate (FMR); FMR is the proportion of impostor comparisons at or above that threshold.** NIST's primary ranking column is **FNMR @ FMR = 10⁻⁶** on the VISABORDER dataset. Source: [NIST FRTE 1:1 Verification](https://pages.nist.gov/frvt/html/frvt11.html), checked 2026-10-30.

Terminology discipline worth carrying into the design doc:
- **FMR / FNMR** — algorithm-level error rates at a threshold (ISO terms; what NIST reports).
- **FAR / FRR** — system-level rates, which include failure-to-acquire and failure-to-enrol events, not just comparison errors.
- **APCER / BPCER** — the PAD-subsystem equivalents (§5.1). A liveness threshold and a matching threshold are two separate policy choices with two separate error surfaces.

NIST also warns that at the top of the field the numbers get hard to resolve: for short time-lapses the most accurate algorithms give **FNMR < 0.001**, with correspondingly wide bootstrap uncertainty ([FRTE report card](https://face.nist.gov/frte/reportcards/11/aware_001.html), checked 2026-10-30).

For operational awareness, NIST's FRTE programme page also notes a forthcoming constraint on submissions: **starting 30 November 2026, template generation must complete in under 2,000 ms per image on a single core of an Intel Xeon Gold 6254 @ 3.10 GHz** — a useful external reference point for what "acceptable" single-image template latency means to NIST.

### 11.2 What AWS documents about Similarity thresholds

AWS is unusually explicit, and the guidance is worth quoting in substance because it is the clearest vendor statement that a threshold is a policy decision:

- **Default:** for `CompareFaces`, only faces at **similarity ≥ 80%** are returned unless `SimilarityThreshold` is set. Valid range 0–100.
- Responses with a `Similarity` below the threshold are **not returned at all**. AWS stresses this threshold is **important to calibrate for your use case, because it determines how many false positives are included** — it controls recall, and the lower the threshold the higher the recall.
- **"All machine learning systems are probabilistic. You should use your judgment in setting the right similarity threshold, depending on your use case."**
- Worked examples: for a photos app identifying similar-looking family members you might choose a **lower threshold such as 80%**; for **many law-enforcement use cases AWS recommends a high threshold of 99% or above to reduce accidental misidentification.**
- A two-stage pattern AWS explicitly endorses: use a low threshold (e.g. 80%) to return more results, then use the `Similarity` response attribute to filter in your application — again noting that **using a higher similarity such as 99% and above reduces the risk of misidentification.**
- Related parameter defaults for collections: `UserMatchThreshold` for `AssociateFaces` / `SearchUsers` defaults to **75**.
- For face attributes, AWS separately states that a **99% confidence threshold is recommended for sensitive use cases** ([AWS — Guidelines on face attributes](https://docs.aws.amazon.com/rekognition/latest/dg/guidance-face-attributes.html), checked 2026-10-30).
- AWS's engineering blog restates the 99% recommendation for use cases where highly accurate face-similarity matches matter, noting it matches their public documentation ([AWS ML Blog — Thoughts on Machine Learning Accuracy](https://aws.amazon.com/blogs/machine-learning/thoughts-on-machine-learning-accuracy), 2018).

Sources: [AWS — Using similarity thresholds for associating and matching faces](https://docs.aws.amazon.com/rekognition/latest/dg/thresholds-collections.html) and [AWS — CompareFaces API Reference](https://docs.aws.amazon.com/rekognition/latest/APIReference/API_CompareFaces.html), both checked 2026-10-30.

For Face Liveness thresholds, AWS gives the same answer and refuses to pick a number for you: customers **can set thresholds for both Face Liveness and face-match confidence; the chosen thresholds should reflect the use case**; the approve/deny decision is then sent based on the score being above or below those thresholds, and a denial should route the user to a retry or an alternative method. AWS adds that the choice between challenge modes should be made **after testing liveness performance with various confidence-score thresholds on the customer's own content**, weighing expected attack types and desired false-accept/false-reject rates. Source: [AWS — Detecting face liveness](https://docs.aws.amazon.com/rekognition/latest/dg/face-liveness.html), checked 2026-10-30.

Note carefully: **`Similarity` is an AWS-internal percentage, not an FMR.** AWS publishes no mapping from a Similarity value to a measured FMR/FNMR on any benchmark. "99% similarity" is not "FMR = 1%". Treat it as an ordinal dial whose error rates you must measure yourself.

### 11.3 What Apple documents about faceprint distances: nothing

Apple documents only that **shorter distances indicate greater similarity** between feature prints, for both the legacy `computeDistance(_:to:)` and the modern `distance(to:) throws -> Double`. There is no stated range, no scale, no units, no example threshold, no accuracy claim, and no guidance on calibration. There is also no documented stability guarantee across request revisions or OS releases (§1.5).

Sources: [Apple — VNFeaturePrintObservation.computeDistance(_:to:)](https://developer.apple.com/documentation/vision/vnfeatureprintobservation/computedistance(_:to:)) and [FeaturePrintObservation.distance(to:)](https://developer.apple.com/documentation/vision/featureprintobservation/distance(to:)), both checked 2026-10-30.

Compounding the problem: the returned `Double` is unbounded and not normalised, so a threshold has no portable meaning; Apple's documentation does not promise that byte-identical images yield distance zero, and developers report they do not ([Apple Developer Forums thread 721760](https://developer.apple.com/forums/thread/721760), checked 2026-10-30 — forum).

### 11.4 Thresholds used by comparable identity-verification products

I could not find a credible set of published operating points from named commercial identity-verification vendors; vendors generally do not publish their thresholds, and the figures that circulate are marketing claims rather than measured operating points (see §12). The verifiable anchors are:

| Anchor | Value | Source |
| --- | --- | --- |
| NIST FRTE 1:1 primary reporting point | **FNMR @ FMR = 10⁻⁶** | [NIST FRTE](https://pages.nist.gov/frvt/html/frvt11.html) |
| AWS `CompareFaces` default | Similarity ≥ **80** | [AWS API ref](https://docs.aws.amazon.com/rekognition/latest/APIReference/API_CompareFaces.html) |
| AWS recommendation, misidentification-sensitive use | Similarity ≥ **99** | [AWS thresholds guidance](https://docs.aws.amazon.com/rekognition/latest/dg/thresholds-collections.html) |
| AWS `UserMatchThreshold` default | **75** | [AWS thresholds guidance](https://docs.aws.amazon.com/rekognition/latest/dg/thresholds-collections.html) |
| NIST PAD convenience point | APCER @ **BPCER = 0.01** | [NIST IR 8491](https://doi.org/10.6028/NIST.IR.8491) |
| NIST PAD security point | BPCER @ **APCER = 0.01** | [NIST IR 8491](https://doi.org/10.6028/NIST.IR.8491) |
| InsightFace MFR benchmark point | TAR @ **FAR ≤ 10⁻⁶** | [InsightFace MFR](https://github.com/deepinsight/insightface/blob/master/challenges/mfr/README.md) |

### 11.5 A threshold is a policy choice, not a technical constant

Stated plainly, with each clause supported above:

1. **The threshold is a dial with two directions and no optimum.** NIST: the two error rates trade off against each other by changing a decision threshold — one goes up, the other goes down.
2. **The vendors say the choice is yours.** AWS: all ML systems are probabilistic, use your judgment depending on your use case; and for liveness, decide after testing on your own content.
3. **The right value depends on the relative cost of the two errors, which is a business and ethical judgement.** NIST frames it directly: BPCER is the inconvenience of a system, APCER its security; the convenience-focused point suits settings where high rejection of genuine users is intolerable and fraud costs are not punitive, and the security-focused point suits settings where rejecting genuine users is acceptable and fraud costs are large.
4. **The same threshold produces different error rates for different demographic groups.** NISTIR 8280's reporting recommendation exists precisely because most systems run a fixed threshold, which means both error rates must be reported per demographic group at that threshold.
5. **A published threshold is not portable between algorithms, or even between revisions of the same algorithm.** AWS Similarity, Apple feature-print distance, and a cosine similarity over SFace embeddings are three incomparable scales, and Apple's feature-print revisions are explicitly non-comparable across versions.

### 11.6 What this means for the design

Express the operating point as **FNMR at a chosen FMR, measured on representative data**, never as "accuracy", and record the threshold as a **configurable policy value with a written rationale and an owner** rather than a constant in the source. Because Apple publishes no distance scale and AWS's Similarity does not map to a published FMR, **the project must measure its own operating curve on its own candidate population** — which is also exactly what NISTIR 8280 tells system owners to do. Budget for that measurement in the plan; a threshold chosen without it is a guess wearing a number.

---

## 12. Unverified / could not confirm

Everything below is something the design document must NOT assert as established. Each entry says what I could not confirm and why.

### Apple / client platform

1. **Whether Apple has any private or unpublished face-recognition API.** I verified the *public* Vision surface exhaustively and `VNGenerateFaceprintRequest` / `VNFaceprint` are not in it. I did not and will not probe private symbols; private API is unusable in a shipping product regardless.
2. **Whether Apple anywhere states a position on using Vision for identity verification.** I found no such statement in either direction. I searched the framework documentation and the relevant WWDC session pages. Absence of a statement is not the same as having searched every Apple document.
3. **`VNFaceObservation.pitch` population across requests and revisions on macOS 15.6 / 26 / 27.** Apple documents the property; community reports say it is `nil` for some request/revision combinations. **Needs an empirical check on each target OS.**
4. **Whether a specific virtual camera (OBS Virtual Camera, Camo, Snap Camera) actually reports a distinguishable `transportType`, `modelID`, or `manufacturer` in practice.** No virtual camera is installed on this machine; I measured only the built-in FaceTime HD Camera (`'bltn'`, `"Apple Inc."`, `"FaceTime HD Camera"`). The architectural conclusion in §6 does not depend on this — it rests on Apple's documentation that `CMIOExtensionDeviceProperties.transportType` and `.model` are writable — but **the specific values current tools happen to report are untested.**
5. **Whether `systemextensionsctl list` works from an App-Sandboxed or hardened-runtime app, and what it returns for current virtual cameras.** Not tested.
6. **Whether the "Camera Extensions" pane still exists in System Settings on macOS 26/27.** An OBS forum thread claims the section no longer exists in Tahoe ([obsproject forum](https://obsproject.com/forum/threads/virtual-camera-mac-os-tahoe-26-3-1.194658/), 2026). **Unverified user report, not Apple documentation.** Several 2026 OBS reports also describe the virtual camera failing outright on macOS 26.7 and on MDM-managed machines — if accurate this is attacker friction, but it is not a control to rely on and it is not verified.
7. **Measured inference latency for any face-embedding model on Apple Silicon.** I found no authoritative current primary-source benchmark and did not run one. **Must be measured on target hardware.**
8. **Which ops of a specific chosen recognition model are supported by the ONNX Runtime Core ML EP.** The supported-operator lists are published per model format; I did not check any particular model against them. Unsupported ops fall back to CPU silently.
9. **The MITRE ATLAS case-study pages themselves** (AML.CS0033, AML.CS0034). `atlas.mitre.org/studies/AML.CS0033` returned HTTP 404 on fetch. The content in §6.7 comes from secondary summaries of the ATLAS entries. **Verify against the ATLAS site before citing in the design document.**

### Models and licensing

10. **The current terms of the VGGFace2 and CASIA-WebFace datasets**, on which the MIT-licensed FaceNet checkpoints were trained. Code licence ≠ weights licence ≠ training-data licence; this chain is unchecked for FaceNet.
11. **What benchmark produced SFace's 0.9940 figure.** The OpenCV Zoo README reports it from the repo's own `tools/eval` harness without naming the dataset in the text I read. Do not cite it as an LFW number.
12. **Whether InsightFace's commercial licence for `buffalo_l` is obtainable, and at what price.** InsightFace directs enquiries to `recognition-oss-pack@insightface.ai`; terms are not published.
13. **The licence of the Silent-Face-Anti-Spoofing model** that DeepFace optionally uses for liveness, and of each other DeepFace backend. DeepFace's README says licences are inherited and must be checked per model; I checked DeepFace's own licence and InsightFace's, not the rest.
14. **antelopev2's per-demographic accuracy.** The InsightFace model-zoo table lists the package but leaves its accuracy row empty.

### Cloud services

15. **Whether Azure Face approval is actually obtainable for a university project.** Microsoft's stated criterion excludes customers not working directly with Microsoft account teams, and access is at Microsoft's sole discretion. **I verified the criterion, not an outcome.** No one has been told "no" on this record.
16. **Whether any AWS-supported route exists for Face Liveness in a native macOS app.** I verified the Amplify SDK is required and that the documented components are React/Swift(iOS)/Android. **I did not find an AWS statement that macOS is unsupported — the absence of macOS from the supported list is the evidence.** Worth a direct question to AWS before finalising.
17. **Whether the Amplify React Liveness component functions correctly inside a `WKWebView` on macOS**, including camera permission flow and the documented inability of the web SDK to adjust screen brightness. Untested.
18. **The exact set of Rekognition image APIs covered by the "Rekognition Image API Requests" price group.** The Price List API groups them; I did not confirm line-by-line that `CompareFaces` bills under that group rather than another. The $0.00125/image Mumbai figure is from the authoritative offer file, but the mapping of `CompareFaces` to that group is inference from the group name and the public pricing page.
19. **Whether Rekognition's image APIs have an India-specific data-residency commitment beyond regional endpoint availability.** Not investigated.

### India / DPDP

20. **Whether DPDP Rule 8(3)'s minimum-one-year retention of "personal data, associated traffic data and other logs" reaches a biometric template**, as opposed to only the processing logs — and how it reconciles with §12(3)'s erasure-on-request right and with BIPA/CUBI destruction duties. **This is the sharpest open legal question in the memo. Needs Indian counsel.**
21. **Whether §7(i)'s employment legitimate use covers interview candidates.** My reading is that it does not, because a candidate is not an employee. **This is my interpretation, not verified against any guidance or decision.**
22. **The full conditions of Rule 15 (cross-border transfer).** I confirmed the rule exists and commences 13 May 2027 but did not extract its conditions.
23. **Whether this product would be designated a Significant Data Fiduciary** under Act §10 / Rule 13, which carries additional obligations and a penalty head up to ₹150 crore. Depends on criteria and scale not assessed here.
24. **Whether any DPDP guidance, FAQ or Board practice note addresses biometric or facial processing.** The Board is newly constituted; I found no such guidance, which is unsurprising given the 13 May 2027 commencement of the substantive rules.

### EU / GDPR

25. **The primary text of GDPR Articles 9 and 22 from EUR-Lex.** The EUR-Lex consolidated-text fetch timed out. The Article 9 and 22 text in §8 is from [gdpr-info.eu](https://gdpr-info.eu), a faithful reproduction but **not the official source.** Verify against Regulation (EU) 2016/679 on EUR-Lex before relying on exact wording.
26. **The text of GDPR Article 35 (DPIA).** I did not fetch it from a primary source in this pass; §8.5 relies on a practitioner summary for the Article 35(3)(b) characterisation. **Verify the trigger wording.**
27. **The Thuringian Higher Regional Court judgment itself** (November 2025, University of Erfurt / Wiseflow). The account in §8.2 comes from GFF, the litigating NGO — a party to the case. I could not locate the judgment text, the case number, or a neutral report. **The reasoning is highly relevant and should be verified from the judgment or a neutral law report before being relied on.**
28. **Whether the Bocconi fine was reduced from €200,000 to €150,000 on appeal.** One industry source says yes; I could not verify from the Garante or a court record.
29. **The Garante's Bocconi decision text (provvedimento).** I have the EDPB summary and NGO reporting; not the decision.
30. **Whether any EDPB guidance addresses remote proctoring or recruitment identity verification specifically.** I found none. The airports statement and the law-enforcement FRT guidelines are the closest analogues.
31. **The Dutch DPA's Uber decision on unlawful automated decision-making** (listed on the EDPB national-news index, 8 October 2026, reported as EUR 824,990,000). Potentially significant for Article 22 practice but **entirely unverified** — I saw only an index entry.

### US states

32. **The primary text of BIPA 740 ILCS 14.** The Illinois General Assembly site returned timeouts and HTTP 403 on every attempt from this network. §9.1 and §9.2 are reconstructed from the ILGA page's indexed content plus multiple independent legal sources quoting the statute. **Counsel must read 740 ILCS 14/10, /15 and /20 directly.** This is the weakest sourcing in the memo on a point with the highest litigation exposure.
33. **The enrolled text of SB 2979 / Public Act 103-769.** §9.3's description of what the amendment changed is from five independent law-firm and practitioner analyses, which agree with each other, but not from the bill text.
34. **Whether the 2024 BIPA amendment applies retroactively to pending cases.** One secondary source reports a Seventh Circuit holding to that effect in *Clay v. Union Pacific*; I did not read the opinion, and Illinois courts were split in late 2024.
35. **Specific BIPA settlement amounts and enforcement outcomes.** Not verified from court records in this pass.
36. **Whether Texas CUBI §503.001(e)(3)'s new security/fraud-detection AI exemption or §503.001(e)(2)'s unique-identification carve-back controls on these facts.** The two subsections, both effective 1 January 2026, pull in opposite directions for a system deployed to uniquely identify an individual *in order to* detect fraud. **Needs Texas counsel.**
37. **Which other states' comprehensive privacy laws classify biometric identifiers as sensitive data, and what each requires.** Not enumerated. The trend is real; the specifics are unverified.
38. **Whether a face template derived from a video frame falls outside Washington's "biometric identifier" definition.** My reading of RCW 19.375.010(1)'s exclusion of photographs, video and "data generated therefrom" suggests yes, and the "security purpose" carve-out from "commercial purpose" suggests the duty would not attach regardless. **Both are my readings of the statutory text, not verified against Washington guidance or case law.**

### Metrics

39. **Any credible published operating point (threshold + measured FMR/FNMR) from a named commercial identity-verification vendor.** Not found. Vendors do not publish thresholds.
40. **Whether NIST has published any demographics report superseding NISTIR 8280.** I found none, and the current FRTE 1:1 report (2026-10-06) still cross-references NISTIR 8280 for the methodology behind its demographic report-card figures — which is strong evidence there is no successor headline report, but I did not exhaustively search NIST's publication database.
41. **Current status of the NIST FATE PAD track.** The FRTE status page states that except PAD, all FRTE tracks are open, which reads as the PAD track being closed to new submissions as of 2026-10-06. I did not confirm whether NIST IR 8491 has been revised since September 2023.

---

## Source-quality note

**Primary sources used directly** (fetched, downloaded, or text-extracted on 2026-10-30): Apple developer documentation (via the documentation data endpoint, which returns the same content as the rendered pages including platform-availability metadata and declarations); the macOS SDK headers on this machine; a Swift `AVCaptureDevice.DiscoverySession` probe run locally; AWS documentation and the AWS Price List offer file for `ap-south-1`; Microsoft's legal/Limited Access documentation; the DPDP Act 2023 and DPDP Rules 2025 gazette PDFs; NISTIR 8280 and NIST IR 8491 PDFs; the NIST FRTE 1:1 report PDF and programme page; the ISO catalogue entry for ISO/IEC 30107-3:2023; the Texas Business and Commerce Code chapter 503 text; Chapter 19.375 RCW; EDPB publication pages; and the InsightFace, DeepFace, OpenCV Zoo and FaceNet repository files.

**Known secondary or partisan sources, flagged inline:** law-firm client alerts for the BIPA amendment and Cothron; the GFF page for the Erfurt judgment (the litigating NGO); EDRi for the Bocconi fine amount; iProov for threat-intelligence percentages (a PAD vendor); startupdefense.io for the MITRE ATLAS case-study content; MIT Technology Review for the Telegram marketplace; Apple Developer Forums threads for feature-print behaviour (forum posts, some from Apple engineers, none formal documentation); Stack Overflow for cross-OS-version feature-print behaviour.

Content from sources was rephrased for compliance with licensing restrictions.
