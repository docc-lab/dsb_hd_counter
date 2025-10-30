import subprocess
import os
import re
import platform
class BaseMetadata:
    """
    BaseMetadata collects system hardware and software metadata for profiling environments.
    This class is used to gather detailed information about the host system where profiling
    is performed. The collected metadata includes:
    - GPU details (name, driver version, memory size)
    - CPU architecture information via `lscpu`
    - Cache hierarchy from sysfs
    - DRAM size from `/proc/meminfo`
    - Software environment details such as:
        * OS and kernel version
        * Compiler versions (AOCC, GCC, Clang)
        * BIOS/Firmware version (via `dmidecode`)
        * Filesystem type of root partition
        * Power management policy (e.g., CPU frequency governor)
    Methods
    -------
    as_dict() : dict
        Returns the full system metadata as a dictionary.
    gpu_info() : dict
        Returns GPU-specific fields.
    cpu_info() : dict
        Returns parsed output of `lscpu`.
    cache_info() : dict
        Returns dictionary of L1d, L1i, L2, L3 cache sizes.
    dram_info() : dict
        Returns total physical memory (DRAM) in MB.
    Usage
    -----
    metadata = BaseMetadata()
    print(metadata.as_dict())
    Notes
    -----
    This class assumes a Linux environment with tools like `lscpu`, `df`, and optionally
    `dmidecode` for firmware data. Error handling is included to ensure graceful degradation
    if any tools or files are missing.
    """
    def __init__(self):
        self.gpu_name = None
        self.driver_version = None
        self.memory_size = None  # in MB
        self.cpu_info_data = {}
        self.cache_info_data = {}
        self.dram_size_MB = None
        self.software_info_data = {}
        self._collect()
    def _collect(self):
        self._collect_gpu_info()
        self._collect_cpu_info()
        self._collect_cache_info()
        self._collect_dram_size()
        self._collect_software_info()
    # New method
    def _collect_software_info(self):
        try:
            self.software_info_data["OS"] = f"{platform.system()} {platform.release()} ({platform.version()})"
            self.software_info_data["Kernel"] = platform.uname().release
            # Compiler info (try AOCC, gcc, clang)
            for compiler in ["aocc", "gcc", "clang"]:
                try:
                    version = subprocess.check_output([compiler, "--version"], stderr=subprocess.DEVNULL, text=True).splitlines()[0]
                    self.software_info_data[f"{compiler}_version"] = version
                except FileNotFoundError:
                    self.software_info_data[f"{compiler}_version"] = "Not Installed"
            # BIOS/Firmware info (Linux dmidecode required)
            try:
                bios_version = subprocess.check_output(["dmidecode", "-s", "bios-version"], text=True).strip()
                bios_date = subprocess.check_output(["dmidecode", "-s", "bios-release-date"], text=True).strip()
                self.software_info_data["BIOS"] = f"{bios_version} ({bios_date})"
            except Exception:
                self.software_info_data["BIOS"] = "Unavailable"
            # Filesystem info
            fs_info = subprocess.check_output(["df", "-T", "/"], text=True).splitlines()[1]
            self.software_info_data["FileSystem"] = fs_info.split()[1]
            # Power Management Policy (CPU governor)
            try:
                with open("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor") as f:
                    self.software_info_data["PowerPolicy"] = f.read().strip()
            except FileNotFoundError:
                self.software_info_data["PowerPolicy"] = "Unavailable"
        except Exception as e:
            self.software_info_data = {"Error": str(e)}
    def _collect_gpu_info(self):
        try:
            smi_output = subprocess.check_output(
                ["nvidia-smi", "--query-gpu=name,driver_version,memory.total", "--format=csv,noheader,nounits"],
                text=True
            )
            parts = smi_output.strip().split(", ")
            if len(parts) >= 3:
                self.gpu_name = parts[0]
                self.driver_version = parts[1]
                self.memory_size = int(parts[2])
        except Exception as e:
            self.gpu_name = self.driver_version = self.memory_size = f"Error: {e}"
    def _collect_cpu_info(self):
        try:
            cpu_output = subprocess.check_output(["lscpu"], text=True)
            for line in cpu_output.strip().split("\n"):
                if ":" in line:
                    key, value = [x.strip() for x in line.split(":", 1)]
                    self.cpu_info_data[key] = value
        except Exception as e:
            self.cpu_info_data = f"Error: {e}"
    def _collect_cache_info(self):
        try:
            cache_sizes = {"L1d": None, "L1i": None, "L2": None, "L3": None}
            cpu_cache_base = "/sys/devices/system/cpu/cpu0/cache"
            for index in os.listdir(cpu_cache_base):
                index_path = os.path.join(cpu_cache_base, index)
                try:
                    with open(os.path.join(index_path, "level")) as f:
                        level = f.read().strip()
                    with open(os.path.join(index_path, "type")) as f:
                        ctype = f.read().strip()
                    with open(os.path.join(index_path, "size")) as f:
                        size = f.read().strip()
                    if level == "1":
                        if ctype == "Data":
                            cache_sizes["L1d"] = size
                        elif ctype == "Instruction":
                            cache_sizes["L1i"] = size
                    elif level == "2":
                        cache_sizes["L2"] = size
                    elif level == "3":
                        cache_sizes["L3"] = size
                except Exception:
                    continue
            self.cache_info_data = cache_sizes
        except Exception as e:
            self.cache_info_data = f"Error: {e}"
    def _collect_dram_size(self):
        try:
            with open("/proc/meminfo") as f:
                for line in f:
                    if line.startswith("MemTotal"):
                        mem_kb = int(re.findall(r'\d+', line)[0])
                        self.dram_size_MB = mem_kb // 1024
                        break
        except Exception as e:
            self.dram_size_MB = f"Error: {e}"
    def gpu_info(self):
        return {
            "gpu_name": self.gpu_name,
            "driver_version": self.driver_version,
            "gpu_memory_MB": self.memory_size
        }
    def cpu_info(self):
        return self.cpu_info_data
    def cache_info(self):
        return self.cache_info_data
    def dram_info(self):
        return {"dram_size_MB": self.dram_size_MB}
    def as_dict(self):
        return {
            **self.gpu_info(),
            "cpu_info": self.cpu_info_data,
            "cpu_cache": self.cache_info_data,
            "dram_size_MB": self.dram_size_MB,
            "software_info": self.software_info_data
        }
    def __repr__(self):
        return (f"BaseMetadata(\n"
                f"  GPU: {self.gpu_name} ({self.memory_size} MB), Driver: {self.driver_version}\n"
                f"  CPU: {self.cpu_info_data.get('Model name', 'Unknown')}\n"
                f"  DRAM: {self.dram_size_MB} MB\n"
                f"  Cache: {self.cache_info_data}\n"
                f"  Software: {self.software_info_data}\n)")
