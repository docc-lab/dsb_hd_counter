"""
gru_train.py
============
GRU-based contention severity predictor.
  • Predicts:  p50_contention_score  [0, 1]  (regression only)
  • Features:  all perf_counters (absolute) + all perf_deltas + full timing
               percentiles + freq fields + derived ratios
  • Outputs:   gru_model_run{N}.pth  +  gru_model_run{N}.onnx
               gru_model_best.pth    +  gru_model_best.onnx
"""

import sys
import json
import numpy as np
import matplotlib.pyplot as plt
from typing import List, Dict, Tuple, Optional
from pathlib import Path
import torch
import torch.nn as nn
import torch.optim as optim
from torch.utils.data import Dataset, DataLoader
from torch.optim.lr_scheduler import ReduceLROnPlateau, CosineAnnealingLR, StepLR, ExponentialLR
from sklearn.preprocessing import StandardScaler
import time
import random
import psutil

print(torch.__version__)
print(torch.version.git_version)

# ══════════════════════════════════════════════════════════════════════════════
# FEATURE EXTRACTION HELPERS
# ══════════════════════════════════════════════════════════════════════════════

# All keys that may appear in perf_counters / perf_deltas
PERF_COUNTER_KEYS = [
    "LLC-load-misses",
    "LLC-loads",
    "branch-instructions",
    "branch-misses",
    "cycles",
    "dTLB-load-misses",
    "dTLB-loads",
    "instructions",
    "page-faults",
    "ref-cycles",
]

# Latency distribution percentiles available in processing/total/blocking
TIMING_PCT_KEYS = ["p50_ns", "p60_ns", "p70_ns", "p75_ns",
                   "p80_ns", "p90_ns", "p99_ns"]

TIMING_STAT_KEYS = ["min_ns", "max_ns", "mean_ns"] + TIMING_PCT_KEYS + ["count"]

TIMING_SECTIONS = ["processing_time", "total_time", "blocking_time"]

# freq sub-fields (numeric only)
FREQ_KEYS = ["actual_freq_mhz", "current_max_mhz", "active_n",
             "freq_util_pct", "tsc_freq_mhz"]


def _safe(val, default=0.0) -> float:
    if val is None:
        return default
    try:
        return float(val)
    except (TypeError, ValueError):
        return default


def extract_features(sample: Dict) -> np.ndarray:
    """
    Extract every numeric field from a sample into a 1-D feature vector.

    Feature groups (all log1p-transformed before StandardScaler):
      1.  perf_counters  (absolute snapshot)       – 10 values
      2.  perf_deltas    (inter-sample deltas)      – 10 values
      3.  timing scalars (arrival/rps)              –  3 values
      4.  timing distributions per section          –  3 × 11 = 33 values
      5.  freq fields                               –  5 values
      6.  derived ratios (no log1p on these)        –  5 values

    Total: 66 features (derived ratios appended after log1p block).
    """
    perf_c  = sample.get("perf_counters", {})
    perf_d  = sample.get("perf_deltas",   {})
    timing  = sample.get("timing_window", {})
    freq    = sample.get("freq", {})

    # ── group 1: perf_counters absolute ──────────────────────────────────────
    g1 = [_safe(perf_c.get(k)) for k in PERF_COUNTER_KEYS]

    # ── group 2: perf_deltas ──────────────────────────────────────────────────
    g2 = [_safe(perf_d.get(k)) for k in PERF_COUNTER_KEYS]

    # ── group 3: arrival / rps ────────────────────────────────────────────────
    g3 = [
        _safe(timing.get("arrival_count")),
        _safe(timing.get("request_count")),
        _safe(timing.get("arrival_rps_1s")),
        _safe(timing.get("arrival_rps_3s")),
    ]

    # ── group 4: timing distributions ────────────────────────────────────────
    g4 = []
    for section in TIMING_SECTIONS:
        sec = timing.get(section, {})
        for k in TIMING_STAT_KEYS:
            g4.append(_safe(sec.get(k)))

    # ── group 5: freq ─────────────────────────────────────────────────────────
    g5 = [_safe(freq.get(k)) for k in FREQ_KEYS]
    # turbo_on as binary
    g5.append(1.0 if freq.get("turbo_on") else 0.0)

    # ── log1p on all the above ────────────────────────────────────────────────
    raw_log = np.log1p(np.array(g1 + g2 + g3 + g4 + g5, dtype=np.float64))

    # ── group 6: derived ratios (not log1p'd; already in [0,1] range) ─────────
    delta_cyc   = _safe(perf_d.get("cycles"))       + 1e-9
    delta_inst  = _safe(perf_d.get("instructions")) + 1e-9
    delta_llc_m = _safe(perf_d.get("LLC-load-misses")) + 1e-9
    delta_llc_l = _safe(perf_d.get("LLC-loads"))       + 1e-9
    delta_br    = _safe(perf_d.get("branch-instructions")) + 1e-9
    delta_brm   = _safe(perf_d.get("branch-misses"))       + 1e-9
    delta_dtlb  = _safe(perf_d.get("dTLB-loads"))          + 1e-9
    delta_dtlbm = _safe(perf_d.get("dTLB-load-misses"))    + 1e-9

    ipc        = np.clip(delta_inst  / delta_cyc,   0.0, 10.0)
    llc_mrate  = np.clip(delta_llc_m / delta_llc_l, 0.0, 1.0)
    br_mrate   = np.clip(delta_brm   / delta_br,    0.0, 1.0)
    dtlb_mrate = np.clip(delta_dtlbm / delta_dtlb,  0.0, 1.0)
    freq_util  = np.clip(_safe(freq.get("freq_util_pct")) / 100.0, 0.0, 1.0)

    ratios = np.array([ipc, llc_mrate, br_mrate, dtlb_mrate, freq_util],
                      dtype=np.float64)

    return np.concatenate([raw_log, ratios]).astype(np.float32)


