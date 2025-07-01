#!/bin/bash

LOGFILE="disk_benchmark_$(date +%F_%H-%M-%S).log"
TESTFILE="/tmp/fio_testfile"
SIZE="1G"

# Check is fio installed
if ! command -v fio &> /dev/null; then
    echo "fio not found. Installing..."
    if [ -f /etc/debian_version ]; then
        sudo apt update && sudo apt install -y fio
    elif [ -f /etc/redhat-release ]; then
        sudo dnf install -y fio || sudo yum install -y fio
    elif [ -f /etc/arch-release ]; then
        sudo pacman -Sy --noconfirm fio
    else
        echo "Unsupported distro. Please install fio manually."
        exit 1
    fi
fi

echo "Disk benchmark started: $(date)"
echo "Log file: $LOGFILE"
echo "----------------------------------"

{
echo "Disk Benchmark Report - $(date)"
echo "Test file: $TESTFILE ($SIZE)"
echo ""
echo -e "Test\t\t\tRead MB/s\tWrite MB/s"

# Sequential 1M
SEQ=$(fio --name=seq --size=$SIZE --filename=$TESTFILE --bs=1M --rw=rw --direct=1 --numjobs=1 --group_reporting --output-format=terse)
SEQ_READ=$(echo $SEQ | cut -d';' -f7)
SEQ_WRITE=$(echo $SEQ | cut -d';' -f49)
echo -e "Sequential 1M\t$((SEQ_READ/1024))\t\t$((SEQ_WRITE/1024))"
echo -e "Sequential 1M\t$((SEQ_READ/1024))\t\t$((SEQ_WRITE/1024))" >> $LOGFILE

# Random 4K
RAND=$(fio --name=rand --size=$SIZE --filename=$TESTFILE --bs=4K --rw=randrw --direct=1 --numjobs=1 --group_reporting --output-format=terse)
RAND_READ=$(echo $RAND | cut -d';' -f7)
RAND_WRITE=$(echo $RAND | cut -d';' -f49)
echo -e "Random 4K\t\t$((RAND_READ/1024))\t\t$((RAND_WRITE/1024))"
echo -e "Random 4K\t\t$((RAND_READ/1024))\t\t$((RAND_WRITE/1024))" >> $LOGFILE

rm -f $TESTFILE
echo ""
echo "Results saved to $LOGFILE"
} | tee -a $LOGFILE
