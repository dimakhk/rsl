"""Writes RSLTests/reference.json: what the S3D model answers to two made-up
inputs, computed with ONNX Runtime on a PC. The tests of the iOS app feed the
same inputs to the model inside the app and expect the same answers - which
checks the model file, the runtime and the order the numbers are fed in.

    python tools/reference.py path/to/s3d_2d.onnx
"""
import json, os, sys
import numpy as np
import onnxruntime as ort

T, C, S = 32, 3, 224

def waves():
    t, c, y, x = np.meshgrid(np.arange(T), np.arange(C), np.arange(S), np.arange(S), indexing="ij")
    return (0.5 + 0.5 * np.sin(0.05 * x + 0.07 * y + 0.3 * t + c)).astype(np.float32)

def noise():
    i = np.arange(T * C * S * S, dtype=np.uint64)
    return (((i * np.uint64(2654435761)) % np.uint64(1000)).astype(np.float32) / np.float32(1000)).reshape(T, C, S, S)

session = ort.InferenceSession(sys.argv[1], providers=["CPUExecutionProvider"])
out = {}
for name, make in (("waves", waves), ("noise", noise)):
    logits = session.run(["logits"], {"frames": make()})[0][0]
    order = np.argsort(-logits)[:5]
    out[name] = [[int(i), round(float(logits[i]), 4)] for i in order]
    print(name, out[name])
here = os.path.dirname(os.path.abspath(__file__))
json.dump(out, open(os.path.join(here, "..", "RSLTests", "reference.json"), "w"), indent=1)
