# PoleLink

Native iPhone field-capture prototype for one pole and many street lights. Requires iOS 17+. Written in SwiftUI, AVFoundation, Vision and SwiftData, with no third-party app dependencies. Includes a Python/SQLite mock REST service in place of SAP.

## Open and run

1. Open `PoleLink.xcodeproj` in Xcode.
2. Select the **PoleLink** scheme. For an iPhone, choose your signing team under Signing & Capabilities and change `com.example.PoleLink` to an available bundle identifier.
3. Run on an iPhone or iPhone simulator. Demo mode is enabled initially. Disable it in Settings for the real camera.
4. Start the API from this directory:

   ```sh
   python3 mock-api/server.py
   ```

   For an iPhone on the same trusted Wi-Fi network, bind the mock server to the LAN:

   ```sh
   python3 mock-api/server.py --host 0.0.0.0
   ```

5. In app Settings, use `http://localhost:8080` for the simulator or your Mac’s LAN IP, such as `http://192.168.1.20:8080`, for a physical iPhone. Allow local-network access when prompted. The mock has no authentication and is intended for trusted development networks only.

## Demonstrate the workflow

1. Leave Demo mode on. Start a pole survey and tap **Scan pole label**.
2. Tap **High confidence**. The value turns green, simulated evidence is created, and the saved pole appears in the review screen.
3. Add a light using **High confidence**.
4. Add another using **Low confidence**. Correct or confirm the serial, then tap **Confirm & capture photo**. No photo is saved before that confirmation.
5. Review the pole, both associated lights, their verification status, and photos. Tap each row to see its evidence. Draft light rows support swipe-to-remove; the pole can be recaptured.
6. Stop the mock server (or enable Airplane Mode) and tap **Confirm & submit survey**. The survey remains queued locally. Close and reopen the app to check persistence.
7. Restart the server/restore connectivity. While the app is open, sync retries on connectivity changes, app activation, and every 30 seconds. **Sync now** retries immediately. The survey changes to Synced after a matching server receipt.
8. View the received evidence and association data:

   ```sh
   curl http://localhost:8080/api/v1/associations
   ```

Demo records and all their photos are explicitly marked as simulated. Demo mode is fixed per survey, so real and demo evidence cannot be mixed. API tests exercise the REST transport and database independently; they do not substitute for device testing.

## Real capture

- **Pole ID:** Vision OCR runs on-device in the central region. The highest candidate is displayed live with its OCR score. Automatic capture requires a single valid candidate, a score of at least 0.90, and three consistent readings. Multiple candidate labels force manual review. Three consistent readings below the threshold open the verification form.
- **Street light:** Vision decodes QR payloads. Supported formats are a plain serial (`SL-100001`) or JSON (`{"serialNumber":"SL-100001"}`). Automatic capture requires three matching valid decodes. The displayed QR percentage is a **read-consistency score**, not a probability that the serial is correct.
- **Manual entry:** Available even if nothing is readable. The technician confirms the value before the camera takes the evidence photo. Original reading, score, verification method and final value are retained.
- **Photos:** Taken through `AVCapturePhotoOutput`, normalised to a maximum dimension of 1,600 pixels, JPEG-compressed, and stored with the survey. This is suitable for a demo; validate evidence resolution against field requirements.
- **Identifier policy:** Currently 3–64 ASCII letters/digits/dots/hyphens/underscores, beginning with a letter or digit. Change `CaptureRules` and mock validation together once actual label examples and QR specifications are available. The 90% threshold requires calibration on representative field labels.

