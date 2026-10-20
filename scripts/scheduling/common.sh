#!/usr/bin/env bash
#
# Helpers for the scheduling lane's capture scripts. Sourced after lib.sh and
# use_site, never run directly.
#
# Every capture writes docs/artifacts/scheduling/<name>-<site>-<stamp>.txt.
# Times are this laptop's clock in UTC, plus the API server's own timestamps
# in events and pod conditions, which are what the timelines are read from.
#

ARTIFACTS_SCHEDULING="$REPO_ROOT/docs/artifacts/scheduling"

# start_capture <name>: from here on, everything printed also goes to the file.
start_capture() {
  local name="$1"
  STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
  OUTFILE="$ARTIFACTS_SCHEDULING/$name-$SITE-$STAMP.txt"
  mkdir -p "$ARTIFACTS_SCHEDULING"
  exec > >(perl -pe 'BEGIN { $| = 1 } s/\e\[[0-9;]*m//g' | tee "$OUTFILE") 2>&1
  echo "# $name on $SITE, $STAMP, laptop clock, UTC. git $(git -C "$REPO_ROOT" rev-parse --short HEAD)"
}

section() {
  echo
  echo "## $*   [$(date -u +%H:%M:%SZ)]"
}

# wait_for <description> <timeout seconds> <command...>: polls every 5 s.
# Returns 1 on timeout instead of exiting, so the caller decides whether a
# timeout is a failure (most steps) or the expected result (a gang that must
# stay Pending).
wait_for() {
  local what="$1" timeout="$2" start now
  shift 2
  start="$(date +%s)"
  while ! "$@" >/dev/null 2>&1; do
    now="$(date +%s)"
    if [ $((now - start)) -ge "$timeout" ]; then
      echo "timeout after ${timeout}s: $what"
      return 1
    fi
    sleep 5
  done
  echo "after $(($(date +%s) - start))s: $what"
}

# The pods of one Job, wide, with the node, phase and start time per pod.
job_pods() {
  local ns="$1" job="$2"
  kubectl_cp -n "$ns" get pods -l "job-name=$job" -o wide --sort-by=.metadata.name
}

# Counts of a Job's pods in a phase: job_phase_count <ns> <job> <phase>
job_phase_count() {
  kubectl_cp -n "$1" get pods -l "job-name=$2" --field-selector "status.phase=$3" --no-headers 2>/dev/null | wc -l | tr -d ' '
}

# Bound pods of a Job: those with a node, whatever their phase.
job_bound_count() {
  kubectl_cp -n "$1" get pods -l "job-name=$2" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' \
    | grep -c . || true
}

# Conditions for wait_for.
bound_at_least() { [ "$(job_bound_count "$1" "$2")" -ge "$3" ]; }
no_pods() { [ -z "$(kubectl_cp -n "$1" get pods -l "$2" --no-headers 2>/dev/null)" ]; }
job_complete() {
  [ "$(kubectl_cp -n "$1" get job "$2" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null)" = "True" ]
}
job_failed() {
  [ "$(kubectl_cp -n "$1" get job "$2" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null)" = "True" ]
}
job_finished() { job_complete "$1" "$2" || job_failed "$1" "$2"; }

# KAI's view: the queues' allocation and the PodGroups of the given namespaces.
kai_state() {
  echo "### queues (GPUs allocated, requested)"
  kubectl_cp get queues.scheduling.run.ai -o custom-columns='QUEUE:.metadata.name,PARENT:.spec.parentQueue,GPU_QUOTA:.spec.resources.gpu.quota,GPU_ALLOCATED:.status.allocated.nvidia\.com/gpu,GPU_REQUESTED:.status.requested.nvidia\.com/gpu,NONPREEMPTIBLE:.status.allocatedNonPreemptible.nvidia\.com/gpu'
  local ns
  for ns in "$@"; do
    echo "### podgroups in $ns"
    kubectl_cp -n "$ns" get podgroups.scheduling.run.ai -o custom-columns='PODGROUP:.metadata.name,QUEUE:.spec.queue,MIN_MEMBER:.spec.minMember,STATE:.status.schedulingState,PRIORITY:.spec.priorityClassName' 2>/dev/null || true
  done
}

# Events of the given namespaces since the capture began, oldest first, with
# the API server's timestamps.
events_since_start() {
  local ns
  for ns in "$@"; do
    echo "### events in $ns"
    kubectl_cp -n "$ns" get events --sort-by=.lastTimestamp \
      -o custom-columns='TIME:.lastTimestamp,FIRST:.firstTimestamp,COUNT:.count,TYPE:.type,REASON:.reason,OBJECT:.involvedObject.name,SOURCE:.source.component,MESSAGE:.message' \
      2>/dev/null || true
  done
}