# report feature dimensionality once
_DUMMY       = extract_features({})
N_FEATURES   = len(_DUMMY)
print(f"[feature extractor] {N_FEATURES} features per sample")


# ══════════════════════════════════════════════════════════════════════════════
# DATASET
# ══════════════════════════════════════════════════════════════════════════════

class ContentionDataset(Dataset):
    """
    Each item:
      sequences : FloatTensor  [seq_len, n_features]
      label     : FloatTensor  scalar  – p50_contention_score
    """
    def __init__(self, sequences: np.ndarray, labels: np.ndarray):
        self.sequences = torch.FloatTensor(sequences)
        self.labels    = torch.FloatTensor(labels)   # (N,)

    def __len__(self):
        return len(self.sequences)

    def __getitem__(self, idx):
        return self.sequences[idx], self.labels[idx]


# ══════════════════════════════════════════════════════════════════════════════
# MODEL
# ══════════════════════════════════════════════════════════════════════════════

class GRUContentionPredictor(nn.Module):
    """
    Single-output regression model.
      • GRU trunk with mean+max temporal pooling
      • Single head: p50_score  (raw linear; targets normalised to [0,1])
    """
    def __init__(self, input_size: int, hidden_size: int = 64,
                 num_layers: int = 1, dropout: float = 0.1):
        super().__init__()
        self.hidden_size = hidden_size
        self.num_layers  = num_layers

        self.gru = nn.GRU(
            input_size  = input_size,
            hidden_size = hidden_size,
            num_layers  = num_layers,
            dropout     = dropout if num_layers > 1 else 0.0,
            batch_first = True,
        )

        pool_size = hidden_size * 2  # mean + max

        self.neck = nn.Sequential(
            nn.Linear(pool_size, hidden_size),
            nn.ReLU(),
            nn.Dropout(dropout),
        )
        self.head = nn.Linear(hidden_size, 1)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        gru_out, _ = self.gru(x)                          # (B, T, H)
        mean_pool  = gru_out.mean(dim=1)                  # (B, H)
        max_pool   = gru_out.max(dim=1).values            # (B, H)
        pooled     = torch.cat([mean_pool, max_pool], dim=1)   # (B, 2H)
        out        = self.head(self.neck(pooled)).squeeze(-1)   # (B,)
        return out


# ══════════════════════════════════════════════════════════════════════════════
# TRAINER
# ══════════════════════════════════════════════════════════════════════════════

