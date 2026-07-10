import json
import os
import numpy as np
import re
from pathlib import Path
from typing import Dict, List, Tuple, Optional


def check_iteration_validity(latency_summary_file: str, iteration_num: int) -> Tuple[bool, str]:
    """
    Check if an iteration is valid based on latency_summary.txt criteria.
    
    Checks:
    1. Non-2xx or 3xx responses must be <= 200
    2. p50 (50.000% percentile) must be >= 5 ms
    
    Args:
        latency_summary_file: Path to processed/latency_summary.txt
        iteration_num: Iteration number to check (1, 2, or 3)
    
    Returns:
        Tuple of (is_valid, reason_if_invalid)
    """
    summary_path = Path(latency_summary_file)
    
    if not summary_path.exists():
        return True, ""
    
    try:
        with open(summary_path, 'r') as f:
            content = f.read()
        
        sections = content.split("=== ITERATION")
        
        target_section = None
        for section in sections:
            if section.strip().startswith(f"{iteration_num} ==="):
                target_section = section
                break
        
        if target_section is None:
            return True, ""
        
        dropped_match = re.search(r'Non-2xx or 3xx responses:\s*(\d+)', target_section)
        if dropped_match:
            dropped_count = int(dropped_match.group(1))
            if dropped_count > 200:
                return False, f"dropped_requests={dropped_count}"
        
        p50_match = re.search(r'50\.000%\s+([\d.]+)ms', target_section)
        if p50_match:
            p50_value = float(p50_match.group(1))
            if p50_value < 5.0:
                return False, f"p50={p50_value:.2f}ms"
        
        return True, ""
        
    except Exception as e:
        print(f"    ⚠ Warning: Could not read latency_summary.txt: {e}")
        return True, ""


def filter_zero_request_samples(input_file: str, output_file: str = None) -> Dict:
    """
    Filter out samples with request_count = 0 from JSON data file.
    
    Args:
        input_file: Path to input JSON file
        output_file: Path to output JSON file (if None, creates _filtered.json version)
    
    Returns:
        Dictionary with statistics about filtering
    """
    input_path = Path(input_file)
    
    if not input_path.exists():
        raise FileNotFoundError(f"File not found: {input_file}")
    
    if output_file is None:
        output_file = str(input_path.parent / f"{input_path.stem}_filtered{input_path.suffix}")
    
    print(f"  Processing: {input_path.name}")
    with open(input_file, 'r') as f:
        data = json.load(f)
    
    if isinstance(data, dict) and 'samples' in data:
        samples = data['samples']
        is_wrapped = True
    elif isinstance(data, list):
        samples = data
        is_wrapped = False
    else:
        raise ValueError("Unexpected JSON structure")
    
    original_count = len(samples)
    filtered_samples = [
        s for s in samples 
        if s.get('timing_window', {}).get('request_count', 0) > 0
    ]
    filtered_count = len(filtered_samples)
    removed_count = original_count - filtered_count
    
    if is_wrapped:
        data['samples'] = filtered_samples
        if 'sample_count' in data:
            data['sample_count'] = filtered_count
    else:
        data = filtered_samples
    
    has_valid_samples = filtered_count > 0
    
    if has_valid_samples:
        with open(output_file, 'w') as f:
            json.dump(data, f, indent=2)
        print(f"    ✓ Saved: {filtered_count} samples → {Path(output_file).name}")
    else:
        print(f"    ✗ Skipped: All samples have zero requests")
    
    stats = {
        'input_file': str(input_path),
        'output_file': str(Path(output_file)) if has_valid_samples else None,
        'original_count': original_count,
        'filtered_count': filtered_count,
        'removed_count': removed_count,
        'removal_percentage': (removed_count / original_count * 100) if original_count > 0 else 0,
        'has_valid_samples': has_valid_samples
    }
    
    return stats


