# Non-private real-camera document fixtures

These files are public, non-private fixtures used only to validate document geometry decisions. They are not user documents.

- `nislive-perspective.jpeg`
  - upstream: `Nislive/document-scanner`, `input-1.jpeg`
  - source: https://github.com/Nislive/document-scanner
  - license: MIT; see `LICENSE-Nislive-MIT.txt`
  - role: genuine smartphone-style perspective document photo.
- `pcaswathiii-perspective.jpg`
  - upstream: `pcaswathiii/document-scanner-ocr`, `sample_test_image.jpg`
  - source: https://github.com/pcaswathiii/document-scanner-ocr
  - license: MIT; see `LICENSE-pcaswathiii-MIT.txt`
  - role: second genuine perspective document photo from an independent public scanner sample.
- `pcaswathiii-near-full-frame-reference.jpg`
  - upstream: `pcaswathiii/document-scanner-ocr`, `sample_corrected_output.jpg`
  - source: https://github.com/pcaswathiii/document-scanner-ocr
  - license: MIT; see `LICENSE-pcaswathiii-MIT.txt`
  - role: camera-derived, already-corrected/near-full-frame reference. It is intentionally paired with the raw perspective sample to assert that production does not blindly re-warp an already flattened page.

- `joellijo32-fronto-parallel-source.jpg`
  - upstream: `joellijo32/Document-Scanner-using-OpenCV`, `assets/3.jpg`
  - source: https://github.com/joellijo32/Document-Scanner-using-OpenCV
  - license: MIT; see `LICENSE-joellijo32-MIT.txt`
  - role: public non-private real-camera source for the near-full derivative below.
- `joellijo32-near-full-camera-derived.jpg`
  - derived only by a rectangular bounding-box crop plus 2.5% margin from `joellijo32-fronto-parallel-source.jpg`; no perspective correction, thresholding, OCR redraw, or synthetic document pixels are applied.
  - source SHA-256: `b896dfe5cf08672292f3c6e384dbeeed11d7243caa90617c651e4ac5b526f1b5`
  - fixture SHA-256: `a375c51c1d91b08bdf5f3d9ef384ee92ee1ed96fa6582975ffad165f6667ffbc`
  - role: high-confidence camera-derived near-full input. On the current macOS Vision stack it is detected with confidence≈0.99, area≈0.869, max-corner-inset≈0.056 and opposite-edge-delta≈0.031; production must preserve it rather than re-warp it.

The pcaswathiii near-full reference is not claimed to be a raw camera frame. The joellijo32 derivative keeps real-camera pixels and removes only surrounding frame area, so it supplies a high-confidence near-full decision case without private material. The deterministic synthetic edge fixture separately retains the exact colored-edge regression that originally reproduced `AUD-007`.