class GRUTrainer:
    def __init__(self, config: Dict):
        self.config          = config
        self.model_config    = config['model']
        self.training_config = config['training']
        self.data_config     = config['data']

        self.sequence_length = self.model_config['sequence_length']
        self.hidden_size     = self.model_config['hidden_size']
        self.num_layers      = self.model_config['num_layers']
        self.dropout         = self.model_config['dropout']

        self.model  = None
        self.scaler = StandardScaler()
        self.device = torch.device('cuda' if torch.cuda.is_available() else 'cpu')

        self.use_amp     = (self.training_config.get('mixed_precision', False)
                            and torch.cuda.is_available())
        self.grad_scaler = torch.cuda.amp.GradScaler() if self.use_amp else None

        print(f"Initialized GRU Trainer  (p50 regression only)")
        print(f"  Device:         {self.device}")
        print(f"  Features/step:  {N_FEATURES}")
        if self.use_amp:
            print(f"  Mixed precision: ENABLED")
        self._print_config()

    # ── config printing ────────────────────────────────────────────────────────

    def _print_config(self):
        print(f"\n{'='*70}")
        print("CONFIGURATION")
        print(f"{'='*70}")
        for section in ('model', 'training', 'data'):
            print(f"\n{section.capitalize()}:")
            skip = {'optimizer_params', 'scheduler_params'}
            for k, v in self.config[section].items():
                if k not in skip:
                    print(f"  {k}: {v}")
            for sub in skip:
                if sub in self.config[section]:
                    print(f"  {sub}:")
                    for k, v in self.config[section][sub].items():
                        print(f"    {k}: {v}")

    # ── file loading ───────────────────────────────────────────────────────────

    def load_from_file(self, filepath: str) -> List[Dict]:
        with open(filepath, 'r') as f:
            data = json.load(f)
        if isinstance(data, dict) and 'samples' in data:
            return data['samples']
        elif isinstance(data, list):
            return data
        return [data]

    def load_multiple_files(self, filepaths: List[str]) -> List[List[Dict]]:
        out = []
        for fp in filepaths:
            try:
                samples = self.load_from_file(fp)
                if samples:
                    out.append(samples)
            except Exception as e:
                print(f"Warning: Could not load {fp}: {e}")
        return out

    # ── sequence preparation ───────────────────────────────────────────────────

    def prepare_sequences(self, files_samples: List[List[Dict]],
                          fit_scaler: bool = True) -> Tuple[np.ndarray, np.ndarray]:
        """
        Returns
        -------
        X : (N, seq_len, n_features)   log1p + StandardScaler
        y : (N,)                       p50_contention_score
        """
        if fit_scaler:
            all_feats = [extract_features(s)
                         for samples in files_samples for s in samples]
            self.scaler.fit(np.array(all_feats))

        all_seqs, all_labels = [], []

        for samples in files_samples:
            feats  = np.array([extract_features(s) for s in samples])
            labels = np.array([
                float(s.get('p50_contention_score',
                             s.get('contention_score', 0.0)))
                for s in samples
            ], dtype=np.float32)

            feats_scaled = self.scaler.transform(feats)

            for i in range(len(samples) - self.sequence_length):
                all_seqs.append(feats_scaled[i: i + self.sequence_length])
                all_labels.append(labels[i + self.sequence_length])

        return (np.array(all_seqs,   dtype=np.float32),
                np.array(all_labels, dtype=np.float32))

    # ── optimiser / scheduler factories ───────────────────────────────────────

    def get_criterion(self):
        name = self.training_config.get('criterion', 'mse').lower()
        if name == 'mse':
            return nn.MSELoss()
        elif name == 'smoothl1':
            return nn.SmoothL1Loss()
        raise ValueError(f"Unknown criterion: {name}")

    def get_optimizer(self):
        name   = self.training_config.get('optimizer', 'adam').lower()
        lr     = self.training_config['learning_rate']
        params = self.training_config.get('optimizer_params', {})
        if name == 'adam':
            return optim.Adam(self.model.parameters(), lr=lr,
                              weight_decay=params.get('weight_decay', 1e-4),
                              betas=params.get('betas', (0.9, 0.999)))
        elif name == 'adamw':
            return optim.AdamW(self.model.parameters(), lr=lr,
                               weight_decay=params.get('weight_decay', 0.01),
                               betas=params.get('betas', (0.9, 0.999)))
        elif name == 'sgd':
            return optim.SGD(self.model.parameters(), lr=lr,
                             momentum=params.get('momentum', 0.9),
                             nesterov=params.get('nesterov', True))
        raise ValueError(f"Unknown optimizer: {name}")

    def get_scheduler(self, optimizer):
        name = self.training_config.get('scheduler', None)
        if name is None:
            return None
        p    = self.training_config.get('scheduler_params', {})
        name = name.lower()
        if name == 'plateau':
            return ReduceLROnPlateau(optimizer, mode='min',
                                    factor=p.get('factor', 0.5),
                                    patience=p.get('patience', 5))
        elif name == 'cosine':
            return CosineAnnealingLR(optimizer,
                                     T_max=p.get('T_max', self.training_config['epochs']),
                                     eta_min=p.get('eta_min', 1e-6))
        elif name == 'step':
            return StepLR(optimizer, step_size=p.get('step_size', 30),
                          gamma=p.get('gamma', 0.1))
        elif name == 'exponential':
            return ExponentialLR(optimizer, gamma=p.get('gamma', 0.95))
        raise ValueError(f"Unknown scheduler: {name}")

    # ── single epoch ───────────────────────────────────────────────────────────

    def _run_epoch(self, loader, optimizer, criterion,
                   gradient_clip, train: bool) -> float:
        self.model.train() if train else self.model.eval()
        total_loss = 0.0
        ctx = torch.enable_grad() if train else torch.no_grad()

        with ctx:
            for seqs, labels in loader:
                seqs   = seqs.to(self.device)
                labels = labels.to(self.device)

                if train:
                    optimizer.zero_grad()

                if self.use_amp:
                    with torch.cuda.amp.autocast():
                        preds = self.model(seqs)
                        loss  = criterion(preds, labels)
                else:
                    preds = self.model(seqs)
                    loss  = criterion(preds, labels)

                if train:
                    if self.use_amp:
                        self.grad_scaler.scale(loss).backward()
                        if gradient_clip:
                            self.grad_scaler.unscale_(optimizer)
                            nn.utils.clip_grad_norm_(self.model.parameters(), gradient_clip)
                        self.grad_scaler.step(optimizer)
                        self.grad_scaler.update()
                    else:
                        loss.backward()
                        if gradient_clip:
                            nn.utils.clip_grad_norm_(self.model.parameters(), gradient_clip)
                        optimizer.step()

                total_loss += loss.item()

        return total_loss / max(len(loader), 1)

    # ── ONNX export ────────────────────────────────────────────────────────────

    def export_onnx(self, onnx_path: str):
        """Export current model weights to ONNX (opset 14)."""
        self.model.eval()
        seq_len    = self.sequence_length
        dummy_input = torch.zeros(1, seq_len, N_FEATURES, device=self.device)

        # Move model to CPU for ONNX export (avoids CUDA device mismatch on
        # machines that run inference CPU-only)
        cpu_model = self.model.cpu().eval()
        dummy_cpu = dummy_input.cpu()

        torch.onnx.export(
            cpu_model,
            dummy_cpu,
            onnx_path,
            export_params   = True,
            opset_version   = 14,
            do_constant_folding = True,
            input_names     = ['input'],
            output_names    = ['p50_score'],
            dynamic_axes    = {
                'input':     {0: 'batch_size'},
                'p50_score': {0: 'batch_size'},
            },
        )
        # move model back to original device
        self.model.to(self.device)
        print(f"  ✓ ONNX model saved: {onnx_path}")

    # ── plotting ───────────────────────────────────────────────────────────────

    def plot_training_history(self, train_losses, val_losses, run_id,
                              save_path='training_history.png'):
        plt.figure(figsize=(10, 6))
        epochs = range(1, len(train_losses) + 1)
        plt.plot(epochs, train_losses, 'b-', label='Training Loss',   linewidth=2)
        plt.plot(epochs, val_losses,   'r-', label='Validation Loss', linewidth=2)
        best_epoch    = int(np.argmin(val_losses)) + 1
        best_val_loss = float(min(val_losses))
        plt.axvline(x=best_epoch, color='green', linestyle='--', linewidth=1.5,
                    label=f'Best Epoch: {best_epoch}')
        plt.scatter([best_epoch], [best_val_loss], color='green', s=100, zorder=5)
        plt.xlabel('Epoch', fontsize=12, fontweight='bold')
        plt.ylabel('MSE Loss', fontsize=12, fontweight='bold')
        plt.title(f'Training History — Run {run_id}', fontsize=14, fontweight='bold')
        plt.legend(fontsize=11)
        plt.grid(True, alpha=0.3)
        plt.tight_layout()
        plt.savefig(save_path, dpi=300, bbox_inches='tight')
        print(f"  ✓ Training history saved: {save_path}")
        plt.close()

    def plot_predictions(self, y_actual: np.ndarray, y_pred: np.ndarray,
                         run_id: int, test_files: List[str],
                         save_path: str = 'predictions_comparison.png'):
        fig, axes = plt.subplots(1, 2, figsize=(14, 5))
        indices   = np.arange(len(y_actual))

        ax = axes[0]
        ax.plot(indices, y_actual, 'b-', label='Actual p50',    linewidth=1.2, alpha=0.7)
        ax.plot(indices, y_pred,   'r-', label='Predicted p50', linewidth=1.2, alpha=0.7)
        rmse = float(np.sqrt(np.mean((y_pred - y_actual) ** 2)))
        mae  = float(np.mean(np.abs(y_pred - y_actual)))
        ax.text(0.02, 0.98, f'RMSE: {rmse:.4f}\nMAE: {mae:.4f}',
                transform=ax.transAxes, fontsize=9, verticalalignment='top',
                bbox=dict(boxstyle='round', facecolor='wheat', alpha=0.8))
        ax.set_title(f'p50 Score — Full View (Run {run_id})', fontweight='bold')
        ax.set_xlabel('Sample Index'); ax.set_ylabel('Score')
        ax.legend(fontsize=9); ax.grid(True, alpha=0.3)

        ax2 = axes[1]
        ax2.scatter(y_actual, y_pred, alpha=0.3, s=8)
        lo = min(y_actual.min(), y_pred.min())
        hi = max(y_actual.max(), y_pred.max())
        ax2.plot([lo, hi], [lo, hi], 'r--', linewidth=2, label='Perfect')
        ax2.set_title('p50 Score Scatter', fontweight='bold')
        ax2.set_xlabel('Actual'); ax2.set_ylabel('Predicted')
        ax2.legend(fontsize=9); ax2.grid(True, alpha=0.3)

        plt.suptitle(f'Predictions — Run {run_id}', fontsize=13, fontweight='bold')
        plt.tight_layout()
        plt.savefig(save_path, dpi=300, bbox_inches='tight')
        print(f"  ✓ Prediction plot saved: {save_path}")
        plt.close()

    # ── save / compare ─────────────────────────────────────────────────────────

    def save_current_run(self, metrics: Dict, train_losses, val_losses,
                         run_id: int) -> Tuple[str, str, str]:
        model_path = f'gru_model_run{run_id}.pth'
        onnx_path  = f'gru_model_run{run_id}.onnx'
        cfg_path   = f'gru_config_run{run_id}.json'

        torch.save(self.model.state_dict(), model_path)
        self.export_onnx(onnx_path)

        # save scaler params alongside so inference can reconstruct it
        scaler_meta = {
            'mean':  self.scaler.mean_.tolist(),
            'scale': self.scaler.scale_.tolist(),
            'n_features_in': int(self.scaler.n_features_in_),
        }

        cfg = {
            'run_id':        run_id,
            'config':        self.config,
            'n_features':    N_FEATURES,
            'scaler':        scaler_meta,
            'metrics': {
                'p50_rmse': float(metrics['p50_rmse']),
                'p50_mae':  float(metrics['p50_mae']),
                'p50_r2':   float(metrics['p50_r2']),
                'rmse':     float(metrics['p50_rmse']),  # compat
                'mae':      float(metrics['p50_mae']),   # compat
            },
            'training': {
                'final_train_loss':      float(train_losses[-1]),
                'final_val_loss':        float(val_losses[-1]),
                'best_val_loss':         float(min(val_losses)),
                'best_epoch':            int(np.argmin(val_losses) + 1),
                'total_epochs':          len(train_losses),
                'training_time_seconds': float(metrics.get('training_time', 0)),
            },
            'timestamp': time.strftime('%Y-%m-%d %H:%M:%S'),
        }
        with open(cfg_path, 'w') as f:
            json.dump(cfg, f, indent=2)

        print(f"\n✓ Run {run_id} saved: {model_path}  {onnx_path}  {cfg_path}")
        return model_path, onnx_path, cfg_path

    def compare_and_update_best(self, metrics: Dict, run_id: int) -> bool:
        best_path     = Path('gru_config_best.json')
        cur_rmse      = metrics['p50_rmse']
        cur_mae       = metrics['p50_mae']
        should_update = False

        if not best_path.exists():
            print(f"\n{'='*70}")
            print(f"RUN {run_id} — FIRST RUN, SETTING AS BEST")
            print(f"  p50 RMSE: {cur_rmse:.6f}  p50 MAE: {cur_mae:.6f}")
            should_update = True
        else:
            with open(best_path) as f:
                best_cfg = json.load(f)
            best_rmse   = best_cfg['metrics']['rmse']
            best_mae    = best_cfg['metrics']['mae']
            best_run_id = best_cfg.get('run_id', '?')

            print(f"\n{'='*70}")
            print(f"RUN {run_id} vs BEST (Run {best_run_id})")
            print(f"  Prev  RMSE:{best_rmse:.6f}  MAE:{best_mae:.6f}")
            print(f"  Curr  RMSE:{cur_rmse:.6f}   MAE:{cur_mae:.6f}")

            if cur_rmse < best_rmse and cur_mae < best_mae:
                pct_rmse = (best_rmse - cur_rmse) / best_rmse * 100
                pct_mae  = (best_mae  - cur_mae)  / best_mae  * 100
                print(f"  🎉 IMPROVEMENT  RMSE↓{pct_rmse:.2f}%  MAE↓{pct_mae:.2f}%")
                should_update = True
            else:
                print("  → No improvement")

        if should_update:
            import shutil
            shutil.copy(f'gru_model_run{run_id}.pth',  'gru_model_best.pth')
            shutil.copy(f'gru_model_run{run_id}.onnx', 'gru_model_best.onnx')
            shutil.copy(f'gru_config_run{run_id}.json', 'gru_config_best.json')
            print(f"✓✓✓ Best model updated to Run {run_id}!")

        return should_update

    # ── training loop ──────────────────────────────────────────────────────────

    def train(self, train_files: List[str], val_files: List[str]):
        epochs     = self.training_config['epochs']
        batch_size = self.training_config['batch_size']

        print("\n" + "="*70)
        print("LOADING DATA")
        print("="*70)

        train_samples = self.load_multiple_files(train_files)
        val_samples   = self.load_multiple_files(val_files)
        print(f"Loaded {len(train_samples)} train files, {len(val_samples)} val files")

        X_train, y_train = self.prepare_sequences(train_samples, fit_scaler=True)
        X_val,   y_val   = self.prepare_sequences(val_samples,   fit_scaler=False)
        print(f"  Training sequences:   {len(X_train)}")
        print(f"  Validation sequences: {len(X_val)}")
        print(f"  Feature dims:         {X_train.shape[2]}")

        train_loader = DataLoader(ContentionDataset(X_train, y_train),
                                  batch_size=batch_size, shuffle=True,
                                  num_workers=0, pin_memory=self.use_amp)
        val_loader   = DataLoader(ContentionDataset(X_val,   y_val),
                                  batch_size=batch_size, shuffle=False,
                                  num_workers=0, pin_memory=self.use_amp)

        print("\n" + "="*70)
        print("BUILDING MODEL")
        print("="*70)

        input_size = X_train.shape[2]
        self.model = GRUContentionPredictor(
            input_size  = input_size,
            hidden_size = self.hidden_size,
            num_layers  = self.num_layers,
            dropout     = self.dropout,
        ).to(self.device)

        total_params = sum(p.numel() for p in self.model.parameters())
        print(f"  Input size:       {input_size}")
        print(f"  Total parameters: {total_params:,}")
        print(f"  Output:           p50_score  [regression, no sigmoid]")
        print(f"  Pooling:          mean + max over all timesteps")

        criterion   = self.get_criterion()
        optimizer   = self.get_optimizer()
        scheduler   = self.get_scheduler(optimizer)
        grad_clip   = self.training_config.get('gradient_clip', None)

        use_es      = self.training_config.get('early_stopping', False)
        es_patience = self.training_config.get('early_stopping_patience', 15)
        es_counter  = 0

        train_losses, val_losses = [], []
        best_val_loss = float('inf')

        print("\n" + "="*70)
        print("TRAINING")
        print("="*70)

        start_time = time.time()

        for epoch in range(epochs):
            ep1 = epoch + 1

            train_loss = self._run_epoch(train_loader, optimizer, criterion,
                                         grad_clip, train=True)
            val_loss   = self._run_epoch(val_loader,   optimizer, criterion,
                                         grad_clip, train=False)

            train_losses.append(train_loss)
            val_losses.append(val_loss)

            if scheduler is not None:
                if isinstance(scheduler, ReduceLROnPlateau):
                    scheduler.step(val_loss)
                else:
                    scheduler.step()

            if val_loss < best_val_loss:
                best_val_loss = val_loss
                torch.save(self.model.state_dict(), '_best_gru_temp.pth')
                es_counter = 0
            else:
                es_counter += 1

            if use_es and es_counter >= es_patience:
                print(f"\n  Early stopping at epoch {ep1} "
                      f"({es_patience} epochs without improvement)")
                break

            if ep1 % 10 == 0 or ep1 == 1:
                lr = optimizer.param_groups[0]['lr']
                print(f"  Epoch [{ep1:3d}/{epochs}]  "
                      f"Train:{train_loss:.6f}  Val:{val_loss:.6f}  LR:{lr:.2e}")

        training_time = time.time() - start_time
        self.model.load_state_dict(torch.load('_best_gru_temp.pth'))
        print(f"\n✓ Training done in {training_time:.2f}s")
        print(f"  Best val loss: {best_val_loss:.6f}  "
              f"(epoch {int(np.argmin(val_losses)) + 1})")

        return train_losses, val_losses, training_time

    # ── testing ────────────────────────────────────────────────────────────────

    def test(self, test_files: List[str], training_time: float,
             train_losses, val_losses, run_id: int) -> Dict:

        print("\n" + "="*70)
        print("TESTING")
        print("="*70)

        test_samples     = self.load_multiple_files(test_files)
        X_test, y_actual = self.prepare_sequences(test_samples, fit_scaler=False)
        print(f"  Test sequences: {len(X_test)}")

        self.model.eval()
        if torch.cuda.is_available():
            torch.cuda.reset_peak_memory_stats(self.device)
            torch.cuda.synchronize()

        preds, inference_times = [], []

        with torch.no_grad():
            for i in range(len(X_test)):
                seq = torch.FloatTensor(X_test[i]).unsqueeze(0).to(self.device)
                if torch.cuda.is_available():
                    torch.cuda.synchronize()
                t0 = time.time()
                if self.use_amp:
                    with torch.cuda.amp.autocast():
                        p = self.model(seq)
                else:
                    p = self.model(seq)
                if torch.cuda.is_available():
                    torch.cuda.synchronize()
                inference_times.append(time.time() - t0)
                preds.append(float(p.cpu()[0]))

        if torch.cuda.is_available():
            peak_mem_mb    = torch.cuda.max_memory_allocated(self.device) / (1024**2)
            current_mem_mb = torch.cuda.memory_allocated(self.device)      / (1024**2)
        else:
            proc           = psutil.Process()
            peak_mem_mb    = proc.memory_info().rss / (1024**2)
            current_mem_mb = peak_mem_mb

        preds = np.clip(np.array(preds), 0.0, 1.0)

        mse      = float(np.mean((preds - y_actual) ** 2))
        p50_rmse = float(np.sqrt(mse))
        p50_mae  = float(np.mean(np.abs(preds - y_actual)))
        ss_r     = float(np.sum((y_actual - preds) ** 2))
        ss_t     = float(np.sum((y_actual - y_actual.mean()) ** 2))
        p50_r2   = float(1 - ss_r / ss_t) if ss_t > 0 else 0.0

        inf_arr = np.array(inference_times)
        infer_stats = {
            'total_time_seconds':              float(inf_arr.sum()),
            'mean_time_ms':                    float(inf_arr.mean()     * 1000),
            'median_time_ms':                  float(np.median(inf_arr) * 1000),
            'p95_time_ms':                     float(np.percentile(inf_arr, 95) * 1000),
            'p99_time_ms':                     float(np.percentile(inf_arr, 99) * 1000),
            'total_sequences':                 len(X_test),
            'throughput_sequences_per_second': float(len(X_test) / inf_arr.sum()),
        }

        metrics = {
            'run_id': run_id,
            'model':  'GRU-p50-TemporalPool',
            'config': self.config,
            'p50_rmse':  p50_rmse,
            'p50_mae':   p50_mae,
            'p50_r2':    p50_r2,
            'rmse':      p50_rmse,   # compat
            'mae':       p50_mae,    # compat
            'r2':        p50_r2,     # compat
            'training_time': training_time,
            'inference':     infer_stats,
            'peak_memory_mb':    peak_mem_mb,
            'current_memory_mb': current_mem_mb,
            'predictions': preds.tolist(),
            'actuals':     y_actual.tolist(),
        }

        print(f"\nRun {run_id} Test Metrics:")
        print(f"  RMSE:{p50_rmse:.6f}  MAE:{p50_mae:.6f}  R²:{p50_r2:.6f}")
        print(f"  Inference  Mean:{infer_stats['mean_time_ms']:.3f}ms  "
              f"P95:{infer_stats['p95_time_ms']:.3f}ms  "
              f"Throughput:{infer_stats['throughput_sequences_per_second']:.0f} seq/s")
        print(f"  Train:{training_time:.2f}s  Peak mem:{peak_mem_mb:.1f}MB")

        print("\n" + "="*70)
        print("GENERATING PLOTS")
        print("="*70)
        Path('Plots').mkdir(exist_ok=True)
        self.plot_training_history(train_losses, val_losses, run_id,
                                   f'training_history_run{run_id}.png')
        self.plot_predictions(y_actual, preds, run_id, test_files,
                              f'Plots/predictions_run{run_id}.png')

        print("\n" + "="*70)
        print(f"SAVING RUN {run_id}")
        print("="*70)
        self.save_current_run(metrics, train_losses, val_losses, run_id)
        self.compare_and_update_best(metrics, run_id)

        return metrics