def get_experiment_metadata(exp_dir: Path) -> Tuple[str, str]:
    """
    Extract metadata from experiment directory.
    
    Args:
        exp_dir: Path to experiment directory
    
    Returns:
        Tuple of (burst_schedule_content, wrk2_rate)
    """
    burst_schedule = ""
    wrk2_rate = ""
    
    burst_file = exp_dir / "metadata" / "burst_schedule_iter1.txt"
    if burst_file.exists():
        try:
            with open(burst_file, 'r') as f:
                burst_schedule = f.read().strip()
        except Exception as e:
            burst_schedule = f"<error reading: {e}>"
    else:
        burst_schedule = "<file not found>"
    
    exp_json = exp_dir / "metadata" / "experiment.json"
    if exp_json.exists():
        try:
            with open(exp_json, 'r') as f:
                content = f.read()
            
            rate_match = re.search(r'"rate":\s*(\d+)', content)
            if rate_match:
                wrk2_rate = rate_match.group(1)
            else:
                try:
                    data = json.loads(content)
                    rate_value = data.get('configuration', {}).get('wrk2_config', {}).get('rate')
                    if rate_value is not None:
                        wrk2_rate = str(rate_value)
                    else:
                        wrk2_rate = '<not found>'
                except json.JSONDecodeError:
                    wrk2_rate = '<malformed JSON, rate not found>'
        except Exception as e:
            wrk2_rate = f"<error: {type(e).__name__}>"
    else:
        wrk2_rate = "<file not found>"
    
    return burst_schedule, wrk2_rate


