Synthetic test voices, generated with the Kokoro-82M text-to-speech model (Apache-2.0): two voices
(`bm_george`, `am_michael`), three sentences each, 16 kHz mono. No real person's voice is in this folder.

`reference-embeddings.json` holds the embeddings a Python reference implementation (NumPy filterbank +
ONNX Runtime) produced for the same files with `voxceleb_ECAPA512_LM.onnx`. The Swift implementation must
match them.
