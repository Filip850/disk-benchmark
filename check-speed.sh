#!/bin/bash

# Config
SEQ_FILE="/tmp/fio_seq_testfile"
RAND_FILE="/tmp/fio_rand_testfile"
SEQ_SIZE="4G"
RAND_RUNTIME="60s"
TEST_COUNT=3
LOGFILE="disk_benchmark_$(date +%F_%H-%M-%S).log"

# Parse args
for arg in "$@"; do
  case $arg in
    --number-of-tests=*)
      TEST_COUNT="${arg#*=}"
      shift
      ;;
  esac
done

# Check fio
if ! command -v fio &>/dev/null; then
  echo "fio not found. Installing..."
  if [ -f /etc/debian_version ]; then
    sudo apt update && sudo apt install -y fio
  elif [ -f /etc/redhat-release ]; then
    sudo dnf install -y fio || sudo yum install -y fio
  elif [ -f /etc/arch-release ]; then
    sudo pacman -Sy --noconfirm fio
  else
    echo "Unsupported distro. Install fio manually."
    exit 1
  fi
fi

# Arrays to store results
declare -a SEQ_READ_MB SEQ_WRITE_MB RAND_READ_MB RAND_WRITE_MB
declare -a SEQ_READ_IOPS SEQ_WRITE_IOPS RAND_READ_IOPS RAND_WRITE_IOPS
declare -a SEQ_READ_LAT SEQ_WRITE_LAT RAND_READ_LAT RAND_WRITE_LAT

run_fio_seq_write() {
  fio --name=seqw --size=$SEQ_SIZE --filename=$SEQ_FILE --bs=1M --rw=write --direct=1 --numjobs=1 --group_reporting --output-format=terse
}

run_fio_seq_read() {
  fio --name=seqr --size=$SEQ_SIZE --filename=$SEQ_FILE --bs=1M --rw=read --direct=1 --numjobs=1 --group_reporting --output-format=terse
}

run_fio_rand_write() {
  fio --name=randw --filename=$RAND_FILE --bs=4K --rw=randwrite --direct=1 --numjobs=1 --group_reporting --runtime=$RAND_RUNTIME --time_based --output-format=terse
}

run_fio_rand_read() {
  fio --name=randr --filename=$RAND_FILE --bs=4K --rw=randread --direct=1 --numjobs=1 --group_reporting --runtime=$RAND_RUNTIME --time_based --output-format=terse
}

# Run tests
echo "Running $TEST_COUNT iterations..."
for ((i=1;i<=TEST_COUNT;i++)); do
  echo "Iteration $i..."

  OUT=$(run_fio_seq_write)
  MBPS=$(( $(echo $OUT | cut -d';' -f49) / 1024 ))
  IOPS=$(echo $OUT | cut -d';' -f48)
  LAT=$(echo $OUT | cut -d';' -f52)
  SEQ_WRITE_MB+=($MBPS)
  SEQ_WRITE_IOPS+=($IOPS)
  SEQ_WRITE_LAT+=($LAT)

  OUT=$(run_fio_seq_read)
  MBPS=$(( $(echo $OUT | cut -d';' -f7) / 1024 ))
  IOPS=$(echo $OUT | cut -d';' -f6)
  LAT=$(echo $OUT | cut -d';' -f10)
  SEQ_READ_MB+=($MBPS)
  SEQ_READ_IOPS+=($IOPS)
  SEQ_READ_LAT+=($LAT)

  OUT=$(run_fio_rand_write)
  MBPS=$(( $(echo $OUT | cut -d';' -f49) / 1024 ))
  IOPS=$(echo $OUT | cut -d';' -f48)
  LAT=$(echo $OUT | cut -d';' -f52)
  RAND_WRITE_MB+=($MBPS)
  RAND_WRITE_IOPS+=($IOPS)
  RAND_WRITE_LAT+=($LAT)

  OUT=$(run_fio_rand_read)
  MBPS=$(( $(echo $OUT | cut -d';' -f7) / 1024 ))
  IOPS=$(echo $OUT | cut -d';' -f6)
  LAT=$(echo $OUT | cut -d';' -f10)
  RAND_READ_MB+=($MBPS)
  RAND_READ_IOPS+=($IOPS)
  RAND_READ_LAT+=($LAT)
done

# Function for mean + stdev
calc_stats() {
  local arr=("$@")
  local sum=0
  local count=${#arr[@]}
  for v in "${arr[@]}"; do sum=$((sum + v)); done
  local mean=$((sum / count))

  local sumsq=0
  for v in "${arr[@]}"; do
    diff=$((v - mean))
    sumsq=$((sumsq + diff * diff))
  done
  local stdev=0
  if (( count > 1 )); then
    stdev=$(echo "scale=2; sqrt($sumsq / ($count - 1))" | bc)
  fi
  echo "$mean ± $stdev"
}

# Output results
{
echo "Disk Benchmark Report - $(date)"
echo ""
printf "%-20s %-15s %-15s %-15s %-15s\n" "Test" "MB/s" "IOPS" "Avg Lat (ms)" ""
echo "------------------------------------------------------------------------------------------"
printf "%-20s %-15s %-15s %-15s\n" "Sequential 1M Read" "$(calc_stats "${SEQ_READ_MB[@]}")" "$(calc_stats "${SEQ_READ_IOPS[@]}")" "$(calc_stats "${SEQ_READ_LAT[@]}")"
printf "%-20s %-15s %-15s %-15s\n" "Sequential 1M Write" "$(calc_stats "${SEQ_WRITE_MB[@]}")" "$(calc_stats "${SEQ_WRITE_IOPS[@]}")" "$(calc_stats "${SEQ_WRITE_LAT[@]}")"
printf "%-20s %-15s %-15s %-15s\n" "Random 4K Read" "$(calc_stats "${RAND_READ_MB[@]}")" "$(calc_stats "${RAND_READ_IOPS[@]}")" "$(calc_stats "${RAND_READ_LAT[@]}")"
printf "%-20s %-15s %-15s %-15s\n" "Random 4K Write" "$(calc_stats "${RAND_WRITE_MB[@]}")" "$(calc_stats "${RAND_WRITE_IOPS[@]}")" "$(calc_stats "${RAND_WRITE_LAT[@]}")"
echo ""
echo "Results saved to $LOGFILE"
} | tee -a $LOGFILE

# Cleanup
rm -f $SEQ_FILE $RAND_FILE