def scan_and_filter_data_directory(base_path: str,
                                   services: List[str] = ['search', 'profile'],
                                   output_list_files: Dict[str, str] = None,
                                   failed_experiments_file: str = "failed.txt") -> Tuple[Dict[str, List[Dict]], Dict[str, List[str]]]:
    """
    Scan ../Data directory for experiment subdirectories and filter run_data_iter[1-3].json files
    for multiple services.
    
    Looks for files matching pattern: */raw/windowed/{service}/run_data_iter[1-3].json
    
    Args:
        base_path: Path to the Data directory (e.g., "../Data")
        services: List of service names to process (e.g., ['search', 'profile'])
        output_list_files: Dict mapping service name to output filename
        failed_experiments_file: Filename for experiments with no valid iterations
    
    Returns:
        Tuple of (all_stats_by_service, valid_files_by_service)
    """
    base_path = Path(base_path)
    
    if not base_path.exists():
        raise FileNotFoundError(f"Data directory not found: {base_path}")
    
    if output_list_files is None:
        output_list_files = {service: f"valid_filtered_files_{service}.txt" for service in services}
    
    print("="*70)
    print(f"SCANNING DATA DIRECTORY: {base_path.absolute()}")
    print("="*70)
    print(f"Services: {', '.join(services)}")
    print(f"Looking for: */raw/windowed/{{service}}/run_data_iter[1-3].json")
    print()
    
    all_stats_by_service = {service: [] for service in services}
    valid_files_by_service = {service: [] for service in services}
    failed_experiments = []
    
    exp_dirs = sorted([d for d in base_path.iterdir() if d.is_dir()])
    
    print(f"Found {len(exp_dirs)} directories to scan")
    
    if len(exp_dirs) == 0:
        print(f"\n⚠ WARNING: No subdirectories found in {base_path.absolute()}")
        print("Please check that the path is correct.")
        return all_stats_by_service, valid_files_by_service
    
    print()
    
    service_stats = {
        service: {
            'total_found': 0,
            'total_processed': 0,
            'dirs_with_files': 0,
            'dropped_by_latency_checks': 0,
            'dropped_by_zero_samples': 0
        } for service in services
    }
    
    for exp_dir in exp_dirs:
        exp_has_files = False
        exp_has_valid_files = False
        
        latency_summary_file = exp_dir / "processed" / "latency_summary.txt"
        
        for service in services:
            service_path = exp_dir / "raw" / "windowed" / service
            
            if not service_path.exists():
                continue
            
            iter_files = []
            for iter_num in [1, 2, 3]:
                iter_file = service_path / f"run_data_iter{iter_num}.json"
                if iter_file.exists():
                    if "_filtered" not in iter_file.stem and "_labeled" not in iter_file.stem:
                        is_valid, reason = check_iteration_validity(str(latency_summary_file), iter_num)
                        if not is_valid:
                            if not exp_has_files:
                                print(f"Directory: {exp_dir.name}")
                                exp_has_files = True
                            print(f"  [{service.upper()}] ITER{iter_num}: Skipped ({reason})")
                            service_stats[service]['dropped_by_latency_checks'] += 1
                            continue
                        
                        iter_files.append(iter_file)
            
            if not iter_files:
                continue
            
            if not exp_has_files:
                print(f"Directory: {exp_dir.name}")
                exp_has_files = True
            
            service_stats[service]['total_found'] += len(iter_files)
            service_stats[service]['dirs_with_files'] += 1
            
            print(f"  [{service.upper()}] Found {len(iter_files)} run_data_iter file(s) passing latency checks")
            
            for iter_file in sorted(iter_files):
                try:
                    output_file = iter_file.parent / f"{iter_file.stem}_filtered{iter_file.suffix}"
                    
                    stats = filter_zero_request_samples(str(iter_file), str(output_file))
                    stats['service'] = service
                    all_stats_by_service[service].append(stats)
                    service_stats[service]['total_processed'] += 1
                    
                    if stats['has_valid_samples']:
                        valid_files_by_service[service].append(str(output_file))
                        exp_has_valid_files = True
                    else:
                        service_stats[service]['dropped_by_zero_samples'] += 1
                    
                except Exception as e:
                    print(f"    ✗ Error processing {iter_file.name}: {e}")
        
        if exp_has_files:
            print()
        
        if exp_has_files and not exp_has_valid_files:
            burst_schedule, wrk2_rate = get_experiment_metadata(exp_dir)
            failed_experiments.append({
                'name': exp_dir.name,
                'burst_schedule': burst_schedule,
                'wrk2_rate': wrk2_rate
            })
    
    print("="*70)
    print("SCAN COMPLETE")
    print("="*70)
    
    for service in services:
        stats = service_stats[service]
        all_stats = all_stats_by_service[service]
        valid_files = valid_files_by_service[service]
        
        print(f"\n[{service.upper()}]")
        
        total_iterations_checked = stats['total_found'] + stats['dropped_by_latency_checks']
        
        if total_iterations_checked == 0:
            print(f"  ⚠ WARNING: No run_data_iter[1-3].json files found!")
            print(f"  Directories checked with {service} path: {stats['dirs_with_files']}/{len(exp_dirs)}")
        else:
            print(f"  Total iterations checked: {total_iterations_checked}")
            print(f"  Dropped (latency checks failed): {stats['dropped_by_latency_checks']}")
            print(f"  Passed latency checks: {stats['total_found']}")
            print(f"  Files processed: {stats['total_processed']}")
            print(f"  Files with valid samples: {len(valid_files)}")
            print(f"  Dropped (all zero samples): {stats['dropped_by_zero_samples']}")
        
        if valid_files:
            output_list_path = Path(base_path) / output_list_files[service]
            
            print(f"\n  Writing {len(valid_files)} valid file paths to: {output_list_path.name}")
            
            with open(output_list_path, 'w') as f:
                for file_path in valid_files:
                    f.write(f"{file_path}\n")
            
            print(f"  ✓ Saved to: {output_list_path}")
    
    if failed_experiments:
        failed_file_path = Path(base_path) / failed_experiments_file
        print(f"\n{'='*70}")
        print(f"EXPERIMENTS WITH NO VALID ITERATIONS: {len(failed_experiments)}")
        print(f"{'='*70}")
        
        with open(failed_file_path, 'w') as f:
            f.write("# Experiments with no valid iterations\n")
            f.write("# Format: experiment_name | wrk2_rate | burst_schedule\n")
            f.write("#" + "="*66 + "\n\n")
            
            for exp in failed_experiments:
                line = f"{exp['name']} | rate={exp['wrk2_rate']} | {exp['burst_schedule']}\n"
                f.write(line)
                print(f"  {exp['name']}")
        
        print(f"\n  ✓ Failed experiments written to: {failed_file_path}")
    
    return all_stats_by_service, valid_files_by_service


