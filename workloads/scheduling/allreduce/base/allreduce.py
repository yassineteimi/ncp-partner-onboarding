"""All-reduce bandwidth between the pods of one KAI gang (use case 4).

Each pod of an Indexed Job runs this once. Rank 0's pod is the rendezvous
point. NVCRE measures all-reduce inside one pod that sees both GPUs; this
measures it across two pods, one GPU each, which is what a tenant gets when
KAI places a two-pod gang on one node. NCCL_DEBUG=INFO in the pod spec makes
NCCL print the transport it picked (P2P, SHM or NET), the part of the
comparison that matters.

Bus bandwidth uses the nccl-tests convention for all-reduce:
busbw = algbw * 2 * (n - 1) / n, with algbw = bytes / time.

Environment:
  RANK            the pod's index (JOB_COMPLETION_INDEX)
  WORLD_SIZE      number of pods in the gang
  MASTER_ADDR     rank 0's address, MASTER_PORT its port
  BACKEND         nccl (GPU, default) or gloo (CPU, for the free check)
  MAX_BYTES       largest message, default 1 GiB on nccl, 64 MiB on gloo
  ITERS           timed iterations per size, default 20
"""

import json
import os
import socket
import sys
import time
from datetime import timedelta

import torch
import torch.distributed as dist


def env_int(name, default):
    value = os.environ.get(name)
    return int(value) if value else default


def sizes(max_bytes):
    # 1 MiB, then doubling, up to max_bytes.
    size = 1 << 20
    while size <= max_bytes:
        yield size
        size *= 2


def main():
    backend = os.environ.get("BACKEND", "nccl")
    rank = int(os.environ["RANK"])
    world = int(os.environ["WORLD_SIZE"])
    iters = env_int("ITERS", 20)
    max_bytes = env_int("MAX_BYTES", (1 << 30) if backend == "nccl" else (64 << 20))

    if backend == "nccl":
        if not torch.cuda.is_available():
            sys.exit("BACKEND=nccl but CUDA is not available")
        device = torch.device("cuda", 0)
        torch.cuda.set_device(device)
        device_name = torch.cuda.get_device_name(device)
        nccl_version = ".".join(str(v) for v in torch.cuda.nccl.version())
    else:
        device = torch.device("cpu")
        device_name = "cpu"
        nccl_version = None

    print(
        f"rank {rank}/{world} host {socket.gethostname()} backend {backend} "
        f"device {device_name} torch {torch.__version__} nccl {nccl_version} "
        f"CUDA_VISIBLE_DEVICES={os.environ.get('CUDA_VISIBLE_DEVICES')}",
        flush=True,
    )

    started = time.time()
    dist.init_process_group(backend, rank=rank, world_size=world, timeout=timedelta(minutes=5))
    print(f"rank {rank}: process group up in {time.time() - started:.1f} s", flush=True)

    # Correctness first: every rank contributes 1, so every element must be world.
    check = torch.ones(1024, device=device)
    dist.all_reduce(check)
    if not torch.all(check == world):
        sys.exit(f"rank {rank}: all-reduce returned {check[0].item()}, expected {world}")

    results = []
    for nbytes in sizes(max_bytes):
        tensor = torch.ones(nbytes // 4, dtype=torch.float32, device=device)
        for _ in range(5):
            dist.all_reduce(tensor)
        sync(device)
        dist.barrier()
        start = time.perf_counter()
        for _ in range(iters):
            dist.all_reduce(tensor)
        sync(device)
        seconds = (time.perf_counter() - start) / iters
        algbw = nbytes / seconds / 1e9
        busbw = algbw * 2 * (world - 1) / world
        results.append({"bytes": nbytes, "time_us": round(seconds * 1e6, 1),
                        "algbw_GBps": round(algbw, 2), "busbw_GBps": round(busbw, 2)})
        if rank == 0:
            print(f"{nbytes:>12} B  {seconds * 1e6:>10.1f} us  algbw {algbw:8.2f} GB/s  "
                  f"busbw {busbw:8.2f} GB/s", flush=True)

    if rank == 0:
        summary = {
            "backend": backend,
            "world_size": world,
            "device": device_name,
            "torch": torch.__version__,
            "nccl": nccl_version,
            "iters": iters,
            "peak_busbw_GBps": max(r["busbw_GBps"] for r in results),
            "results": results,
        }
        print("RESULT " + json.dumps(summary), flush=True)

    dist.destroy_process_group()


def sync(device):
    if device.type == "cuda":
        torch.cuda.synchronize(device)


if __name__ == "__main__":
    main()