# ══════════════════════════════════════════════════════════════════════════════
# EXPERIMENT RUNNER
# ══════════════════════════════════════════════════════════════════════════════

def run_experiments(configs: List[Dict], data_files: List[str]):
    print("="*70)
    print("MULTI-CONFIG GRU EXPERIMENTS  (p50 regression)")
    print("="*70)
    print(f"Configs to run: {len(configs)}")

    all_results = []

    for run_id, config in enumerate(configs, start=1):
        print("\n" + "#"*70)
        print(f"RUN {run_id} / {len(configs)}")
        print("#"*70)

        seed = config['data']['random_seed']
        random.seed(seed); np.random.seed(seed); torch.manual_seed(seed)
        if torch.cuda.is_available():
            torch.cuda.manual_seed_all(seed)

        manual_test_files = [
            "../../Data/exp_20251211_194655_5cd623a4/raw/windowed/search/run_data_iter1_ready.json",
            "../../Data/exp_20251213_035336_7bcf6fa8/raw/windowed/profile/run_data_iter1_ready.json",
        ]
        remaining = [f for f in data_files if f not in manual_test_files]
        random.shuffle(remaining)

        train_r    = config['data']['train_split']
        val_r      = config['data']['val_split']
        test_r     = config['data']['test_split']
        n_test_rem = max(0, int(test_r * len(data_files)) - len(manual_test_files))
        n_train    = int(train_r * len(data_files))
        n_val      = int(val_r   * len(data_files))

        train_files = remaining[:n_train]
        val_files   = remaining[n_train: n_train + n_val]
        test_files  = (manual_test_files
                       + remaining[n_train + n_val: n_train + n_val + n_test_rem])

        print(f"Split: {len(train_files)} train  "
              f"{len(val_files)} val  {len(test_files)} test")

        trainer = GRUTrainer(config)
        train_losses, val_losses, training_time = trainer.train(train_files, val_files)
        metrics = trainer.test(test_files, training_time,
                               train_losses, val_losses, run_id)

        with open(f'gru_results_run{run_id}.json', 'w') as f:
            json.dump(metrics, f, indent=2)

        all_results.append(metrics)
        print(f"\n✓ Run {run_id} complete!")

    # ── summary table ──────────────────────────────────────────────────────────
    print("\n" + "="*70)
    print("EXPERIMENT SUMMARY")
    print("="*70)
    header = f"{'Run':<5} {'p50 RMSE':<11} {'p50 MAE':<11} {'p50 R²':<9} {'Train(s)'}"
    print(header)
    print("-" * len(header))

    best_run_id = -1
    best_path   = Path('gru_config_best.json')
    if best_path.exists():
        with open(best_path) as f:
            best_run_id = json.load(f).get('run_id', -1)

    for r in all_results:
        marker = " ✓✓✓" if r['run_id'] == best_run_id else ""
        print(f"{r['run_id']:<5} {r['p50_rmse']:<11.6f} {r['p50_mae']:<11.6f} "
              f"{r['p50_r2']:<9.4f} {r['training_time']:.2f}{marker}")

    print("\n" + "="*70)
    print("ALL EXPERIMENTS COMPLETE!")
    print("="*70)
    return all_results


