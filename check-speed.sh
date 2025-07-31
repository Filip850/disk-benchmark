#!/bin/bash

set -e

# Defaults
NUMBER_OF_TESTS=3
FILE_SIZE=1G
TEST_FILE="fio_testfile"  # Created in the current working directory
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
install_if_missing bc

echo "Starting disk benchmark with $NUMBER_OF_TESTS runs per test..."
echo "Test file size: $FILE_SIZE"
echo "Test file location: $TEST_FILE (in current directory: $(pwd))"
echo

# Run fio test with text parsing
run_fio_test() {
  local fio_rw=$1
  local blocksize=$2
  local op=$3

  # Run fio and capture output
  local fio_out
  fio_out=$(fio --name=test --filename=$TEST_FILE --size=$FILE_SIZE --direct=1 --rw=$fio_rw --bs=$blocksize \
              --numjobs=8 --iodepth=64 --runtime=30 --time_based --group_reporting --output-format=normal 2>&1)

  # Parse output
  parse_text_output "$fio_out" "$fio_rw"

  echo "$mbps $iops $lat_ms"
}

# Parse fio text output
parse_text_output() {
  local fio_out="$1"
  local fio_rw="$2"
  
  # Find aggregate bandwidth line
  local bw_line
  bw_line=$(echo "$fio_out" | grep -i -m1 "agg.*bw=")
  
  # Fallback to any bw= line if aggregate not found
  if [ -z "$bw_line" ]; then
    bw_line=$(echo "$fio_out" | grep -i -m1 "bw=")
  fi

  # Extract bandwidth value and unit
  if [[ $bw_line =~ [bB][wW]=([0-9.]+)([KkMm]?i?B?)/s ]]; then
    local bw_val=${BASH_REMATCH[1]}
    local unit=$(echo "${BASH_REMATCH[2]}" | tr '[:upper:]' '[:lower:]')
    
    # Convert to MB/s
    if [[ "$unit" =~ k ]]; then
      mbps=$(echo "scale=2; $bw_val / 1024" | bc)
    elif [[ "$unit" =~ m ]]; then
      mbps=$bw_val
    else
      # Default to MB/s if no unit matched
      mbps=$bw_val
    fi
  else
    mbps=0
  fi

  # Not used in final report but kept for structure
  iops=0
  lat_ms=0
}

# Statistics helpers
mean() {
  awk '{ total += $1; count++ } END { if (count > 0) print total/count; else print 0 }'
}

stddev() {
  awk '{ sum += $1; sumsq += ($1)^2; count++ }
       END { if (count > 0) { mean = sum/count; print sqrt(sumsq/count - mean^2) } else print 0 }'
}

# Create test file with random data in the current directory
echo "Creating test file with random data in $(pwd)..."
if [ -f "$TEST_FILE" ]; then
  rm -f "$TEST_FILE"
fi

# Preallocate test file
fio --name=init --filename="$TEST_FILE" --size="$FILE_SIZE" --rw=write --bs=1M \
    --direct=1 --numjobs=1 --iodepth=16 --end_fsync=1 --output-format=normal >/dev/null

echo "Running tests, please wait..."

declare -a results_read_seq results_write_seq
declare -a results_read_rand results_write_rand

for ((run=1; run<=NUMBER_OF_TESTS; run++)); do
  echo "Run #$run..."

  # Sequential 1M read
  result=($(run_fio_test read 1M read))
  results_read_seq+=("${result[0]}")

  # Sequential 1M write
  result=($(run_fio_test write 1M write))
  results_write_seq+=("${result[0]}")

  # Random 4K read
  result=($(run_fio_test randread 4K read))
  results_read_rand+=("${result[0]}")

  # Random 4K write
  result=($(run_fio_test randwrite 4K write))
  results_write_rand+=("${result[0]}")
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

# Log results
{
  echo "Disk Benchmark Report - $(date)"
  echo "Test file: $TEST_FILE (in $(pwd))"
  echo "Test file size: $FILE_SIZE"
  echo "Number of test runs: $NUMBER_OF_TESTS"
  echo
  printf "%-20s %-15s %-15s\n" "Test" "Read MB/s ± stddev" "Write MB/s ± stddev"
  printf "%-20s %-15s %-15s\n" "Sequential 1M" \
    "$(printf '%.2f ± %.2f' "$avg_read_seq" "$std_read_seq")" \
    "$(printf '%.2f ± %.2f' "$avg_write_seq" "$std_write_seq")"
  printf "%-20s %-15s %-15s\n" "Random 4K" \
    "$(printf '%.2f ± %.2f' "$avg_read_rand" "$std_read_rand")" \
    "$(printf '%.2f ± %.2f' "$avg_write_rand" "$std_write_rand")"
  echo
  echo "Raw results:"
  echo "Sequential Read: ${results_read_seq[*]}"
  echo "Sequential Write: ${results_write_seq[*]}"
  echo "Random Read: ${results_read_rand[*]}"
  echo "Random Write: ${results_write_rand[*]}"
} | tee "$LOG_FILE"

# Cleanup
rm -f "$TEST_FILE"

echo
echo "Benchmark finished. Results saved to $LOG_FILE"