def print_summary(all_stats_by_service: Dict[str, List[Dict]]):
    """Print summary statistics for all filtered files by service."""
    
    for service, all_stats in all_stats_by_service.items():
        if not all_stats:
            continue
        
        print("\n" + "="*70)
        print(f"FILTERING SUMMARY - {service.upper()}")
        print("="*70)
        
        valid_stats = [s for s in all_stats if s['has_valid_samples']]
        invalid_stats = [s for s in all_stats if not s['has_valid_samples']]
        
        print(f"\nTotal files processed: {len(all_stats)}")
        print(f"  Files with valid samples: {len(valid_stats)}")
        print(f"  Files with all zeros: {len(invalid_stats)}")
        
        if valid_stats:
            total_original = sum(s['original_count'] for s in valid_stats)
            total_filtered = sum(s['filtered_count'] for s in valid_stats)
            total_removed = sum(s['removed_count'] for s in valid_stats)
            
            print(f"\nValid files statistics:")
            print(f"  Total original samples: {total_original}")
            print(f"  Total filtered samples: {total_filtered}")
            print(f"  Total removed samples:  {total_removed} ({total_removed/total_original*100:.1f}%)")
        
        if invalid_stats:
            print(f"\n⚠ Files skipped (all zero samples):")
            for stats in invalid_stats:
                file_path = Path(stats['input_file'])
                print(f"  - {file_path.parent.parent.parent.name}/{file_path.name}")
        
        if valid_stats:
            print(f"\n✓ Valid files breakdown:")
            for stats in valid_stats:
                file_path = Path(stats['input_file'])
                exp_name = file_path.parent.parent.parent.name
                file_name = file_path.name
                print(f"  {exp_name}/{file_name:<30} → {stats['filtered_count']:>4} samples ({stats['removal_percentage']:>5.1f}% removed)")


def load_valid_files_list(list_file: str) -> List[str]:
    """
    Load the list of valid filtered files from the output file.
    
    Args:
        list_file: Path to the valid files list
    
    Returns:
        List of file paths
    """
    list_path = Path(list_file)
    
    if not list_path.exists():
        raise FileNotFoundError(f"Valid files list not found: {list_file}")
    
    with open(list_path, 'r') as f:
        files = [line.strip() for line in f if line.strip()]
    
    print(f"Loaded {len(files)} valid file paths from: {list_path}")
    return files


def extract_response_times(samples: List[Dict], perc='p90_ns') -> np.ndarray:
    """Extract response times from samples."""
    response_times = []
    for sample in samples:
        timing = sample.get('timing_window', {})
        total_time = timing.get('processing_time', {}).get(perc, 0)
        response_time_ms = total_time / 1_000_000 if total_time > 0 else 0
        response_times.append(response_time_ms)
    return np.array(response_times)


def extract_perf_deltas(samples: List[Dict]) -> Dict[str, np.ndarray]:
    """
    Extract per-sample perf_deltas arrays from samples.

    Args:
        samples: List of sample dicts from the JSON data

    Returns:
        Dictionary mapping each perf counter name to a numpy array of delta values,
        one entry per sample. Samples missing a counter get a value of 0.
    """
    counter_names = set()
    for sample in samples:
        counter_names.update(sample.get('perf_deltas', {}).keys())

    deltas: Dict[str, List[float]] = {name: [] for name in counter_names}
    for sample in samples:
        perf_deltas = sample.get('perf_deltas', {})
        for name in counter_names:
            deltas[name].append(float(perf_deltas.get(name, 0)))

    return {name: np.array(vals) for name, vals in deltas.items()}


# Numeric fields inside each sample's "freq" block that we want descriptive
# stats for. "ok" and "turbo_on" are booleans/flags and are handled separately.
FREQ_NUMERIC_FIELDS = [
    'actual_freq_mhz',
    'current_max_mhz',
    'active_n',
    'freq_util_pct',
    'tsc_freq_mhz',
]


def extract_freq_samples(samples: List[Dict], only_ok: bool = True) -> List[Dict]:
    """
    Extract the raw "freq" sub-dicts from samples.

    Args:
        samples: List of sample dicts from the JSON data
        only_ok: If True (default), drop samples where freq.ok is not True.
                 Frequency readings that failed (ok=False) are typically all
                 zeros and would otherwise drag down the baseline stats.

    Returns:
        List of freq dicts (one per qualifying sample)
    """
    freq_samples = []
    for sample in samples:
        freq = sample.get('freq', {})
        if only_ok and not freq.get('ok', False):
            continue
        freq_samples.append(freq)
    return freq_samples