# ══════════════════════════════════════════════════════════════════════════════
# CONFIGS
# ══════════════════════════════════════════════════════════════════════════════

config_plato = {
    'model': {
        'sequence_length': 50,
        'hidden_size':     64,
        'num_layers':      1,
        'dropout':         0.1,
    },
    'training': {
        'epochs':                  100,
        'batch_size':              64,
        'learning_rate':           0.001,
        'optimizer':               'adam',
        'criterion':               'mse',
        'optimizer_params':        {'weight_decay': 1e-4, 'betas': [0.9, 0.999]},
        'early_stopping':          True,
        'early_stopping_patience': 15,
        'gradient_clip':           1.0,
        'scheduler':               'plateau',
        'scheduler_params':        {'factor': 0.5, 'patience': 5},
        'mixed_precision':         True,
    },
    'data': {
        'train_split': 0.7,
        'val_split':   0.20,
        'test_split':  0.10,
        'random_seed': 21,
    },
}

config_baseline = {
    'model': {
        'sequence_length': 20,
        'hidden_size':     64,
        'num_layers':      1,
        'dropout':         0.1,
    },
    'training': {
        'epochs':                  100,
        'batch_size':              64,
        'learning_rate':           0.001,
        'optimizer':               'adam',
        'criterion':               'mse',
        'optimizer_params':        {'weight_decay': 1e-4, 'betas': [0.9, 0.999]},
        'early_stopping':          True,
        'early_stopping_patience': 15,
        'gradient_clip':           1.0,
        'scheduler':               'plateau',
        'scheduler_params':        {'factor': 0.5, 'patience': 5},
        'mixed_precision':         True,
    },
    'data': {
        'train_split': 0.7,
        'val_split':   0.27,
        'test_split':  0.03,
        'random_seed': 41,
    },
}

