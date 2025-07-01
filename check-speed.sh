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
install_if_missing bc

echo "Starting disk benchmark with $NUMBER_OF_TESTS runs per test..."
echo "Test file size: $FILE_SIZE"
echo

# Run fio test with fallback parsing
run_fio_test() {
  local fio_rw=$1
  local blocksize=$2
  local op=$3

  # Run fio and capture output
  local fio_out
  if fio_out=$(fio --name=test --filename=$TEST_FILE --size=$FILE_SIZE --direct=1 --rw=$fio_rw --bs=$blocksize --numjobs=1 --iodepth=16 --runtime=30 --time_based --group_reporting --output-format=json 2>&1); then
    # JSON parsing
    if echo "$fio_out" | grep -q '{'; then
      # Extract metrics using text processing (for compatibility with older fio versions)
      local read_metric write_metric
      if [[ "$fio_rw" == "read" || "$fio_rw" == "randread" ]]; then
        read_metric=$(echo "$fio_out" | grep -A1 '"read" :' | grep -E 'bw \([0-9]' | awk -F '[,=]' '{print $3}' | grep -oE '[0-9.]+')
        iops=$(echo "$fio_out" | grep -A1 '"read" :' | grep -E 'iops' | awk -F '[,=]' '{print $3}' | grep -oE '[0-9.]+')
      else
        write_metric=$(echo "$fio_out" | grep -A1 '"write" :' | grep -E 'bw \([0-9]' | awk -F '[,=]' '{print $3}' | grep -oE '[0-9.]+')
        iops=$(echo "$fio_out" | grep -A1 '"write" :' | grep -E 'iops' | awk -F '[,=]' '{print $3}' | grep -oE '[0-9.]+')
      fi
      
      # Determine the bandwidth value to use
      local bw_val
      if [[ -n "$read_metric" ]]; then
        bw_val=$read_metric
      else
        bw_val=$write_metric
      fi
      
      # Convert bw to MB/s
      local bw_unit=$(echo "$fio_out" | grep 'bw (' | awk '{print $2}' | tr -d ')')
      if [[ "$bw_unit" == "KiB/s" ]]; then
        mbps=$(echo "scale=2; $bw_val / 1024" | bc)
      else  # Assume MiB/s
        mbps=$bw_val
      fi
      
      # Get latency (skip if not available)
      lat_ms=0
    else
      # Fallback to text parsing
      parse_text_output "$fio_out" "$fio_rw"
    fi
  else
    # Fallback to text parsing
    parse_text_output "$fio_out" "$fio_rw"
  fi

  echo "$mbps $iops $lat_ms"
}

# Parse fio text output
parse_text_output() {
  local fio_out="$1"
  local fio_rw="$2"
  
  # Find relevant line
  local bw_line
  if [[ "$fio_rw" == "read" || "$fio_rw" == "randread" ]]; then
    bw_line=$(echo "$fio_out" | grep -m1 "read:")
  else
    bw_line=$(echo "$fio_out" | grep -m1 "write:")
  fi

  # Extract bandwidth
  if [[ $bw_line =~ [bB][wW]=([0-9.]+)([KkMm]) ]]; then
    local bw_val=${BASH_REMATCH[1]}
    local unit=${BASH_REMATCH[2],,}  # Convert to lowercase
    
    if [[ "$unit" == "k" ]]; then
      mbps=$(echo "scale=2; $bw_val / 1024" | bc)
    else
      mbps=$bw_val
    fi
  else
    mbps=0
  fi

  # Extract IOPS
  if [[ $bw_line =~ [iI][oO][pP][sS]=([0-9]+) ]]; then
    iops=${BASH_REMATCH[1]}
  else
    iops=0
  fi

  # Latency not available in text mode
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

# Create test file if needed
if [[ ! -f "$TEST_FILE" ]]; then
  echo "Creating test file..."
  touch "$TEST_FILE"
fi

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
  echo "Test file: $TEST_FILE ($FILE_SIZE)"
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
