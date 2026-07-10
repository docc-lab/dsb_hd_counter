import sys
import json
import numpy as np
from sklearn.preprocessing import StandardScaler
from gru_train import extract_features, N_FEATURES

SEQUENCE_LENGTH = 50

def load_scaler(cfg_path="gru_config_run1.json"):
    cfg = json.load(open(cfg_path))
    if "scaler" not in cfg:
        print("[shared_input] WARNING: 'scaler' missing in config → using identity scaler", file=sys.stderr)
        scaler = StandardScaler()
        scaler.mean_ = np.zeros(N_FEATURES)
        scaler.scale_ = np.ones(N_FEATURES)
        scaler.n_features_in_ = N_FEATURES
        return scaler
    meta = cfg["scaler"]
    scaler = StandardScaler()
    scaler.mean_ = np.array(meta["mean"])
    scaler.scale_ = np.array(meta["scale"])
    scaler.n_features_in_ = meta["n_features_in"]
    return scaler

def load_sequence(json_path, scaler):
    samples = json.load(open(json_path))
    if "samples" in samples:
        samples = samples["samples"]
    feats = np.array([extract_features(s) for s in samples])
    print(f"[feature extractor] {feats.shape[1]} features per sample", file=sys.stderr)
    feats = scaler.transform(feats)
    seq = feats[-SEQUENCE_LENGTH:]
    seq = seq.reshape(1, SEQUENCE_LENGTH, N_FEATURES).astype(np.float32)
    return seq

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 shared_input.py <input_json>")
        sys.exit(1)
    input_json = sys.argv[1]
    scaler = load_scaler()
    seq = load_sequence(input_json, scaler)
    np.save("input_seq.npy", seq)
    seq.astype(np.float32).tofile("input_seq.bin")
    print(f"Shared input prepared from: {input_json}")