def compute_freq_stats_block(freq_samples: List[Dict]) -> Dict[str, Dict[str, float]]:
    """
    Compute descriptive statistics for frequency-related fields.

    Args:
        freq_samples: List of freq dicts (e.g. from extract_freq_samples)

    Returns:
        Dictionary mapping each numeric freq field to a stats block
        (mean/std/median/q25/q75/q90/q95/q99/min/max), plus a
        'turbo_on_fraction' entry giving the fraction of samples with
        turbo_on=True.
    """
    stats: Dict[str, Dict[str, float]] = {}

    for field in FREQ_NUMERIC_FIELDS:
        values = np.array([f.get(field, 0) for f in freq_samples], dtype=float)
        if len(values) == 0:
            continue
        stats[field] = {
            'mean':   float(np.mean(values)),
            'std':    float(np.std(values)),
            'median': float(np.median(values)),
            'q25':    float(np.percentile(values, 25)),
            'q75':    float(np.percentile(values, 75)),
            'q90':    float(np.percentile(values, 90)),
            'q95':    float(np.percentile(values, 95)),
            'q99':    float(np.percentile(values, 99)),
            'min':    float(np.min(values)),
            'max':    float(np.max(values)),
        }

    if freq_samples:
        turbo_on_count = sum(1 for f in freq_samples if f.get('turbo_on', False))
        stats['turbo_on_fraction'] = float(turbo_on_count / len(freq_samples))
    else:
        stats['turbo_on_fraction'] = 0.0

    return stats


