# NVSentinel: from a GPU fault back to service

=== "In short"

    ### The problem

    A GPU fails in the middle of a training run. Someone has to notice, take the server out
    of service, move the work, repair the server and bring it back. At 3 a.m. that someone
    should be software, not a person.

    ### Part 1 vs now

    Part 1 did this with a controller I wrote. Here NVIDIA's **NVSentinel** does it, on the
    same L4 GPU, with the same training job and the same fault (XID 79, "GPU has fallen off
    the bus"), so the two timelines compare phase by phase.

    ```mermaid
    flowchart LR
      inj["XID 79<br/>in the kernel log"] --> det["Detect<br/>log monitor"]
      det --> q["Quarantine<br/>cordon"]
      q --> d["Drain<br/>evict the job"]
      d --> r["Repair<br/>reboot the node"]
      r --> back["Return<br/>healthy again, uncordon"]
      back --> res["Training resumes<br/>from its checkpoint"]
    ```

    ### What happened

    | | Part 1 | NVSentinel |
    |---|---|---|
    | Fault to training resumed | 360.9 s | **288.8 s** |
    | Goodput (useful share of the run) | 66.4% | **73.0%** |
    | People involved | One, to approve the return | **None** |

    - **The waiting disappeared.** Part 1 spent 299 s on a safety timer I wrote and about
      40 s waiting for a person. NVSentinel detected the fault in 1.3 s and cordoned and
      drained in 1.7 s more.
    - **New work replaced it.** NVIDIA's rule for XID 79 is a reboot, which Part 1 skipped.
      The reboot (115 s) and the driver rebuild after it (123 s) are now 82% of the outage.
      On a fleet the job would restart on another server about 3 s after the fault.

    ### What I had to change

    | NVSentinel default | Why it fails here | What I set |
    |---|---|---|
    | Drain waits for jobs to finish | A training job never finishes on its own, so repair never starts | Evict immediately |
    | Circuit breaker: stop after 50% of GPU nodes cordoned | With one GPU node, the first fault trips it, and it also blocks the return | Off here; on a fleet, on with an absolute cap |
    | Reboot provider `kind` | Pretends to reboot | `generic`: a real reboot Job |
    | MongoDB images from Bitnami | amd64 only, so my laptop tests wouldn't match | Percona |

    Part 1's fault injection also needed one fix: the system log stripped the `NVRM:` tag
    from the fake line, so NVSentinel couldn't match it. Adding the node's uptime in front,
    as a real kernel line has and as NVSentinel's own tests do, fixed it.

    ### What's still not automated

    - **No hardware check before the return.** The node went back to tenants when the
      monitors said healthy, without a DCGM diagnostic. NVSentinel can run one (validation
      after repair); I left it off to measure it as shipped, and I'd turn it on for tenants.
    - **Some faults wait for a person by design:** those NVIDIA marks "contact support".
    - **NVSentinel's brain runs on the Paris CPU worker.** When that worker is off, faults
      are seen but nobody acts.

    ### In one sentence

    NVSentinel took a GPU fault to resumed training with no human in the loop, 20% faster
    than my Part 1 controller, and the time left is the reboot NVIDIA prescribes, which a
    fleet hides by moving the job elsewhere.

=== "Run evidence"

    ```mermaid
    flowchart LR
      inj["SIMULATED XID 79<br/>kernel log line"] --> sys["syslog-health-monitor<br/>reads journald every 15 s"]
      sys --> pc["platform-connectors<br/>node condition, MongoDB event"]
      pc --> fq["fault-quarantine<br/>cordon"]
      fq --> nd["node-drainer<br/>evicts through the Eviction API"]
      nd --> fr["fault-remediation<br/>XID 79 = RESTART_BM"]
      fr --> j["janitor<br/>RebootNode"]
      j --> jp["janitor-provider generic<br/>busybox Job: chroot /host reboot"]
      jp --> back["new boot ID, node Ready,<br/>healthy events, uncordon"]
    ```

    ### Setup

    - NVSentinel v1.28.0, all three stages on, values in
      [`nvsentinel-par.yaml`](https://github.com/yassineteimi/ncp-partner-onboarding/blob/main/gitops/values/readiness/nvsentinel-par.yaml).
      XID 79 maps to `RESTART_BM` in NVIDIA's XID catalog, which NVSentinel embeds.
    - Part 1's training Job, checkpoints in Garage and goodput analysis, unchanged.
    - Injection time from the L4's own clock; every later event from a recorder on the
      laptop watching the node, pods, `RebootNode` objects and GPU Operator pods, with clock
      offsets measured at the start (L4 +0.24 s, round trip 0.53 s).
    - Checked without a GPU first: chart render, server dry run (177 objects), NVSentinel's
      KIND demo, then the Paris values in KIND stage by stage. The syslog monitor, the
      labeler and a real reboot ran for the first time on the L4, and worked first time.

    ### Results, Paris L4, 21 October (UTC)

    | Time | Event |
    |---|---|
    | 17:03:23.4 | SIMULATED XID 79 written, training at step 427 (checkpoint at 400) |
    | 17:03:24.8 | `SysLogsXIDError` raised; cordoned 9 ms later; trainer evicted |
    | 17:03:34.9 | `RebootNode` created; janitor Job runs `chroot /host reboot` |
    | 17:05:29.7 | Node Ready on a new boot ID |
    | 17:07:33.0 | GPU Operator rebuilt the driver; GPU allocatable |
    | 17:08:05.3 | All monitors healthy (DCGM last); uncordoned |
    | 17:08:12.3 | Replacement pod restores checkpoint 400 (1.8 s) |
    | 17:22:14 | Job completed, 3000 steps |

    | Phase | Part 1 (s) | NVSentinel (s) | Note |
    |---|---|---|---|
    | Detection | 299.4 | 1.3 | Part 1's 5-minute lookback rule. The journal is polled every 15 s; the XID 13 test took 11.8 s |
    | Quarantine and drain | (in lookback) | 1.7 | Cordon, then eviction |
    | Remediation | ~40 | 8.4 | Part 1 waited for a person |
    | Reboot | none | 114.8 | Scaleway VM shutdown, boot, kubelet |
    | Driver | none | 123.3 | Compiled on the node after every boot in Paris |
    | Diagnostic | 6 | none | Post-remediation validation off |
    | Return | 12 | 32.3 | Waits for every monitor to report healthy |
    | Resume | 3.9 | 7.0 | Schedule and container start |
    | **Outage** | **360.9** | **288.8** | |

    ```{ .sh .terminal }
    $ make uc3-capture
    ...
      "final_step": 3000,
      "steps_kept": 3000,
      "steps_redone": 27,
      "total_s": 1267.0,
      "useful_s": 925.268,
      "redone_s": 8.298,
      "checkpoint_s": 34.791,
      "restore_s": 1.829,
      "outage_s": 287.583,
      "other_s": 9.232,
      "goodput": 0.7303,
    ```

    Full output: [uc3-goodput.json](https://github.com/yassineteimi/ncp-partner-onboarding/blob/main/docs/artifacts/readiness/uc3-goodput.json),
    phases: [uc3-phases-20261021T172243Z.json](https://github.com/yassineteimi/ncp-partner-onboarding/blob/main/docs/artifacts/readiness/uc3-phases-20261021T172243Z.json).
    Goodput counts the outage from the trainer's last step (287.6 s) plus 27 redone steps.

    ### Second detection path, and a no-action fault

    - **XID 79 through DCGM**, with no training running: `GpuAllWatch`
      (`DCGM_FR_FALLEN_OFF_BUS`), cordoned 5.7 s after injection, uncordoned 283.3 s after,
      within 6 s of the first run
      ([timeline](https://github.com/yassineteimi/ncp-partner-onboarding/blob/main/docs/artifacts/readiness/uc3-r5-dcgm-timeline-20261021T172645Z.txt)).
    - **XID 13**, which the catalog marks as no action: an event 11.8 s after injection, node
      left schedulable:

    ```{ .sh .terminal }
    $ kubectl get events -A --field-selector involvedObject.name=eu1-par-gpu-01,reason=SysLogsXIDErrorIsNotHealthy \
        -o custom-columns='TIME:.lastTimestamp,SRC:.source.component,REASON:.reason,MSG:.message'
    TIME                   SRC                     REASON                        MSG
    2026-10-21T17:00:39Z   syslog-health-monitor   SysLogsXIDErrorIsNotHealthy   ErrorCode:13 PCI:0000:01:00 GPU_UUID:GPU-2b3af644-eb7c-0ecd-2a95-1097054adffd MESSAGE=[901.52] NVRM: Xid (PCI:0000:01:00): 13, pid=0, name=inject-xid.sh, SIMULATED by scripts/readiness/inject-xid.sh, not a real fault Recommended Action=NONE;
    ```

    Full output: [uc3-xid13-smoke-20261021T170027Z.txt](https://github.com/yassineteimi/ncp-partner-onboarding/blob/main/docs/artifacts/readiness/uc3-xid13-smoke-20261021T170027Z.txt).

    ### Issues met

    - **journald strips `NVRM:` from a userspace `/dev/kmsg` write** (it becomes the syslog
      identifier), so Part 1's injection was invisible. Shown on systemd 255; fixed with an
      `[uptime]` prefix, as NVSentinel's tests do.
    - **Controller restarts before the run:** a Paris API stall at 12:07 UTC that day
      (Grafana starving etcd's disk) left 8 to 10 restarts on each controller. Counts taken
      before and after the injection show the run itself caused two, both on the rebooted L4
      ([before](https://github.com/yassineteimi/ncp-partner-onboarding/blob/main/docs/artifacts/readiness/uc3-check-20261021T170021Z.txt),
      [after](https://github.com/yassineteimi/ncp-partner-onboarding/blob/main/docs/artifacts/readiness/uc3-nvsentinel-state-20261021T172243Z.txt)).

    ### Limits

    - **Simulated:** the fault only. Every XID was written by a script; the cordon, eviction,
      reboot, driver rebuild, uncordon and resume were real ([what is simulated](simulated.md)).
    - One L4: the job could only resume on the node that failed. A real XID 79 usually kills
      the process with a CUDA error; here the trainer got a clean SIGTERM from the eviction.
    - Not exercised: `CONTACT_SUPPORT` faults, which leave the node cordoned for a person.
