#!/bin/bash

set -e

# Default number of tests
NUMBER_OF_TESTS=3

usage() {
  echo "Usage: $0 [--number-of-tests N]"
  exit 1
}

# Parse argument
while [[ $# -gt 0 ]]; do
  case "$1" in
    --number-of-tests)
      shift
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        NUMBER_OF_TESTS=$1
      else
        echo "Error: --number-of-tests requires a positive integer"
        exit 1
      fi
      shift
      ;;
    *)
      usage
      ;;
  esac
done

# Check and install dependencies
for cmd in fio bc awk; do
  if ! command -v $cmd &>/dev/null; then
    echo "Installing missing dependency: $cmd"
    if command -v apt-get &>/dev/null; then
      sudo apt-get update && sudo apt-get install -y $cmd
    elif command -v yum &>/dev/null; then
      sudo yum install -y $cmd
    else
      echo "Unsupported package manager. Please install $cmd manually."
      exit 1
    fi
  fi
done

TEST_FILE="/tmp/fio_testfile"
FILE_SIZE="1G"
DATE_STR=$(date +"%Y-%m-%d_%H-%M-%S")
LOGFILE="disk_benchmark_${DATE_STR}.log"

# Functions to calculate average and std dev from array
calc_avg() {
  local arr=("$@")
  local sum=0
  for val in "${arr[@]}"; do
    sum=$(echo "$sum + $val" | bc)
  done
  echo "scale=2; $sum / ${#arr[@]}" | bc
}

calc_stddev() {
  local arr=("$@")
  local avg=$(calc_avg "${arr[@]}")
  local sumsq=0
  for val in "${arr[@]}"; do
    diff=$(echo "$val - $avg" | bc -l)
    sq=$(echo "$diff * $diff" | bc -l)
    sumsq=$(echo "$sumsq + $sq" | bc -l)
  done
  local variance=$(echo "$sumsq / ${#arr[@]}" | bc -l)
  # sqrt using awk
  awk "BEGIN {print sqrt($variance)}"
}

format_result() {
  local arr=("$@")
  local avg=$(calc_avg "${arr[@]}")
  local stddev=$(calc_stddev "${arr[@]}")
  printf "%.2f ± %.2f" "$avg" "$stddev"
}

# Wrapper to run fio test and parse output
run_fio_test() {
  local name=$1
  local fio_params=$2

  # Run fio, get JSON output
  local fio_out=$(fio --name=test --filename=$TEST_FILE --size=$FILE_SIZE --direct=1 --rw=$fio_params --bs=$3 --numjobs=1 --iodepth=16 --runtime=30 --time_based --group_reporting --output-format=json)

  # Parse MB/s, IOPS, lat mean (ms) from JSON using awk
  # For read/write we parse "read" or "write"
  local op=$4

  local mbps=$(echo "$fio_out" | awk -v op=$op '
    /"bw_agg"/ {bw_agg=1}
    /"bw":/ && bw_agg {
      gsub(/[^0-9]/,"",$0);
      if ($0 ~ op) {print $0; exit}
    }
  ')

  # We will do more precise parsing using jq if available, fallback to awk:

  if command -v jq &>/dev/null; then
    mbps=$(echo "$fio_out" | jq -r ".jobs[0].$op.bw" )
    iops=$(echo "$fio_out" | jq -r ".jobs[0].$op.iops" )
    lat_ns=$(echo "$fio_out" | jq -r ".jobs[0].$op.lat_ns.mean" )
    # Convert bytes/s to MB/s (bw is KB/s in fio output)
    # Actually fio bw is in KB/s
    mbps=$(echo "scale=2; $mbps / 1024" | bc)
    lat_ms=$(echo "scale=3; $lat_ns / 1000000" | bc)
  else
    # No jq installed, do fallback parsing with awk for bw, iops, lat_ns
    mbps="N/A"
    iops="N/A"
    lat_ms="N/A"
  fi

  echo "$mbps $iops $lat_ms"
}

# Storage arrays for results
SEQ_READ_MB=()
SEQ_READ_IOPS=()
SEQ_READ_LAT=()

SEQ_WRITE_MB=()
SEQ_WRITE_IOPS=()
SEQ_WRITE_LAT=()

RAND_READ_MB=()
RAND_READ_IOPS=()
RAND_READ_LAT=()

RAND_WRITE_MB=()
RAND_WRITE_IOPS=()
RAND_WRITE_LAT=()

echo "Starting disk benchmark with $NUMBER_OF_TESTS runs per test..."
echo "Test file size: $FILE_SIZE"
echo ""

for ((i=1; i<=NUMBER_OF_TESTS; i++)); do
  echo "Run #$i..."

  # Sequential 1M Read
  read_mb read_iops read_lat=$(run_fio_test "Seq Read" "read" "1M" "read")
  SEQ_READ_MB+=($read_mb)
  SEQ_READ_IOPS+=($read_iops)
  SEQ_READ_LAT+=($read_lat)

  # Sequential 1M Write
  write_mb write_iops write_lat=$(run_fio_test "Seq Write" "write" "1M" "write")
  SEQ_WRITE_MB+=($write_mb)
  SEQ_WRITE_IOPS+=($write_iops)
  SEQ_WRITE_LAT+=($write_lat)

  # Random 4K Read
  rand_read_mb rand_read_iops rand_read_lat=$(run_fio_test "Rand Read" "randread" "4k" "read")
  RAND_READ_MB+=($rand_read_mb)
  RAND_READ_IOPS+=($rand_read_iops)
  RAND_READ_LAT+=($rand_read_lat)

  # Random 4K Write
  rand_write_mb rand_write_iops rand_write_lat=$(run_fio_test "Rand Write" "randwrite" "4k" "write")
  RAND_WRITE_MB+=($rand_write_mb)
  RAND_WRITE_IOPS+=($rand_write_iops)
  RAND_WRITE_LAT+=($rand_write_lat)

  echo ""
done

# Print header and rows in table format

print_line() {
  printf "+----------------------+-----------------+-----------------+-----------------+\n"
}

print_header() {
  print_line
  printf "| %-20s | %-15s | %-15s | %-15s |\n" "Test" "MB/s" "IOPS" "Avg Lat (ms)"
  print_line
}

print_row() {
  local test="$1"
  local mbps="$2"
  local iops="$3"
  local lat="$4"
  printf "| %-20s | %-15s | %-15s | %-15s |\n" "$test" "$mbps" "$iops" "$lat"
}

{
echo "Disk Benchmark Report - $(date)"
echo "Test file: $TEST_FILE ($FILE_SIZE)"
echo ""
print_header
print_row "Sequential 1M Read" "$(format_result "${SEQ_READ_MB[@]}")" "$(format_result "${SEQ_READ_IOPS[@]}")" "$(format_result "${SEQ_READ_LAT[@]}")"
print_row "Sequential 1M Write" "$(format_result "${SEQ_WRITE_MB[@]}")" "$(format_result "${SEQ_WRITE_IOPS[@]}")" "$(format_result "${SEQ_WRITE_LAT[@]}")"
print_row "Random 4K Read" "$(format_result "${RAND_READ_MB[@]}")" "$(format_result "${RAND_READ_IOPS[@]}")" "$(format_result "${RAND_READ_LAT[@]}")"
print_row "Random 4K Write" "$(format_result "${RAND_WRITE_MB[@]}")" "$(format_result "${RAND_WRITE_IOPS[@]}")" "$(format_result "${RAND_WRITE_LAT[@]}")"
print_line
echo ""
echo "Results saved to $LOGFILE"
} | tee "$LOGFILE"

# Clean up test file
rm -f $TEST_FILE
