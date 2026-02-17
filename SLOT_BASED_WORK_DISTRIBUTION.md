# Slot-Based Work Distribution for BDS Data Markets

## Overview

The Powerloom lite node (`snapshotter-lite-v2`) participates in decentralized data markets by computing base snapshots for assigned data sources. Work is distributed across registered node slots using a deterministic algorithm that ensures:

- Every active pool is covered by multiple nodes each epoch
- Work assignments are verifiable by any observer
- No central coordinator is required

This document covers the work distribution logic specific to BDS (Bulk Data Snapshotter) data markets, currently deployed for Uniswap V3 on Ethereum mainnet.

## Architecture: Compute Package Integration

The lite node does **not** contain compute logic directly. Instead, it dynamically loads a compute package at container startup:

```
snapshotter-lite-v2/        (the node runtime)
  └── /app/computes/         (cloned at startup from a separate git repo)
```

### How It Works

1. **Environment variables** specify the compute repo and branch:
   ```
   SNAPSHOTTER_COMPUTE_REPO=https://github.com/powerloom/snapshotter-computes
   SNAPSHOTTER_COMPUTE_REPO_BRANCH=feat/bds_lite
   SNAPSHOTTER_COMPUTE_REPO_COMMIT=<commit_hash>
   ```

2. **`init_docker.sh`** clones the repo into `/app/computes` at container startup:
   ```bash
   git clone --depth 1 --branch $SNAPSHOTTER_COMPUTE_REPO_BRANCH $SNAPSHOTTER_COMPUTE_REPO "/app/computes"
   git fetch --depth 1 origin $SNAPSHOTTER_COMPUTE_REPO_COMMIT
   git reset --hard $SNAPSHOTTER_COMPUTE_REPO_COMMIT
   ```

3. **`projects.json`** (from config repo) specifies which module/class to load:
   ```json
   {
     "processor": {
       "module": "computes.pair_total_reserves",
       "class_name": "PairTotalReservesProcessor"
     }
   }
   ```

4. **`snapshot_worker.py`** dynamically imports and instantiates the processor:
   ```python
   module = importlib.import_module(project_config.processor.module)
   class_ = getattr(module, project_config.processor.class_name)
   ```

This design allows the same node runtime to serve different data markets by swapping the compute package.

## The Full Node Equivalent

The full node (`snapshotter-core-edge`) uses the **same compute repository** but a different branch:

| Node Type | Compute Branch | Function |
|-----------|---------------|----------|
| Lite node | `feat/bds_lite` | Computes base snapshots for one assigned pool per epoch |
| Full node | `bds_eth_uniswapv3_core_unified_cache-experimental` | Computes base snapshots for ALL pools, aggregates, caches |

The full node mounts computes via Docker volume (`./computes:/computes`) rather than cloning at startup, since it runs alongside the computes directory in its local workspace.

## Deterministic Slot Selection Algorithm

The slot selection algorithm lives in the compute package (`computes/utils/slot_selection.py`) because the assignment logic is data-market-specific.

### Parameters

| Parameter | Value | Source |
|-----------|-------|--------|
| `total_slots` | Dynamic | `getTotalNodeCount()` from ProtocolState contract (cached 30s) |
| `SLOTS_PER_EPOCH` | 1000 | Hardcoded constant |
| Epoch duration | ~12 seconds | One Ethereum mainnet block |

### Algorithm Steps

**1. Seed Generation**

For each epoch, a deterministic seed is created:
```
seed = SHA256(block_hash_bytes + epoch_id_bytes)
```
- `block_hash` is the epoch's end block hash (known to all nodes)
- `epoch_id` is the epoch number (encoded as 8 bytes, big-endian)

**2. Slot Selection (Fisher-Yates Shuffle)**

From the full set of slot IDs `[1, total_slots]`, select `min(1000, total_slots)` slots:

```
for i in range(slots_to_select):
    rand = SHA256(seed + i_bytes)
    j = i + (rand_int % (n - i))
    swap(items[i], items[j])
selected = items[:slots_to_select]
```

This is a partial Fisher-Yates shuffle using the deterministic seed, ensuring every node computes the same selection for the same epoch.

**3. Pool Assignment**

Each selected slot is assigned exactly one pool:
```
slot_hash = SHA256(seed + slot_id_bytes)
pool_index = slot_hash_int % len(active_pools)
assigned_pool = sorted_active_pools[pool_index]
```

The pool list **must be sorted** before assignment to ensure determinism across nodes.

### Selection Probability

With `total_slots = 8192` and `SLOTS_PER_EPOCH = 1000`:
- Per-epoch selection probability: `1000/8192 ≈ 12.2%`
- Expected selections per hour: `~36` (300 epochs/hour × 0.122)
- There is no guarantee of minimum selection frequency for any given slot

### Genesis Epoch (Epoch 0)

Special handling: all nodes process epoch 0, each picking one pool deterministically based on their slot ID:
```python
pool_address = random.Random(slot_id).choice(sorted_active_pools)
```

## Health Monitoring Integration

The lite node monitors slot selection outcomes to distinguish between legitimate non-selection and actual failures.

### Slot Selection Tracker

The `SlotSelectionTracker` (`snapshotter/utils/slot_selection_tracker.py`) is passed into the compute package's `compute()` method. The compute reports its selection decision:

```python
slot_tracker.report_selection(
    epoch_id=epoch_id,
    was_selected=True/False,
    slot_id=slot_id
)
```

### Failure Detection in `snapshot_worker.py`

After each epoch's processing in `process_task()`:

1. **Selected + Success**: Reset `consecutiveMissedSubmissions`, increment success counter
2. **Selected + Failure**: Increment `consecutiveMissedSubmissions`, track in `_consecutive_selection_failures`
3. **Not Selected**: No counter modification (critical: avoids false resets)

If 3 consecutive selected-but-failed epochs occur, a Telegram alert is sent.

### Safety Net in `system_event_detector.py`

A periodic check (every 2 minutes) verifies the node is processing epochs at all by reading `slot_selection_status.txt`. If no activity in 10 minutes, the node is considered stuck.

### Edge Case: Empty Compute Return After Selection

If `compute()` returns an empty list despite the slot being selected (e.g., data fetch failure within compute), `_process()` explicitly raises an exception:

```python
if not snapshots:
    selection_status = self._slot_tracker.get_last_selection()
    if selection_status and selection_status.get('was_selected') and selection_status.get('epoch_id') == msg_obj.epochId:
        raise Exception(f"Slot selected but compute returned no data")
```

This ensures all selected-but-failed cases follow the exception path consistently.

## Legacy Comparison: powervigil-mainnet Bulk Snapshotting

The legacy bulk snapshotting service (`powervigil-mainnet`) used a different work distribution model:

| Aspect | Legacy (powervigil-mainnet) | Current (snapshotter-lite-v2) |
|--------|---------------------------|-------------------------------|
| Data Market | Uniswap V2 | Uniswap V3 (BDS) |
| Work Distribution | Time-slot based (12 slots/day) | Epoch-based deterministic selection |
| Assignment | `(epoch + snapshotter + slot + day) % sources` | SHA256-based Fisher-Yates + modulo |
| Scope | Slot signs pre-built snapshots | Slot computes and submits its own snapshot |
| Coordination | Centralized processor distributor | Fully decentralized, no coordinator |
| Signing | Separate signing workers (20 instances) | Integrated into snapshot submission |

The current system eliminates the need for a central processor distributor by making the selection algorithm deterministic and verifiable by all participants.