config_cosine = {
    'model': {
        'sequence_length': 20,
        'hidden_size':     64,
        'num_layers':      2,
        'dropout':         0.1,
    },
    'training': {
        'epochs':                  120,
        'batch_size':              64,
        'learning_rate':           0.001,
        'optimizer':               'adamw',
        'criterion':               'mse',
        'optimizer_params':        {'weight_decay': 0.001, 'betas': [0.9, 0.999]},
        'early_stopping':          True,
        'early_stopping_patience': 20,
        'gradient_clip':           1.0,
        'scheduler':               'cosine',
        'scheduler_params':        {'eta_min': 1e-6},
        'mixed_precision':         True,
    },
    'data': {
        'train_split': 0.7,
        'val_split':   0.27,
        'test_split':  0.03,
        'random_seed': 41,
    },
}


# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════

if __name__ == "__main__":

    valid_files_list = r"..\..\Data\valid_filtered_files.txt"

    with open(valid_files_list, 'r') as f:
        filtered_files = [f"../{line.strip()}" for line in f if line.strip()]

    all_files = [f.replace('_filtered.json', '_ready.json')
                 for f in filtered_files
                 if Path(f.replace('_filtered.json', '_ready.json')).exists()]

    fallback = [
        f.replace('_filtered.json', '_filtered_labeled.json')
        for f in filtered_files
        if Path(f.replace('_filtered.json', '_filtered_labeled.json')).exists()
        and f.replace('_filtered.json', '_ready.json') not in all_files
    ]
    all_files += fallback

    print(f"Found {len(all_files)} labeled files "
          f"({len(all_files) - len(fallback)} _ready.json, "
          f"{len(fallback)} legacy)")

    configs_to_run = [config_plato]

    results = run_experiments(
        configs    = configs_to_run,
        data_files = all_files,
    )

    print("\n" + "="*70)
    print("FILES GENERATED PER RUN")
    print("="*70)
    for i in range(1, len(configs_to_run) + 1):
        print(f"  Run {i}: gru_model_run{i}.pth  gru_model_run{i}.onnx  "
              f"gru_config_run{i}.json  gru_results_run{i}.json  "
              f"training_history_run{i}.png  Plots/predictions_run{i}.png")
    print("  Best: gru_model_best.pth  gru_model_best.onnx  gru_config_best.json")
    print("\nOutput: p50_contention_score  [0, 1]")