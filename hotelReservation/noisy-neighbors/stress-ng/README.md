# Stress-ng for Kubernetes

A simple toolkit for creating "noisy neighbor" pods in Kubernetes using stress-ng. Perfect for testing how your services handle resource contention.

## 🚀 Quick Start

1. **Build and push the Docker image:**
   ```bash
   ./build-stress-ng.sh yourusername 
   ```

2. **Update the username in helpers:**
   ```bash
   # Edit stress-ng-helpers.sh and change:
   USERNAME="yourusername"  # <- Change this to your Docker Hub username
   ```

3. **Start stress testing:**
   ```bash
   # Option 1: Use helper commands
   alias my-stressng='./stress-ng-helpers.sh'
   my-stressng cpu 4 60s

   # Option 2: Use kubectl directly
   kubectl run cpu-stress --image=yourusername/stress-ng --restart=Never -- --cpu 4 --timeout 60s
   ```

## 📁 Files

- `Dockerfile` - Builds stress-ng container
- `build-stress-ng.sh` - Builds and pushes Docker image
- `stress-ng-helpers.sh` - Convenient wrapper commands
- `README.md` - This file

## 🛠️ Helper Commands

After setting up the alias `alias my-stressng='./stress-ng-helpers.sh'`:

### Core Stress Tests

| Command | Description | Example |
|---------|-------------|---------|
| `my-stressng cpu [workers] [duration]` | CPU stress | `my-stressng cpu 4 120s` |
| `my-stressng memory [workers] [duration]` | STREAM memory bandwidth | `my-stressng memory 2 60s` |
| `my-stressng vm [workers] [size] [duration]` | Virtual memory stress | `my-stressng vm 2 1G 60s` |
| `my-stressng pagefault [workers] [duration]` | Page fault stress | `my-stressng pagefault 1 30s` |
| `my-stressng io [workers] [duration]` | I/O stress | `my-stressng io 2 60s` |
| `my-stressng network [workers] [duration]` | UDP network stress | `my-stressng network 1 45s` |

### Special Commands

| Command | Description | Example |
|---------|-------------|---------|
| `my-stressng noisy [duration]` | Combined noisy neighbor | `my-stressng noisy 300s` |
| `my-stressng noisy [duration]` | Combined noisy neighbor | `my-stressng noisy 300s` |
| `my-stressng status` | Show running stress pods | `my-stressng status` |
| `my-stressng nodes` | List available nodes | `my-stressng nodes` |
| `my-stressng cleanup` | Remove all stress pods | `my-stressng cleanup` |
| `my-stressng help` | Show help | `my-stressng help` |

## 🎯 Node Selection

The helper script now supports targeting specific nodes for deployment with automatic toleration for tainted nodes:

### Node Selection Syntax
```bash
my-stressng <command> [args...] --node <node-name>
my-stressng <command> [args...] -n <node-name>  # Short form
```

### Toleration Support
When using the `--node` parameter, the stress pods automatically include toleration for nodes tainted with:
- **Key**: `dedicated`
- **Value**: `special`
- **Effect**: `NoSchedule`

This allows stress pods to be scheduled on tainted nodes that are dedicated for specific workloads.

### Examples
```bash
# Deploy CPU stress to specific node (includes toleration)
my-stressng cpu 4 120s --node node-0

# Deploy noisy neighbor to tainted node (includes toleration)
my-stressng noisy 0 --node node-1

# Deploy VM stress to specific node using short form (includes toleration)
my-stressng vm 2 1G 60s -n node-2
```

### List Available Nodes
```bash
my-stressng nodes
```

This will show all available nodes with their status and roles.

### Working with Tainted Nodes
If you have nodes tainted using the `node-taint.sh` script (with `dedicated=special:NoSchedule`), the stress pods will automatically include the necessary toleration when using the `--node` parameter. This ensures they can be scheduled on tainted nodes that are dedicated for specific workloads.

## 📋 kubectl Examples

### Basic Stress Tests

**CPU stress - 4 workers for 2 minutes**
```bash
# Helper shorthand:
my-stressng cpu 4 120s

# Equivalent kubectl command:
kubectl run cpu-stress --image=yourusername/stress-ng --restart=Never -- --cpu 4 --timeout 120s
```

**Memory pressure - STREAM memory bandwidth**
```bash
# Helper shorthand:
my-stressng memory 2 60s

# Equivalent kubectl command:
kubectl run mem-stress --image=yourusername/stress-ng --restart=Never -- --stream 2 --timeout 60s
```

**VM stress - 2 workers with 1GB each**
```bash
# Helper shorthand:
my-stressng vm 2 1G 60s

# Equivalent kubectl command:
kubectl run vm-stress --image=yourusername/stress-ng --restart=Never -- --vm 2 --vm-bytes 1G --timeout 60s
```

**Page fault stress**
```bash
# Helper shorthand:
my-stressng pagefault 1 60s

# Equivalent kubectl command:
kubectl run page-fault --image=yourusername/stress-ng --restart=Never -- --fault 1 --timeout 60s
```

