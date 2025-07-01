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
  echo "Installing fio..."
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

# Arrays
SEQ_READ_MB=() SEQ_WRITE_MB=() RAND_READ_MB=() RAND_WRITE_MB=()
SEQ_READ_IOPS=() SEQ_WRITE_IOPS=() RAND_READ_IOPS=() RAND_WRITE_IOPS=()
SEQ_READ_LAT=() SEQ_WRITE_LAT=() RAND_READ_LAT=() RAND_WRITE_LAT=()

run_fio_seq() {
  fio --name=$1 --filename=$SEQ_FILE --size=$SEQ_SIZE --bs=1M --rw=$2 --direct=1 --numjobs=1 --group_reporting --output-format=terse
}

run_fio_rand() {
  fio --name=$1 --filename=$RAND_FILE --bs=4K --rw=$2 --direct=1 --numjobs=1 --group_reporting --runtime=$RAND_RUNTIME --time_based --output-format=terse
}

# Stats function
calc_stats() {
  arr=("$@")
  sum=0
  for v in "${arr[@]}"; do sum=$(echo "$sum + $v" | bc); done
  mean=$(echo "scale=2; $sum / ${#arr[@]}" | bc)
  sumsq=0
  for v in "${arr[@]}"; do diff=$(echo "$v - $mean" | bc); sumsq=$(echo "$sumsq + ($diff * $diff)" | bc); done
  stdev=0
  if [ ${#arr[@]} -gt 1 ]; then
    stdev=$(echo "scale=2; sqrt($sumsq / (${#arr[@]} - 1))" | bc)
  fi
  echo "$mean ± $stdev"
}

echo "Running $TEST_COUNT iterations..."
for ((i=1;i<=TEST_COUNT;i++)); do
  echo "Iteration $i..."

  out=$(run_fio_seq seqw write)
  MBPS=$(echo $out | cut -d';' -f49 | awk '{print $1/1024}')
  IOPS=$(echo $out | cut -d';' -f48)
  LAT=$(echo $out | cut -d';' -f52)
  SEQ_WRITE_MB+=($MBPS) SEQ_WRITE_IOPS+=($IOPS) SEQ_WRITE_LAT+=($LAT)

  out=$(run_fio_seq seqr read)
  MBPS=$(echo $out | cut -d';' -f7 | awk '{print $1/1024}')
  IOPS=$(echo $out | cut -d';' -f6)
  LAT=$(echo $out | cut -d';' -f10)
  SEQ_READ_MB+=($MBPS) SEQ_READ_IOPS+=($IOPS) SEQ_READ_LAT+=($LAT)

  out=$(run_fio_rand randw randwrite)
  MBPS=$(echo $out | cut -d';' -f49 | awk '{print $1/1024}')
  IOPS=$(echo $out | cut -d';' -f48)
  LAT=$(echo $out | cut -d';' -f52)
  RAND_WRITE_MB+=($MBPS) RAND_WRITE_IOPS+=($IOPS) RAND_WRITE_LAT+=($LAT)

  out=$(run_fio_rand randr randread)
  MBPS=$(echo $out | cut -d';' -f7 | awk '{print $1/1024}')
  IOPS=$(echo $out | cut -d';' -f6)
  LAT=$(echo $out | cut -d';' -f10)
  RAND_READ_MB+=($MBPS) RAND_READ_IOPS+=($IOPS) RAND_READ_LAT+=($LAT)
done

{
echo "Disk Benchmark Report - $(date)"
echo
printf "%-20s %-20s %-15s %-15s\n" "Test" "MB/s" "IOPS" "Avg Lat (ms)"
echo "----------------------------------------------------------------------------"
printf "%-20s %-20s %-15s %-15s\n" "Sequential 1M Read" "$(calc_stats "${SEQ_READ_MB[@]}")" "$(calc_stats "${SEQ_READ_IOPS[@]}")" "$(calc_stats "${SEQ_READ_LAT[@]}")"
printf "%-20s %-20s %-15s %-15s\n" "Sequential 1M Write" "$(calc_stats "${SEQ_WRITE_MB[@]}")" "$(calc_stats "${SEQ_WRITE_IOPS[@]}")" "$(calc_stats "${SEQ_WRITE_LAT[@]}")"
printf "%-20s %-20s %-15s %-15s\n" "Random 4K Read" "$(calc_stats "${RAND_READ_MB[@]}")" "$(calc_stats "${RAND_READ_IOPS[@]}")" "$(calc_stats "${RAND_READ_LAT[@]}")"
printf "%-20s %-20s %-15s %-15s\n" "Random 4K Write" "$(calc_stats "${RAND_WRITE_MB[@]}")" "$(calc_stats "${RAND_WRITE_IOPS[@]}")" "$(calc_stats "${RAND_WRITE_LAT[@]}")"
} | tee "$LOGFILE"

rm -f "$SEQ_FILE" "$RAND_FILE"