def compute_baseline_stats(baseline_file: str, output_file: str, skip_first_n: int = 0):
    """
    Compute baseline statistics from no-contention experiment file.
    Computes latency stats for both p50 and p90, perf_delta stats, and
    frequency stats, all in one file.

    Args:
        baseline_file: Path to no-contention filtered JSON file
        output_file: Path to save baseline_stats.json
        skip_first_n: Number of initial samples to skip (warmup period)
    """
    baseline_path = Path(baseline_file)

    if not baseline_path.exists():
        raise FileNotFoundError(f"Baseline file not found: {baseline_file}")

    print(f"\n{'='*70}")
    print("COMPUTING BASELINE STATISTICS")
    print(f"{'='*70}")
    print(f"Baseline file: {baseline_path.name}")
    print(f"Skip first N: {skip_first_n}")

    with open(baseline_file, 'r') as f:
        data = json.load(f)

    if isinstance(data, dict) and 'samples' in data:
        samples = data['samples']
    elif isinstance(data, list):
        samples = data
    else:
        raise ValueError("Unexpected JSON format")

    # Skip warmup period
    if skip_first_n > 0 and len(samples) > skip_first_n:
        samples = samples[skip_first_n:]
        print(f"  Samples after skipping warmup: {len(samples)}")
    else:
        print(f"  Total samples: {len(samples)}")

    def compute_latency_block(response_times: np.ndarray) -> Dict:
        return {
            'mean':      float(np.mean(response_times)),
            'std':       float(np.std(response_times)),
            'median':    float(np.median(response_times)),
            'q50':       float(np.percentile(response_times, 50)),
            'q25':       float(np.percentile(response_times, 25)),
            'q75':       float(np.percentile(response_times, 75)),
            'q90':       float(np.percentile(response_times, 90)),
            'q95':       float(np.percentile(response_times, 95)),
            'q99':       float(np.percentile(response_times, 99)),
            'min':       float(np.min(response_times)),
            'max':       float(np.max(response_times)),
            'n_samples': len(response_times),
        }

    rt_p50 = extract_response_times(samples, perc='p50_ns')
    rt_p90 = extract_response_times(samples, perc='p90_ns')

    # Compute perf_delta baseline statistics
    perf_deltas = extract_perf_deltas(samples)
    perf_delta_stats: Dict[str, Dict[str, float]] = {}
    for counter_name, values in sorted(perf_deltas.items()):
        if len(values) == 0:
            continue
        perf_delta_stats[counter_name] = {
            'mean':   float(np.mean(values)),
            'std':    float(np.std(values)),
            'median': float(np.median(values)),
            'q25':    float(np.percentile(values, 25)),
            'q75':    float(np.percentile(values, 75)),
            'q90':    float(np.percentile(values, 90)),
            'q95':    float(np.percentile(values, 95)),
            'q99':    float(np.percentile(values, 99)),
            'min':    float(np.min(values)),
            'max':    float(np.max(values)),
        }

    # Compute frequency baseline statistics (only over samples with a valid
    # freq reading, i.e. freq.ok == True)
    freq_samples_ok = extract_freq_samples(samples, only_ok=True)
    freq_stats = compute_freq_stats_block(freq_samples_ok)

    baseline_stats = {
        'source_file':        str(baseline_file),
        'skip_first_n':       skip_first_n,
        'latency_p50':        compute_latency_block(rt_p50),
        'latency_p90':        compute_latency_block(rt_p90),
        'perf_delta_stats':   perf_delta_stats,
        'freq_stats':         freq_stats,
        'freq_ok_count':      len(freq_samples_ok),
        'freq_total_count':   len(samples),
    }

    # Save to file
    output_path = Path(output_file)
    with open(output_path, 'w') as f:
        json.dump(baseline_stats, f, indent=2)

    print(f"\n{'='*70}")
    print("BASELINE STATISTICS COMPUTED")
    print(f"{'='*70}")
    print(f"  [latency_p50]")
    print(f"    Mean:   {baseline_stats['latency_p50']['mean']:.4f} ms")
    print(f"    Median: {baseline_stats['latency_p50']['median']:.4f} ms")
    print(f"    Q90:    {baseline_stats['latency_p50']['q90']:.4f} ms")
    print(f"    Q95:    {baseline_stats['latency_p50']['q95']:.4f} ms")
    print(f"    Q99:    {baseline_stats['latency_p50']['q99']:.4f} ms")
    print(f"  [latency_p90]")
    print(f"    Mean:   {baseline_stats['latency_p90']['mean']:.4f} ms")
    print(f"    Median: {baseline_stats['latency_p90']['median']:.4f} ms")
    print(f"    Q90:    {baseline_stats['latency_p90']['q90']:.4f} ms")
    print(f"    Q95:    {baseline_stats['latency_p90']['q95']:.4f} ms")
    print(f"    Q99:    {baseline_stats['latency_p90']['q99']:.4f} ms")
    if perf_delta_stats:
        print(f"  [perf_delta_stats] ({len(perf_delta_stats)} counters):")
        for counter_name, cstats in perf_delta_stats.items():
            print(f"    {counter_name:<28}  mean={cstats['mean']:.2f}  std={cstats['std']:.2f}  q90={cstats['q90']:.2f}")
    print(f"  [freq_stats] (valid readings: {len(freq_samples_ok)}/{len(samples)}):")
    for field in FREQ_NUMERIC_FIELDS:
        if field in freq_stats:
            fstats = freq_stats[field]
            print(f"    {field:<20}  mean={fstats['mean']:.2f}  std={fstats['std']:.2f}  q90={fstats['q90']:.2f}")
    print(f"    {'turbo_on_fraction':<20}  {freq_stats.get('turbo_on_fraction', 0.0):.4f}")
    print(f"\n  Saved to: {output_path.absolute()}")
    print(f"{'='*70}\n")

    return baseline_stats


