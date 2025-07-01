#!/bin/bash

set -e

# Defaults
NUMBER_OF_TESTS=3
FILE_SIZE=1G
TEST_FILE="/tmp/fio_testfile"
LOG_DIR="./"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_FILE="$LOG_DIR/disk_benchmark_$TIMESTAMP.log"

# Parse --number-of-test argument
for arg in "$@"; do
  if [[ "$arg" =~ ^--number-of-test=([0-9]+)$ ]]; then
    NUMBER_OF_TESTS="${BASH_REMATCH[1]}"
  fi
done

# Install dependencies if missing
install_if_missing() {
  local pkg=$1
  if ! command -v "$pkg" &>/dev/null; then
    echo "Installing $pkg..."
    sudo apt-get update
    sudo apt-get install -y "$pkg"
  fi
}

install_if_missing fio
install_if_missing jq
install_if_missing bc

echo "Starting disk benchmark with $NUMBER_OF_TESTS runs per test..."
echo "Test file size: $FILE_SIZE"
echo

# Run fio test with fallback parsing
run_fio_test() {
  local fio_rw=$1
  local blocksize=$2
  local op=$3

  local fio_out
  if ! fio_out=$(fio --name=test --filename=$TEST_FILE --size=$FILE_SIZE --direct=1 --rw=$fio_rw --bs=$blocksize --numjobs=1 --iodepth=16 --runtime=30 --time_based --group_reporting --output-format=json 2>/dev/null); then
    echo "fio JSON output failed for $fio_rw $blocksize, falling back to text mode..."
    fio_out=$(fio --name=test --filename=$TEST_FILE --size=$FILE_SIZE --direct=1 --rw=$fio_rw --bs=$blocksize --numjobs=1 --iodepth=16 --runtime=30 --time_based --group_reporting 2>/dev/null)

    local bw_line
    if [[ "$fio_rw" == "read" || "$fio_rw" == "randread" ]]; then
      bw_line=$(echo "$fio_out" | grep -m1 "read:")
    else
      bw_line=$(echo "$fio_out" | grep -m1 "write:")
    fi

    local bw_kb=$(echo "$bw_line" | grep -oP 'bw=\K[0-9]+')
    if [[ -z "$bw_kb" ]]; then bw_kb=0; fi
    local mbps=$(echo "scale=2; $bw_kb / 1024" | bc)
    local iops=$(echo "$bw_line" | grep -oP 'iops=\K[0-9]+' || echo 0)
    local lat_ms=0

    echo "$mbps $iops $lat_ms"
    return
  fi

  if command -v jq &>/dev/null; then
    local mbps=$(echo "$fio_out" | jq -r ".jobs[0].$op.bw")
    local iops=$(echo "$fio_out" | jq -r ".jobs[0].$op.iops")
    local lat_ns=$(echo "$fio_out" | jq -r ".jobs[0].$op.lat_ns.mean")
    mbps=$(echo "scale=2; $mbps / 1024" | bc)
    lat_ms=$(echo "scale=3; $lat_ns / 1000000" | bc)
    echo "$mbps $iops $lat_ms"
  else
    echo "0 0 0"
  fi
}

# Statistics helpers
mean() {
  awk '{ total += $1; count++ } END { print total/count }'
}
stddev() {
  awk '{ sum += $1; sumsq += ($1)^2; count++ }
       END { mean = sum/count; print sqrt(sumsq/count - mean^2) }'
}

echo "Running tests, please wait..."

declare -A results_read_seq results_write_seq results_iops_seq results_lat_seq
declare -A results_read_rand results_write_rand results_iops_rand results_lat_rand

for ((run=1; run<=NUMBER_OF_TESTS; run++)); do
  echo "Run #$run..."

  # Sequential 1M read
  read_mb iops lat_ms=$(run_fio_test read 1M read)
  read_mb=$(echo $read_mb)
  iops=$(echo $iops)
  lat_ms=$(echo $lat_ms)
  results_read_seq[$run]=$read_mb
  results_iops_seq[$run]=$iops
  results_lat_seq[$run]=$lat_ms

  # Sequential 1M write
  read_mb iops lat_ms=$(run_fio_test write 1M write)
  read_mb=$(echo $read_mb)
  iops=$(echo $iops)
  lat_ms=$(echo $lat_ms)
  results_write_seq[$run]=$read_mb
  results_iops_seq[$((run + NUMBER_OF_TESTS))]=$iops # separate iops for write seq after read seq, no mixing
  results_lat_seq[$((run + NUMBER_OF_TESTS))]=$lat_ms

  # Random 4K read
  read_mb iops lat_ms=$(run_fio_test randread 4K read)
  read_mb=$(echo $read_mb)
  iops=$(echo $iops)
  lat_ms=$(echo $lat_ms)
  results_read_rand[$run]=$read_mb
  results_iops_rand[$run]=$iops
  results_lat_rand[$run]=$lat_ms

  # Random 4K write
  read_mb iops lat_ms=$(run_fio_test randwrite 4K write)
  read_mb=$(echo $read_mb)
  iops=$(echo $iops)
  lat_ms=$(echo $lat_ms)
  results_write_rand[$run]=$read_mb
  results_iops_rand[$run]=$iops
  results_lat_rand[$run]=$lat_ms

done

# Compute averages and stddev
avg_read_seq=$(printf "%s\n" "${results_read_seq[@]}" | mean)
std_read_seq=$(printf "%s\n" "${results_read_seq[@]}" | stddev)
avg_write_seq=$(printf "%s\n" "${results_write_seq[@]}" | mean)
std_write_seq=$(printf "%s\n" "${results_write_seq[@]}" | stddev)
avg_read_rand=$(printf "%s\n" "${results_read_rand[@]}" | mean)
std_read_rand=$(printf "%s\n" "${results_read_rand[@]}" | stddev)
avg_write_rand=$(printf "%s\n" "${results_write_rand[@]}" | mean)
std_write_rand=$(printf "%s\n" "${results_write_rand[@]}" | stddev)

# Log header
{
  echo "Disk Benchmark Report - $(date)"
  echo "Test file: $TEST_FILE ($FILE_SIZE)"
  echo
  printf "%-20s %-15s %-15s\n" "Test" "Read MB/s ± stddev" "Write MB/s ± stddev"
  printf "%-20s %-15s %-15s\n" "Sequential 1M" \
    "$(printf '%.2f ± %.2f' "$avg_read_seq" "$std_read_seq")" \
    "$(printf '%.2f ± %.2f' "$avg_write_seq" "$std_write_seq")"
  printf "%-20s %-15s %-15s\n" "Random 4K" \
    "$(printf '%.2f ± %.2f' "$avg_read_rand" "$std_read_rand")" \
    "$(printf '%.2f ± %.2f' "$avg_write_rand" "$std_write_rand")"
} | tee "$LOG_FILE"

# Cleanup
rm -f $TEST_FILE

echo
echo "Benchmark finished. Results saved to $LOG_FILE"