**I/O stress**
```bash
# Helper shorthand:
my-stressng io 2 60s

# Equivalent kubectl command:
kubectl run io-stress --image=yourusername/stress-ng --restart=Never -- --io 2 --timeout 60s
```

**Network stress - UDP**
```bash
# Helper shorthand:
my-stressng network 2 60s

# Equivalent kubectl command:
kubectl run network-stress --image=yourusername/stress-ng --restart=Never -- --udp 2 --timeout 60s
```

### Advanced Examples

**Combined noisy neighbor - combines multiple stressors**
```bash
# Helper shorthand:
my-stressng noisy 0  # 0 = infinite duration

# Equivalent kubectl command:
kubectl run noisy-neighbor --image=yourusername/stress-ng --restart=Never -- \
  --cpu 2 --vm 1 --vm-bytes 1G --stream 1 --io 2 --udp 1 --timeout 0
```


**With resource limits**
```bash
# Helper shorthand:
# Cannot use helper shorthand, must directly use kubectl with --limits flag

# kubectl command:
kubectl run limited-stress --image=yourusername/stress-ng --restart=Never \
  --limits="cpu=2,memory=1Gi" -- --cpu 4 --vm 1 --vm-bytes 512M --timeout 0
```

### Target Specific Nodes
```bash
# Helper shorthand:
my-stressng cpu 4 300s --node node-0
my-stressng noisy 0 --node node-1
my-stressng vm 2 1G 60s -n node-2

# Equivalent kubectl command (includes toleration for tainted nodes):
kubectl run node-stress --image=yourusername/stress-ng --restart=Never \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"node-0"},"tolerations":[{"key":"dedicated","operator":"Equal","value":"special","effect":"NoSchedule"}]}}' \
  -- --cpu 4 --timeout 300s
```

**List available nodes:**
```bash
my-stressng nodes
```

## 🧹 Cleanup
```bash
# Helper shorthand:
my-stressng cleanup

# Equivalent kubectl commands:
kubectl delete pod cpu-stress mem-stress vm-stress page-fault io-stress udp-stress noisy-neighbor heavy-load limited-stress node-stress
```

## 📊 Monitoring Impact

Watch the impact on your services:
```bash
# Monitor resource usage
kubectl top pods
kubectl top nodes

# Watch victim service's logs
kubectl logs -f victim-pod

# Monitor node metrics
kubectl describe node victim-node

# Watch in real-time
watch kubectl get pods -o wide
```

## ⚙️ Stress-ng Parameters

### Common Options
- `--cpu N` - Number of CPU workers (0 = all CPUs)
- `--vm N` - Number of VM workers
- `--vm-bytes SIZE` - Memory per VM worker (256M, 512M, 1G, 2G)
- `--stream N` - STREAM memory bandwidth workers
- `--fault N` - Page fault workers
- `--io N` - I/O workers
- `--udp N` - UDP network workers
- `--timeout TIME` - Duration (60s, 5m, 1h, 0 = infinite)

### Memory Sizes
- `256M` = 256 megabytes
- `512M` = 512 megabytes  
- `1G` = 1 gigabyte
- `2G` = 2 gigabytes
- `50%` = 50% of available memory

## 🎯 Use Cases

### Test Scenarios
1. **CPU Starvation** - High CPU load to test CPU contention
2. **Memory Pressure** - Force memory allocation to test OOM conditions
3. **I/O Bottlenecks** - Heavy disk I/O to simulate storage issues
4. **Mixed Workloads** - Combined stress to simulate realistic noisy neighbors

### Example Test Session
```bash
# Set up alias
alias my-stressng='./stress-ng-helpers.sh'

# Start background noisy neighbor
my-stressng noisy &

# Test hotelreservation application performance
# in a loop for manual curl
curl -v "http://192.168.161.9:5000/hotels?inDate=2015-04-09&outDate=2015-04-10&lat=37.7749&lon=-122.4194"
# or use load generator wrk2

# Add more specific stress
my-stressng cpu 4 120s    # CPU pressure for 2 minutes
my-stressng vm 2 1G 60s   # Memory pressure for 1 minute

# Check what's running
my-stressng status

# Clean up when done
my-stressng cleanup
```

## 🔧 Troubleshooting

### Image Build Issues
```bash
# Clean up failed builds
docker system prune -f

# Test locally first
docker build -t stress-ng-local .
docker run --rm stress-ng-local --version
```

### Permission Issues
```bash
# If pods fail to start, check:
kubectl describe pod stress-test-pod
kubectl logs stress-test-pod
```

### Resource Limits
```bash
# If stress test seems limited, check node resources:
kubectl describe node
kubectl top node
```

## 🚨 Notes

- **Set timeouts** - Avoid infinite tests time
- **Use resource limits** - Prevent complete resource exhaustion
- **Test incrementally** - Start with light loads and increase gradually

## 📚 References

- [Official stress-ng documentation](https://colinianking.github.io/stress-ng/)
- [stress-ng man page](https://manpages.ubuntu.com/manpages/focal/man1/stress-ng.1.html)
- [Kubernetes resource management](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/)