def compute_all_baseline_stats(base_data_path: str,
                               services: List[str] = ['search', 'profile'],
                               skip_first_n: int = 0) -> Dict[str, Dict]:
    """
    Compute baseline statistics for all services.

    Args:
        base_data_path: Path to the Data directory
        services: List of service names
        skip_first_n: Number of initial samples to skip (warmup period)

    Returns:
        Dictionary mapping service name to baseline stats
    """
    base_path = Path(base_data_path)
    all_baseline_stats = {}

    print("\n" + "="*70)
    print("COMPUTING BASELINE STATISTICS FOR ALL SERVICES")
    print("="*70)

    for service in services:
        baseline_file = base_path / "no_contention" / "raw" / "windowed" / service / "run_data_iter2_filtered.json"
        output_file = base_path / f"baseline_stats_{service}.json"

        if not baseline_file.exists():
            print(f"\n⚠ WARNING: Baseline file not found for {service}: {baseline_file}")
            print(f"  Skipping {service} baseline computation")
            continue

        try:
            stats = compute_baseline_stats(
                baseline_file=str(baseline_file),
                output_file=str(output_file),
                skip_first_n=skip_first_n,
            )
            all_baseline_stats[service] = stats
        except Exception as e:
            print(f"\n✗ Error computing baseline for {service}: {e}")

    print("\n" + "="*70)
    print("BASELINE COMPUTATION SUMMARY")
    print("="*70)
    for service in services:
        if service in all_baseline_stats:
            stats = all_baseline_stats[service]
            print(f"\n[{service.upper()}]")
            print(f"  P50 → Mean: {stats['latency_p50']['mean']:.4f} ms  Q95: {stats['latency_p50']['q95']:.4f} ms")
            print(f"  P90 → Mean: {stats['latency_p90']['mean']:.4f} ms  Q95: {stats['latency_p90']['q95']:.4f} ms")
            print(f"  File: baseline_stats_{service}.json")
            if 'perf_delta_stats' in stats and stats['perf_delta_stats']:
                print(f"  Perf delta counters recorded: {list(stats['perf_delta_stats'].keys())}")
            if 'freq_stats' in stats and stats['freq_stats']:
                freq_mean = stats['freq_stats'].get('actual_freq_mhz', {}).get('mean')
                turbo_frac = stats['freq_stats'].get('turbo_on_fraction')
                ok_count = stats.get('freq_ok_count', 0)
                total_count = stats.get('freq_total_count', 0)
                if freq_mean is not None:
                    print(f"  Freq → Mean actual_freq_mhz: {freq_mean:.2f} MHz  Turbo-on fraction: {turbo_frac:.4f}  (valid readings: {ok_count}/{total_count})")
        else:
            print(f"\n[{service.upper()}]")
            print(f"  ✗ Not computed (baseline file not found)")

    return all_baseline_stats


# Main execution
if __name__ == "__main__":

    # Configuration
    base_data_path = r"..\Data"
    services = ['search', 'profile']

    print("="*70)
    print("AUTOMATIC DATA FILTERING SCRIPT - MULTI-SERVICE")
    print("="*70)
    print(f"\nBase path: {base_data_path}")
    print(f"Services: {', '.join(services)}")
    print(f"Target files: run_data_iter[1-3].json")
    print(f"Target locations: */raw/windowed/{{{', '.join(services)}}}/")
    print(f"\nFiltering criteria:")
    print(f"  1. p50 latency must be >= 5 ms (from processed/latency_summary.txt)")
    print(f"  2. Non-2xx or 3xx responses must be <= 200 (from processed/latency_summary.txt)")
    print(f"  3. Response times must be non-zero (from JSON data)")
    print()

    try:
        # Scan and filter all experiment files for all services
        all_stats_by_service, valid_files_by_service = scan_and_filter_data_directory(
            base_path=base_data_path,
            services=services
        )

        # Print comprehensive summary
        print_summary(all_stats_by_service)

        # Compute baseline statistics for all services
        all_baseline_stats = compute_all_baseline_stats(
            base_data_path=base_data_path,
            services=services,
            skip_first_n=0
        )

        print("\n" + "="*70)
        print("DONE!")
        print("="*70)
        print(f"\nGenerated files:")
        for service in services:
            print(f"\n  [{service.upper()}]")
            print(f"    - Filtered data files: *_filtered.json (in */raw/windowed/{service}/)")
            print(f"    - Valid files list: {base_data_path}/valid_filtered_files_{service}.txt")
            if service in all_baseline_stats:
                print(f"    - Baseline stats: {base_data_path}/baseline_stats_{service}.json")

        print(f"\n  [GENERAL]")
        print(f"    - Failed experiments: {base_data_path}/failed.txt")

        print(f"\nNext steps:")
        print(f"  - Use the filtered files for labeling")
        print(f"  - Load valid files list in your script:")
        print(f"    >>> from merged_data_processing import load_valid_files_list")
        for service in services:
            print(f"    >>> {service}_files = load_valid_files_list('{base_data_path}/valid_filtered_files_{service}.txt')")

    except FileNotFoundError as e:
        print(f"\nError: {e}")
        print("\nPlease check:")
        print(f"  1. Does the directory exist? {base_data_path}")
        print(f"  2. Are there any subdirectories?")
        print(f"  3. Do they have the structure: */raw/windowed/{{search,profile}}/")
    except Exception as e:
        print(f"\nUnexpected error: {e}")
        import traceback
        traceback.print_exc()