Apple documents OCR scores as normalised confidence values: [VNRecognizedText.confidence](https://developer.apple.com/documentation/vision/vnrecognizedtext/confidence). QR parsing uses [VNBarcodeObservation](https://developer.apple.com/documentation/vision/vnbarcodeobservation).

## Storage and synchronisation

A SwiftData database in the app sandbox stores each survey, its JSON payload including JPEG data, timestamps, submission state and last sync error. Each capture is persisted before the scanner dismisses. Relationships are contained in the survey: one pole, an array of lights, unique UUIDs for every capture. Duplicate light serials within the same survey are rejected case-insensitively.

State transitions: **draft → queued → synced**. Drafts are editable and excluded from upload. Submitted payloads are immutable. A UUID idempotency key permits retrying the exact payload after timeouts or interrupted acknowledgements without creating duplicates. Conflicting payloads for the same UUID return HTTP 409. Failed uploads retain their queue state and evidence. The mock database persists across server restarts.

Sync is automatic **while the app is active**, and resumes when reopened. iOS suspension means this prototype does not guarantee immediate background synchronisation. Production background delivery needs background URLSession file uploads and OS-scheduled work, tested on devices. No server runs on the iPhone: the server-side REST API exposes uploaded data to external clients, including a future SAP adapter. Offline data becomes externally visible after sync.

## API contract

| Method | Path | Behaviour |
| --- | --- | --- |
| GET | `/health` | Mock service health |
| POST | `/api/v1/associations` | Validate and persist a complete survey |
| GET | `/api/v1/associations` | List submitted surveys, including photos |
| GET | `/api/v1/associations/{id}` | Retrieve one survey |

POST uses `Content-Type: application/json` and `Idempotency-Key: <survey UUID>`. Request structure is described by `mock-api/openapi.json`. Dates are ISO 8601, UUIDs are strings, and JPEG photos use base64. Limit: 40 MiB per JSON request. Large surveys should be split; the app checks the request size before queuing.

Successful response:

```json
{"id":"<survey UUID>","accepted":true,"destination":"mock-sap","duplicate":false}
```

Responses: 201 for a new record; 200 for an identical retry; 400 for invalid data; 404 for unknown paths/records; 409 for a changed payload with an existing ID; 413 for oversized requests; 503 for database unavailability. External applications can pull submitted records using GET. No actual SAP write or SAP-specific field mapping is claimed.

## Verification

```sh
python3 -m unittest discover -s tests -v
xcodebuild -project PoleLink.xcodeproj -scheme PoleLink \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

Verified here:

- Seven HTTP/SQLite integration tests pass: association round trip, identical retries, conflicts, duplicate serials, photo requirements, confidence/manual verification, required lights and idempotency header, persistence across server creation.
- All Swift sources type-check against the iOS 26.5 SDK with an iOS 17 deployment target.
- Xcode project and Info.plist syntax validate.

Not verified here: app launch, UI layout on a device/simulator, physical-camera accuracy, camera permission recovery, real offline-to-online app sync. This machine’s Xcode installation lacks `/Library/Developer/PrivateFrameworks/CoreSimulator.framework`, so `xcodebuild` and simulator launch fail before compiling the target. Complete Xcode first-launch component installation (the runner suggests `xcodebuild -runFirstLaunch`), then build and run the demonstration above.

## Production decisions still needed

This is a functional prototype, not a production deployment. Confirm real Pole ID formats, QR payload formats, device photo requirements, cross-survey serial uniqueness and correction rules. Before deployment, add identity/access controls, HTTPS-only transport, secure API credentials, an SAP-specific adapter, background upload support, schema migration/retention policies, and field/device tests. The current Info.plist permits HTTP to enable the LAN mock; remove that exception for production. The mock validates JPEG envelope bytes but is not a hardened image ingestion service.

## Files

- `PoleLink/Models.swift`: capture schema, SwiftData survey model, identifier policy.
- `PoleLink/Camera.swift`: camera session, Vision recognition, still capture.
- `PoleLink/ScannerView.swift`: live status, verification, capture and demo path.
- `PoleLink/PoleLinkApp.swift`: home, survey review, settings.
- `PoleLink/SyncService.swift`: connectivity monitoring, persistent queue delivery.
- `mock-api/server.py`: REST endpoint and SQLite persistence.
- `mock-api/openapi.json`: integration contract.
- `tests/test_api.py`: HTTP integration tests.
