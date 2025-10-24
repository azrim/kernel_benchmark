#!/bin/bash

# ext4 Filesystem Benchmark Script with Interactive Menus
# Runs tests 3 times, saves best results, and compares with previous benchmarks

set -e

# --- Global variables for cleanup ---
IOSTAT_PID=0
TEMP_MONITOR_PID=0
ORIGINAL_CPU_GOVERNOR=""
ORIGINAL_TURBO_STATE=""
TEST_DIR_TO_CLEAN=""

# --- Robust Cleanup & Restore Functions ---
restore_cpu_governor() {
    local original=$1
    if [ -n "$original" ] && [ "$original" != "none" ]; then
        printf "Restoring CPU governor to %s...\\n" "$original"
        for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            echo "$original" > "$cpu" 2>/dev/null || true
        done
    fi
}

restore_turbo() {
    local original_state=$1
    if [ -z "$original_state" ]; then return; fi

    # Intel
    if [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
        echo "$original_state" > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
    fi
    # AMD
    if [ -f /sys/devices/system/cpu/cpufreq/boost ]; then
        echo "$original_state" > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true
    fi
}

cleanup_on_exit() {
    local exit_code=$?
    
    printf "\\n\\n${YELLOW}--- Cleaning up ---${NC}\\n"
    
    # Stop any background monitoring
    if [ -n "$IOSTAT_PID" ] && [ "$IOSTAT_PID" -ne 0 ]; then
        kill "$IOSTAT_PID" 2>/dev/null || true
        printf "Stopped iostat monitoring.\\n"
    fi
    
    if [ -n "$TEMP_MONITOR_PID" ] && [ "$TEMP_MONITOR_PID" -ne 0 ]; then
        kill "$TEMP_MONITOR_PID" 2>/dev/null || true
        printf "Stopped temperature monitoring.\\n"
    fi
    
    # Restore CPU settings
    if [ -n "$ORIGINAL_CPU_GOVERNOR" ]; then
        restore_cpu_governor "$ORIGINAL_CPU_GOVERNOR"
    fi
    if [ -n "$ORIGINAL_TURBO_STATE" ]; then
        restore_turbo "$ORIGINAL_TURBO_STATE"
        printf "Restored CPU turbo boost state.\\n"
    fi
    
    # Clean test directory (variable set in run_benchmark)
    if [ -n "$TEST_DIR_TO_CLEAN" ] && [ -d "$TEST_DIR_TO_CLEAN" ]; then
        rm -rf "${TEST_DIR_TO_CLEAN:?}"
        printf "Cleaned up test directory.\\n"
    fi
    
    # Stop logging to file if it was redirected
    exec > /dev/tty 2>&1
    
    sync
    
    if [ $exit_code -ne 0 ]; then
        printf "${RED}Benchmark interrupted or failed (exit code: %d). Cleanup complete.${NC}\\n" "$exit_code"
    else
        printf "${GREEN}Cleanup complete.${NC}\\n"
    fi
}

# Set trap at script start
trap cleanup_on_exit EXIT INT TERM

# Configuration
DEFAULT_MOUNT_POINT="/mnt/ext4_test"
DEFAULT_NUM_RUNS=3
DEFAULT_NUM_FILES=1000
DEFAULT_NUM_JOBS=1 # Default to 1 job for fio
BLOCK_SIZE="4k"
RESULTS_BASE_DIR="$HOME/ext4_benchmarks"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Function to print menu header
print_menu_header() {
    clear
    printf "${GREEN}╔════════════════════════════════════════════════════════╗${NC}\n"
    printf "${GREEN}║                                                        ║${NC}\n"
    printf "${GREEN}║       ext4 Filesystem Benchmark Suite                 ║${NC}\n"
    printf "${GREEN}║       Interactive Menu System                          ║${NC}\n"
    printf "${GREEN}║                                                        ║${NC}\n"
    printf "${GREEN}╚════════════════════════════════════════════════════════╝${NC}\n"
    printf "\n"
}

# Function to show main menu
show_main_menu() {
    print_menu_header
    printf "${CYAN}Main Menu:${NC}\n"
    printf "\n"
    printf "  1) Run New Benchmark\n"
    printf "  2) Compare Previous Benchmarks\n"
    printf "  3) List Saved Benchmarks\n"
    printf "  4) Delete Saved Benchmark\n"
    printf "  5) View Benchmark Details\n"
    printf "  6) Export Results to CSV\n"
    printf "  7) Settings\n"
    printf "  8) Show Performance Tips\n"
    printf "  9) Exit\n"
    printf "\n"
    printf "Select option [1-9]: "
}

# Function to show settings menu
show_settings_menu() {
    print_menu_header
    printf "${CYAN}Current Settings:${NC}\n"
    printf "\n"
    printf "  Mount Point:      %s\n" "$DEFAULT_MOUNT_POINT"
    printf "  Number of Runs:   %s\n" "$DEFAULT_NUM_RUNS"
    printf "  Test Files Count: %s\n" "$DEFAULT_NUM_FILES"
    printf "  Number of FIO Jobs: %s\n" "$DEFAULT_NUM_JOBS"
    printf "  Block Size:       %s\n" "$BLOCK_SIZE"
    printf "  Results Location: %s\n" "$RESULTS_BASE_DIR"
    printf "\n"
    printf "${CYAN}Settings Menu:${NC}\n"
    printf "\n"
    printf "  1) Change Mount Point\n"
    printf "  2) Change Number of Runs\n"
    printf "  3) Change Test Files Count\n"
    printf "  4) Change Number of FIO Jobs\n"
    printf "  5) Change Results Location\n"
    printf "  6) Save Current Settings to File\n"
    printf "  7) Back to Main Menu\n"
    printf "\n"
    printf "Select option [1-7]: "
}

# --- Enhanced Helper Functions ---

# Check for the presence of a given tool
check_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf "${RED}✗ Command not found: %s${NC}\n" "$1"
        printf "  (e.g., %s)\n" "$2"
        return 1
    fi
    printf "${GREEN}✓ Found: %s${NC}\n" "$1"
    return 0
}

# A. Better Statistical Analysis
get_median() {
    local arr=("$@")
    local sorted=($(printf '%s\n' "${arr[@]}" | sort -n))
    local count=${#sorted[@]}
    local mid=$((count / 2))
    
    if [ $((count % 2)) -eq 0 ]; then
        echo "scale=2; (${sorted[$mid-1]} + ${sorted[$mid]}) / 2" | bc
    else
        echo "${sorted[$mid]}"
    fi
}

calculate_stddev() {
    local arr=("$@")
    local sum=0
    local count=${#arr[@]}
    if [ "$count" -eq 0 ]; then echo 0; return; fi
    # Calculate mean
    for val in "${arr[@]}"; do
        sum=$(echo "$sum + $val" | bc -l)
    done
    local mean=$(echo "scale=4; $sum / $count" | bc -l)
    # Calculate variance
    local variance_sum=0
    for val in "${arr[@]}"; do
        local diff=$(echo "$val - $mean" | bc -l)
        variance_sum=$(echo "$variance_sum + ($diff * $diff)" | bc -l)
    done
    
    local variance=$(echo "scale=4; $variance_sum / $count" | bc -l)
    echo "scale=2; sqrt($variance)" | bc -l
}

print_enhanced_summary() {
    local test_name=$1
    shift
    local results_str="$*"
    local results=($results_str)
    
    if [ ${#results[@]} -eq 0 ]; then
        printf "${YELLOW}%s:${NC} No data collected.\n" "$test_name"
        return
    fi

    local best=$(get_max "${results[@]}")
    local worst=$(get_min "${results[@]}")
    local median=$(get_median "${results[@]}")
    local stddev=$(calculate_stddev "${results[@]}")
    # Avoid division by zero
    if (( $(echo "$median == 0" | bc -l) )); then
        local variance=0
    else
        local variance=$(echo "scale=2; ($stddev / $median) * 100" | bc -l)
    fi
    
    printf "${CYAN}%s:${NC}\n" "$test_name"
    printf "  Best:     %.2f\n" "$best"
    printf "  Median:   %.2f\n" "$median"
    printf "  Worst:    %.2f\n" "$worst"
    printf "  StdDev:   %.2f (%.1f%% variance)\n" "$stddev" "$variance"
    # Flag high variance as potentially unreliable
    if (( $(echo "$variance > 10" | bc -l) )); then
        printf "  ${YELLOW}⚠ High variance detected - results may be unreliable${NC}\n"
    fi
    echo ""
}

# B. Improved Cache Management
clear_caches_thoroughly() {
    sync
    # Drop page cache, dentries and inodes
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    # If available, also clear slab cache
    if [ -f /proc/sys/vm/compact_memory ]; then
        echo 1 > /proc/sys/vm/compact_memory 2>/dev/null || true
    fi
    # Wait for system to stabilize
    sleep 3
}

# C. CPU Isolation & Frequency Scaling
setup_cpu_performance() {
    local original_governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "none")
    
    if [ "$original_governor" != "none" ] && [ "$original_governor" != "performance" ]; then
        printf "Setting CPU governor to performance mode...\n"
        for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            echo performance > "$cpu" 2>/dev/null || true
        done
        echo "$original_governor"  # Return original for restoration
    else
        echo "none"
    fi
}

disable_turbo() {
    local turbo_path=""
    local current_state=""
    # Intel
    if [ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
        turbo_path="/sys/devices/system/cpu/intel_pstate/no_turbo"
        current_state=$(cat "$turbo_path")
        if [ "$current_state" = "0" ]; then
            echo 1 > "$turbo_path" 2>/dev/null || true
            printf "Disabled Intel Turbo Boost.\n"
            echo "$current_state" # Return original state
        fi
    # AMD
    elif [ -f /sys/devices/system/cpu/cpufreq/boost ]; then
        turbo_path="/sys/devices/system/cpu/cpufreq/boost"
        current_state=$(cat "$turbo_path")
        if [ "$current_state" = "1" ]; then
            echo 0 > "$turbo_path" 2>/dev/null || true
            printf "Disabled AMD CPU Boost.\n"
            echo "$current_state" # Return original state
        fi
    fi
}

# D. Resource Management
check_disk_space() {
    local mount_point=$1
    local required_gb=5  # Require 5GB free for safety
    
    local available_kb=$(df -k "$mount_point" | tail -1 | awk '{print $4}')
    local available_gb=$(echo "scale=2; $available_kb / 1024 / 1024" | bc)
    
    printf "Available space on device: %.2f GB\n" "$available_gb"
    
    if (( $(echo "$available_gb < $required_gb" | bc -l) )); then
        printf "${RED}Error: Not enough free space. At least %d GB is required.${NC}\n" "$required_gb"
        return 1
    fi
    return 0
}

set_process_priority() {
    if command -v chrt &> /dev/null; then
        # SCHED_FIFO with priority 50
        chrt -f -p 50 $$
        printf "Process priority set to real-time (SCHED_FIFO).\n"
    else
        # Fallback to nice
        renice -n -10 -p $$ >/dev/null 2>&1
        printf "Process nice value adjusted to -10.\n"
    fi
}

# E. Enhanced Monitoring & Diagnostics
capture_system_state() {
    local output_file=$1
    
    (
    echo "--- System State Snapshot ---"
    echo "Date: $(date)"
    echo "Kernel: $(uname -a)"
    echo "Uptime: $(uptime)"
    echo ""
    echo "--- CPU Info ---"
    lscpu | grep -E "Model name|Socket|Core|Thread|CPU max MHz"
    echo ""
    echo "--- Memory Info ---"
    free -h
    echo ""
    echo "--- Top 5 Processes (by CPU) ---"
    ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%cpu | head -n 6
    echo ""
    echo "--- Top 5 Processes (by Mem) ---"
    ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%mem | head -n 6
    ) > "$output_file"
    
    printf "System state captured to %s\n" "$output_file"
}

capture_device_info() {
    local device=$1
    local output=$2
    
    {
        echo "=== Device Information ==="
        lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT "$device" 2>/dev/null || true
        echo ""
        hdparm -I "$device" 2>/dev/null || true
        smartctl -a "$device" 2>/dev/null || true
    } > "$output"
    printf "Device information captured to %s\n" "$output"
}

start_iostat_monitoring() {
    local device=$1
    local interval=5
    local output_file=$2
    
    if command -v iostat &> /dev/null; then
        iostat -x "$device" $interval >> "$output_file" &
        echo $!  # Return PID to kill later
    else
        echo "0"
    fi
}

monitor_temperature() {
    local output_file=$1
    
    if command -v sensors &> /dev/null; then
        (
            echo "--- Temperature Log (started at $(date +%T)) ---" >> "$output_file"
            while true; do
                echo "[$(date +%T)] $(sensors 2>&1 | head -n 5)" >> "$output_file"
                sleep 5
            done
        ) &
        echo $!  # Return PID
    else
        echo "0"
    fi
}

check_throttling() {
    local throttle_count=0
    if [ -f /sys/devices/system/cpu/cpu0/thermal_throttle/core_throttle_count ]; then
        for cpu in /sys/devices/system/cpu/cpu*/thermal_throttle/core_throttle_count; do
            local count=$(cat "$cpu" 2>/dev/null || echo "0")
            throttle_count=$((throttle_count + count))
        done
    fi
    
    if [ "$throttle_count" -gt 0 ]; then
        printf "${YELLOW}Warning: Thermal throttling detected (%d events) since boot.${NC}\n" "$throttle_count"
    fi
}

# F. Output Improvements
show_progress() {
    local current=$1
    local total=$2
    local prefix=$3
    
    local percent=$((current * 100 / total))
    local filled=$((percent / 2))
    local empty=$((50 - filled))
    
    printf "\r${prefix} ["
    printf "%${filled}s" | tr ' ' '='
    printf "%${empty}s" | tr ' ' '-'
    printf "] %3d%%" "$percent"
    
    if [ "$current" -eq "$total" ]; then
        printf "\n"
    fi
}

# G. Configuration Management
load_config() {
    local config_file="${HOME}/.ext4_benchmark.conf"
    if [ -f "$config_file" ]; then
        printf "Loading configuration from %s\n" "$config_file"
        # Source config safely
        while IFS='=' read -r key value; do
            # Skip comments and empty lines
            [[ "$key" =~ ^#.*$ ]] && continue
            [[ -z "$key" ]] && continue
            
            case "$key" in
                DEFAULT_MOUNT_POINT) DEFAULT_MOUNT_POINT="$value" ;;
                DEFAULT_NUM_RUNS) DEFAULT_NUM_RUNS="$value" ;;
                DEFAULT_NUM_FILES) DEFAULT_NUM_FILES="$value" ;;
                DEFAULT_NUM_JOBS) DEFAULT_NUM_JOBS="$value" ;;
                RESULTS_BASE_DIR) RESULTS_BASE_DIR="$value" ;;
            esac
        done < "$config_file"
    fi
}

save_config() {
    local config_file="${HOME}/.ext4_benchmark.conf"
    cat > "$config_file" << EOF
# ext4 Benchmark Configuration
# Generated: $(date)

DEFAULT_MOUNT_POINT=$DEFAULT_MOUNT_POINT
DEFAULT_NUM_RUNS=$DEFAULT_NUM_RUNS
DEFAULT_NUM_FILES=$DEFAULT_NUM_FILES
DEFAULT_NUM_JOBS=$DEFAULT_NUM_JOBS
RESULTS_BASE_DIR=$RESULTS_BASE_DIR
EOF
    printf "${GREEN}Configuration saved to %s${NC}\n" "$config_file"
    sleep 1
}

# H. Info Display
show_performance_tips() {
    local gov
    gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "N/A")
    local load
    load=$(uptime | awk -F'load average: ' '{print $2}')
    local mem
    mem=$(free -h | awk '/^Mem:/ {print $4}')

    clear
    printf "
╔════════════════════════════════════════════════════════════╗
║           BENCHMARK PERFORMANCE TIPS                       ║
╠════════════════════════════════════════════════════════════╣
║                                                            ║
║  For most accurate results:                                ║
║  ✓ Close unnecessary applications                         ║
║  ✓ Disable background services (updates, indexing, etc.)  ║
║  ✓ Run on AC power (not battery)                          ║
║  ✓ Ensure system is not under thermal load                ║
║                                                            ║
║  This script attempts to:                                  ║
║  ✓ Set CPU governor to 'performance'                      ║
║  ✓ Disable CPU turbo boost                                ║
║  ✓ Set real-time process priority                         ║
║                                                            ║
║  Current system state:                                     ║
║  - CPU Governor:   %s
║  - Load Average:   %s
║  - Available Mem:  %s
║                                                            ║
╚════════════════════════════════════════════════════════════╝
" "$gov" "$load" "$mem"
    printf "\n"
    read -p "Press Enter to continue..."
}

# Check if running as root for benchmark operations
check_root() {
    if [ "$EUID" -ne 0 ]; then
        printf "${RED}This operation requires root privileges${NC}\n"
        printf "Please run this script with sudo\n"
        printf "\n"
        read -p "Press Enter to continue..."
        return 1
    fi
    return 0
}

# Check for required tools
check_dependencies() {
    local missing_count=0
    printf "Checking for required tools...\\n"
    check_tool "bc" "e.g., sudo apt-get install bc" || ((missing_count++))
    check_tool "jq" "e.g., sudo apt-get install jq" || ((missing_count++))
    check_tool "fio" "e.g., sudo apt-get install fio" || ((missing_count++))
    check_tool "iostat" "e.g., sudo apt-get install sysstat" || ((missing_count++))
    check_tool "sensors" "e.g., sudo apt-get install lm-sensors" || ((missing_count++))
    
    if [ "$missing_count" -gt 0 ]; then
        return 1
    fi
    return 0
}

# List saved benchmarks
list_benchmarks() {
    print_menu_header
    printf "${CYAN}Saved Benchmarks:${NC}\n"
    printf "\n"

    if [ ! -d "$RESULTS_BASE_DIR" ] || [ -z "$(ls -A "$RESULTS_BASE_DIR" 2>/dev/null)" ]; then
        printf "  No benchmarks found in %s\n" "$RESULTS_BASE_DIR"
        printf "\n"
        read -p "Press Enter to continue..."
        return
    fi

    local count=1
    declare -g -A benchmark_dirs

    for dir in "$RESULTS_BASE_DIR"/*; do
        if [ -f "$dir/summary.json" ]; then
            local NAME
            NAME=$(jq -r '.benchmark_name' "$dir/summary.json" 2>/dev/null || echo "unknown")
            local TIMESTAMP
            TIMESTAMP=$(jq -r '.timestamp' "$dir/summary.json" 2>/dev/null || echo "unknown")
            local KERNEL
            KERNEL=$(jq -r '.kernel_version' "$dir/summary.json" 2>/dev/null || echo "unknown")
            local DATE
            DATE=$(echo "$TIMESTAMP" | sed 's/_/ /' | cut -d' ' -f1 | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3/')
            local TIME
            TIME=$(echo "$TIMESTAMP" | sed 's/_/ /' | cut -d' ' -f2 | sed 's/\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1:\2:\3/')

            printf "  %2d) %-25s (Kernel: %-15s Date: %s %s)\n" "$count" "$NAME" "$KERNEL" "$DATE" "$TIME"
            benchmark_dirs[$count]="$dir"
            ((count++))
        fi
    done

    if [ "$count" -eq 1 ]; then
        printf "  No valid benchmarks found\n"
    fi

    printf "\n"
    read -p "Press Enter to continue..."
}

# View benchmark details
view_benchmark_details() {
    print_menu_header
    printf "${CYAN}View Benchmark Details${NC}\n"
    printf "\n"

    if [ ! -d "$RESULTS_BASE_DIR" ] || [ -z "$(ls -A "$RESULTS_BASE_DIR" 2>/dev/null)" ]; then
        printf "  No benchmarks found in %s\n" "$RESULTS_BASE_DIR"
        printf "\n"
        read -p "Press Enter to continue..."
        return
    fi

    local count=1
    local -A benchmark_dirs

    printf "Available benchmarks:\n"
    printf "\n"

    for dir in "$RESULTS_BASE_DIR"/*; do
        if [ -f "$dir/summary.json" ]; then
            local NAME
            NAME=$(jq -r '.benchmark_name' "$dir/summary.json" 2>/dev/null || echo "unknown")
            local TIMESTAMP
            TIMESTAMP=$(jq -r '.timestamp' "$dir/summary.json" 2>/dev/null || echo "unknown")
            printf "  %2d) %s (%s)\n" "$count" "$NAME" "$TIMESTAMP"
            benchmark_dirs[$count]="$dir"
            ((count++))
        fi
    done

    if [ "$count" -eq 1 ]; then
        printf "  No valid benchmarks found\n"
        printf "\n"
        read -p "Press Enter to continue..."
        return
    fi

    printf "\n"
    printf "Select benchmark to view (or 0 to cancel): "
    local selection
    read -r selection

    if [ "$selection" = "0" ]; then
        return
    fi

    if [ -n "${benchmark_dirs[$selection]}" ]; then
        clear
        printf "${GREEN}Benchmark Details${NC}\n"
        printf "\n"

        local dir="${benchmark_dirs[$selection]}"

        if command -v jq >/dev/null 2>&1 && [ -f "$dir/summary.json" ]; then
            local NAME
            NAME=$(jq -r '.benchmark_name' "$dir/summary.json")
            local KERNEL
            KERNEL=$(jq -r '.kernel_version' "$dir/summary.json")
            local DEVICE
            DEVICE=$(jq -r '.device' "$dir/summary.json")

            printf "${CYAN}Name:${NC} %s\n" "$NAME"
            printf "${CYAN}Kernel:${NC} %s\n" "$KERNEL"
            printf "${CYAN}Device:${NC} %s\n" "$DEVICE"
            printf "\n"
            printf "${CYAN}Best Results:${NC}\n"
            printf "\n"

            local SEQ_WRITE
            SEQ_WRITE=$(jq -r '.best_results.seq_write_mbps' "$dir/summary.json")
            local SEQ_READ
            SEQ_READ=$(jq -r '.best_results.seq_read_mbps' "$dir/summary.json")
            printf "  Sequential Write: %.2f MB/s\n" "$SEQ_WRITE"
            printf "  Sequential Read:  %.2f MB/s\n" "$SEQ_READ"

            local RAND_WRITE
            RAND_WRITE=$(jq -r '.best_results.rand_write_iops' "$dir/summary.json")
            if [ "$RAND_WRITE" != "null" ] && [ "$RAND_WRITE" != "0" ]; then
                local RAND_READ
                RAND_READ=$(jq -r '.best_results.rand_read_iops' "$dir/summary.json")
                printf "  Random Write:     %.0f IOPS\n" "$RAND_WRITE"
                printf "  Random Read:      %.0f IOPS\n" "$RAND_READ"
            fi

            local FILE_CREATE
            FILE_CREATE=$(jq -r '.best_results.file_create_time' "$dir/summary.json")
            local FILE_DELETE
            FILE_DELETE=$(jq -r '.best_results.file_delete_time' "$dir/summary.json")
            local NUM_FILES
            NUM_FILES=$(jq -r '.config.num_files' "$dir/summary.json")

            printf "  File Creation:    %s files/s\n" "$(echo "$NUM_FILES / $FILE_CREATE" | bc)"
            printf "  File Deletion:    %s files/s\n" "$(echo "$NUM_FILES / $FILE_DELETE" | bc)"
        else
            printf "Summary not available\n"
        fi

        printf "\n"
        printf "${CYAN}Full log available at:${NC} %s/benchmark_full.txt\n" "$dir"
        printf "\n"
        read -p "Press Enter to continue..."
    else
        printf "\n"
        printf "${RED}Invalid selection${NC}\n"
        printf "\n"
        read -p "Press Enter to continue..."
    fi
}

# Delete benchmark
delete_benchmark() {
    print_menu_header
    printf "${CYAN}Delete Benchmark${NC}\n"
    printf "\n"

    if [ ! -d "$RESULTS_BASE_DIR" ] || [ -z "$(ls -A "$RESULTS_BASE_DIR" 2>/dev/null)" ]; then
        printf "  No benchmarks found in %s\n" "$RESULTS_BASE_DIR"
        printf "\n"
        read -p "Press Enter to continue..."
        return
    fi

    local count=1
    local -A benchmark_dirs

    printf "Available benchmarks:\n"
    printf "\n"

    for dir in "$RESULTS_BASE_DIR"/*; do
        if [ -f "$dir/summary.json" ]; then
            local NAME
            NAME=$(jq -r '.benchmark_name' "$dir/summary.json" 2>/dev/null || echo "unknown")
            local TIMESTAMP
            TIMESTAMP=$(jq -r '.timestamp' "$dir/summary.json" 2>/dev/null || echo "unknown")
            printf "  %2d) %s (%s)\n" "$count" "$NAME" "$TIMESTAMP"
            benchmark_dirs[$count]="$dir"
            ((count++))
        fi
    done

    if [ "$count" -eq 1 ]; then
        printf "  No valid benchmarks found\n"
        printf "\n"
        read -p "Press Enter to continue..."
        return
    fi

    printf "\n"
    printf "Select benchmark to delete (or 0 to cancel): "
    local selection
    read -r selection

    if [ "$selection" = "0" ]; then
        return
    fi

    if [ -n "${benchmark_dirs[$selection]}" ]; then
        local dir="${benchmark_dirs[$selection]}"
        local NAME
        NAME=$(jq -r '.benchmark_name' "$dir/summary.json" 2>/dev/null || echo "unknown")

        printf "\n"
        printf "${YELLOW}Are you sure you want to delete benchmark '%s'?${NC}\n" "$NAME"
        printf "Type 'yes' to confirm: "
        local confirm
        read -r confirm

        if [ "$confirm" = "yes" ]; then
            rm -rf "$dir"
            printf "\n"
            printf "${GREEN}Benchmark deleted successfully${NC}\n"
        else
            printf "\n"
            printf "Deletion cancelled\n"
        fi
        printf "\n"
        read -p "Press Enter to continue..."
    else
        printf "\n"
        printf "${RED}Invalid selection${NC}\n"
        printf "\n"
        read -p "Press Enter to continue..."
    fi
}

# Export to CSV
export_to_csv() {
    print_menu_header
    printf "${CYAN}Export Results to CSV${NC}\n"
    printf "\n"

    if ! command -v jq >/dev/null 2>&1; then
        printf "${RED}jq is required for CSV export${NC}\n"
        printf "Install with: apt-get install jq\n"
        printf "\n"
        read -p "Press Enter to continue..."
        return
    fi

    if [ ! -d "$RESULTS_BASE_DIR" ] || [ -z "$(ls -A "$RESULTS_BASE_DIR" 2>/dev/null)" ]; then
        printf "  No benchmarks found in %s\n" "$RESULTS_BASE_DIR"
        printf "\n"
        read -p "Press Enter to continue..."
        return
    fi

    local CSV_FILE
    CSV_FILE="$HOME/ext4_benchmark_comparison_$(date +%Y%m%d_%H%M%S).csv"

    # Write CSV header
    echo "Benchmark Name,Timestamp,Kernel Version,Device,Seq Write (MB/s),Seq Read (MB/s),Rand Write IOPS,Rand Read IOPS,Mixed Read IOPS,Mixed Write IOPS,File Create Time,File Delete Time,Dir Create Time" > "$CSV_FILE"

    # Write data
    for dir in "$RESULTS_BASE_DIR"/*; do
        if [ -f "$dir/summary.json" ]; then
            local NAME
            NAME=$(jq -r '.benchmark_name' "$dir/summary.json")
            local TIMESTAMP
            TIMESTAMP=$(jq -r '.timestamp' "$dir/summary.json")
            local KERNEL
            KERNEL=$(jq -r '.kernel_version' "$dir/summary.json")
            local DEVICE
            DEVICE=$(jq -r '.device' "$dir/summary.json")
            local SEQ_WRITE
            SEQ_WRITE=$(jq -r '.best_results.seq_write_mbps' "$dir/summary.json")
            local SEQ_READ
            SEQ_READ=$(jq -r '.best_results.seq_read_mbps' "$dir/summary.json")
            local RAND_WRITE
            RAND_WRITE=$(jq -r '.best_results.rand_write_iops' "$dir/summary.json")
            local RAND_READ
            RAND_READ=$(jq -r '.best_results.rand_read_iops' "$dir/summary.json")
            local MIXED_READ
            MIXED_READ=$(jq -r '.best_results.mixed_read_iops' "$dir/summary.json")
            local MIXED_WRITE
            MIXED_WRITE=$(jq -r '.best_results.mixed_write_iops' "$dir/summary.json")
            local FILE_CREATE
            FILE_CREATE=$(jq -r '.best_results.file_create_time' "$dir/summary.json")
            local FILE_DELETE
            FILE_DELETE=$(jq -r '.best_results.file_delete_time' "$dir/summary.json")
            local DIR_CREATE
            DIR_CREATE=$(jq -r '.best_results.dir_create_time' "$dir/summary.json")

            echo "$NAME,$TIMESTAMP,$KERNEL,$DEVICE,$SEQ_WRITE,$SEQ_READ,$RAND_WRITE,$RAND_READ,$MIXED_READ,$MIXED_WRITE,$FILE_CREATE,$FILE_DELETE,$DIR_CREATE" >> "$CSV_FILE"
        fi
    done

    printf "${GREEN}CSV file exported successfully!${NC}\n"
    printf "\n"
    printf "Location: %s\n" "$CSV_FILE"
    printf "\n"
    read -p "Press Enter to continue..."
}

# Comparison function
compare_benchmarks() {
    print_menu_header

    if ! command -v jq >/dev/null 2>&1; then
        printf "${RED}jq is required for comparison${NC}\n"
        printf "Install with: apt-get install jq\n"
        printf "\n"
        read -p "Press Enter to continue..."
        return
    fi

    if [ ! -d "$RESULTS_BASE_DIR" ] || [ -z "$(ls -A "$RESULTS_BASE_DIR" 2>/dev/null)" ]; then
        printf "${RED}No benchmark results found in %s${NC}\n" "$RESULTS_BASE_DIR"
        printf "\n"
        read -p "Press Enter to continue..."
        return
    fi

    printf "${CYAN}Select benchmarks to compare:${NC}\n"
    printf "\n"

    # Find all benchmark summaries
    local count=1
    local -A benchmark_dirs

    for dir in "$RESULTS_BASE_DIR"/*; do
        if [ -f "$dir/summary.json" ]; then
            local NAME
            NAME=$(jq -r '.benchmark_name' "$dir/summary.json" 2>/dev/null || echo "unknown")
            local TIMESTAMP
            TIMESTAMP=$(jq -r '.timestamp' "$dir/summary.json" 2>/dev/null || echo "unknown")
            local KERNEL
            KERNEL=$(jq -r '.kernel_version' "$dir/summary.json" 2>/dev/null || echo "unknown")

            printf "  %2d) %-25s (Kernel: %s, Time: %s)\n" "$count" "$NAME" "$KERNEL" "$TIMESTAMP"
            benchmark_dirs[$count]="$dir"
            ((count++))
        fi
    done

    if [ "$count" -eq 1 ]; then
        printf "  No valid benchmarks found\n"
        printf "\n"
        read -p "Press Enter to continue..."
        return
    fi

    printf "\n"
    printf "  0) Compare all benchmarks\n"
    printf "\n"
    printf "Select option (or press Enter to cancel): "
    local selection
    read -r selection

    if [ -z "$selection" ]; then
        return
    fi

    clear
    printf "${GREEN}╔════════════════════════════════════════╗${NC}\n"
    printf "${GREEN}║   Benchmark Comparison Results         ║${NC}\n"
    printf "${GREEN}╚════════════════════════════════════════╝${NC}\n"
    printf "\n"

    # Prepare arrays
    local SUMMARIES=()
    local NAMES=()

    if [ "$selection" = "0" ]; then
        # Compare all
        for i in $(seq 1 $((count-1))); do
            SUMMARIES+=("${benchmark_dirs[$i]}/summary.json")
            NAMES+=("$(jq -r '.benchmark_name' "${benchmark_dirs[$i]}/summary.json")")
        done
    else
        # Compare selected (you can extend this to select multiple)
        if [ -n "${benchmark_dirs[$selection]}" ]; then
            # For now, compare selected with all others
            for i in $(seq 1 $((count-1))); do
                SUMMARIES+=("${benchmark_dirs[$i]}/summary.json")
                NAMES+=("$(jq -r '.benchmark_name' "${benchmark_dirs[$i]}/summary.json")")
            done
        else
            printf "${RED}Invalid selection${NC}\n"
            printf "\n"
            read -p "Press Enter to continue..."
            return
        fi
    fi

    # Print comparison table
    printf "${CYAN}════════════════════════════════════════════════════════════════${NC}\n"
    printf "%-25s" "Test"
    for name in "${NAMES[@]}"; do
        printf "%-20s" "${name:0:18}"
    done
    printf "%-15s\n" "Winner"
    printf "${CYAN}════════════════════════════════════════════════════════════════${NC}\n"

    # Compare Sequential Write
    printf "%-25s" "Seq Write (MB/s)"
    local MAX_VAL=0
    local MAX_IDX=0
    local i
    for i in "${!SUMMARIES[@]}"; do
        local VAL
        VAL=$(jq -r '.best_results.seq_write_mbps' "${SUMMARIES[$i]}")
        printf "%-20s" "$(printf "%.2f" "$VAL")"
        if (( $(echo "$VAL > $MAX_VAL" | bc -l) )); then
            MAX_VAL=$VAL
            MAX_IDX=$i
        fi
    done
    printf "${GREEN}%s${NC}\n" "${NAMES[$MAX_IDX]:0:13}"

    # Compare Sequential Read
    printf "%-25s" "Seq Read (MB/s)"
    MAX_VAL=0
    MAX_IDX=0
    for i in "${!SUMMARIES[@]}"; do
        local VAL
        VAL=$(jq -r '.best_results.seq_read_mbps' "${SUMMARIES[$i]}")
        printf "%-20s" "$(printf "%.2f" "$VAL")"
        if (( $(echo "$VAL > $MAX_VAL" | bc -l) )); then
            MAX_VAL=$VAL
            MAX_IDX=$i
        fi
    done
    printf "${GREEN}%s${NC}\n" "${NAMES[$MAX_IDX]:0:13}"

    # Check if FIO data exists
    local HAS_FIO
    HAS_FIO=$(jq -r '.best_results.rand_write_iops' "${SUMMARIES[0]}")

    if [ "$HAS_FIO" != "null" ] && [ "$HAS_FIO" != "0" ]; then
        # Random Write IOPS
        printf "%-25s" "Rand Write IOPS"
        MAX_VAL=0
        MAX_IDX=0
        for i in "${!SUMMARIES[@]}"; do
            local VAL
            VAL=$(jq -r '.best_results.rand_write_iops' "${SUMMARIES[$i]}")
            printf "%-20s" "$(printf "%.0f" "$VAL")"
            if (( $(echo "$VAL > $MAX_VAL" | bc -l) )); then
                MAX_VAL=$VAL
                MAX_IDX=$i
            fi
        done
        printf "${GREEN}%s${NC}\n" "${NAMES[$MAX_IDX]:0:13}"

        # Random Read IOPS
        printf "%-25s" "Rand Read IOPS"
        MAX_VAL=0
        MAX_IDX=0
        for i in "${!SUMMARIES[@]}"; do
            local VAL
            VAL=$(jq -r '.best_results.rand_read_iops' "${SUMMARIES[$i]}")
            printf "%-20s" "$(printf "%.0f" "$VAL")"
            if (( $(echo "$VAL > $MAX_VAL" | bc -l) )); then
                MAX_VAL=$VAL
                MAX_IDX=$i
            fi
        done
        printf "${GREEN}%s${NC}\n" "${NAMES[$MAX_IDX]:0:13}"
    fi

    # File Creation
    printf "%-25s" "File Create (files/s)"
    MAX_VAL=0
    MAX_IDX=0
    for i in "${!SUMMARIES[@]}"; do
        local TIME
        TIME=$(jq -r '.best_results.file_create_time' "${SUMMARIES[$i]}")
        local FILES
        FILES=$(jq -r '.config.num_files' "${SUMMARIES[$i]}")
        local VAL
        VAL=$(echo "$FILES / $TIME" | bc -l)
        printf "%-20s" "$(printf "%.0f" "$VAL")"
        if (( $(echo "$VAL > $MAX_VAL" | bc -l) )); then
            MAX_VAL=$VAL
            MAX_IDX=$i
        fi
    done
    printf "${GREEN}%s${NC}\n" "${NAMES[$MAX_IDX]:0:13}"

    # File Deletion
    printf "%-25s" "File Delete (files/s)"
    MAX_VAL=0
    MAX_IDX=0
    for i in "${!SUMMARIES[@]}"; do
        local TIME
        TIME=$(jq -r '.best_results.file_delete_time' "${SUMMARIES[$i]}")
        local FILES
        FILES=$(jq -r '.config.num_files' "${SUMMARIES[$i]}")
        local VAL
        VAL=$(echo "$FILES / $TIME" | bc -l)
        printf "%-20s" "$(printf "%.0f" "$VAL")"
        if (( $(echo "$VAL > $MAX_VAL" | bc -l) )); then
            MAX_VAL=$VAL
            MAX_IDX=$i
        fi
    done
    printf "${GREEN}%s${NC}\n" "${NAMES[$MAX_IDX]:0:13}"

    printf "${CYAN}════════════════════════════════════════════════════════════════${NC}\n"

    # Calculate overall scores
    printf "\n"
    printf "${CYAN}Overall Performance Score:${NC}\n"
    local -A SCORES
    for i in "${!SUMMARIES[@]}"; do
        SCORES[$i]=0
    done

    # Sequential Write
    MAX_VAL=0; MAX_IDX=0
    for i in "${!SUMMARIES[@]}"; do
        local VAL
        VAL=$(jq -r '.best_results.seq_write_mbps' "${SUMMARIES[$i]}")
        if (( $(echo "$VAL > $MAX_VAL" | bc -l) )); then
            MAX_VAL=$VAL; MAX_IDX=$i
        fi
    done
    SCORES[$MAX_IDX]=$((${SCORES[$MAX_IDX]} + 10))

    # Sequential Read
    MAX_VAL=0; MAX_IDX=0
    for i in "${!SUMMARIES[@]}"; do
        local VAL
        VAL=$(jq -r '.best_results.seq_read_mbps' "${SUMMARIES[$i]}")
        if (( $(echo "$VAL > $MAX_VAL" | bc -l) )); then
            MAX_VAL=$VAL; MAX_IDX=$i
        fi
    done
    SCORES[$MAX_IDX]=$((${SCORES[$MAX_IDX]} + 10))

    if [ "$HAS_FIO" != "null" ] && [ "$HAS_FIO" != "0" ]; then
        # Random Write
        MAX_VAL=0; MAX_IDX=0
        for i in "${!SUMMARIES[@]}"; do
            local VAL
            VAL=$(jq -r '.best_results.rand_write_iops' "${SUMMARIES[$i]}")
            if (( $(echo "$VAL > $MAX_VAL" | bc -l) )); then
                MAX_VAL=$VAL; MAX_IDX=$i
            fi
        done
        SCORES[$MAX_IDX]=$((${SCORES[$MAX_IDX]} + 15))

        # Random Read
        MAX_VAL=0; MAX_IDX=0
        for i in "${!SUMMARIES[@]}"; do
            local VAL
            VAL=$(jq -r '.best_results.rand_read_iops' "${SUMMARIES[$i]}")
            if (( $(echo "$VAL > $MAX_VAL" | bc -l) )); then
                MAX_VAL=$VAL; MAX_IDX=$i
            fi
        done
        SCORES[$MAX_IDX]=$((${SCORES[$MAX_IDX]} + 15))
    fi

    # Print scores
    for i in "${!SUMMARIES[@]}"; do
        printf "  %s: %s points\n" "${NAMES[$i]}" "${SCORES[$i]}"
    done

    # Find overall winner
    local MAX_SCORE=0
    local WINNER_IDX=0
    for i in "${!SUMMARIES[@]}"; do
        if [ "${SCORES[$i]}" -gt "$MAX_SCORE" ]; then
            MAX_SCORE=${SCORES[$i]}
            WINNER_IDX=$i
        fi
    done

    printf "\n"
    printf "${GREEN}🏆 Overall Winner: %s (%s points)${NC}\n" "${NAMES[$WINNER_IDX]}" "${SCORES[$WINNER_IDX]}"
    printf "\n"
    read -p "Press Enter to continue..."
}

# Function to get max value using bc for float comparison
get_max() {
    local max=0
    for val in "$@"; do
        if (( $(echo "$val > $max" | bc -l) )); then
            max="$val"
        fi
    done
    echo "$max"
}

# Function to get min value using bc for float comparison
get_min() {
    local min
    if [ -n "$1" ]; then
        min="$1"
        for val in "$@"; do
            if (( $(echo "$val < $min" | bc -l) )); then
                min="$val"
            fi
        done
        echo "$min"
    fi
}

# Function to print test header
print_test_header() {
    printf "\n"
    printf "${CYAN}========================================\n"
    printf "%s\n" "$1"
    printf "========================================${NC}\n"
}

# Function to print run header
print_run_header() {
    printf "${YELLOW}--- Run %s of %s ---${NC}\n" "$1" "$2"
}

print_ascii_chart() {
    local title=$1
    shift
    local values=($@)
    local max=$(get_max "${values[@]}")
    
    printf "\n${CYAN}%s${NC}\n" "$title"
    for i in "${!values[@]}"; do
        local bar_len=$(echo "${values[$i]} / $max * 50" | bc -l | xargs printf "%.0f")
        printf "Run %d: " "$((i+1))"
        printf "%${bar_len}s" | tr ' ' '█'
        printf " %.2f\n" "${values[$i]}"
    done
}

run_benchmark() {
    if ! check_root; then return; fi
    print_menu_header
    printf "${CYAN}Run New Benchmark${NC}\n\n"
    if ! check_dependencies; then
        printf "\n${RED}Please install missing dependencies.${NC}\n"; read -p "Enter..."; return; fi

    # --- Pre-flight Checks & Setup ---
    printf "Enter benchmark name (e.g., 'kernel-6.1'): "
    local BENCHMARK_NAME; read -r BENCHMARK_NAME
    BENCHMARK_NAME=${BENCHMARK_NAME:-"benchmark-$(date +%Y%m%d-%H%M%S)"}

    printf "Enter directory for benchmark (default: %s): " "$DEFAULT_MOUNT_POINT"
    local MOUNT_POINT; read -r MOUNT_POINT
    MOUNT_POINT=${MOUNT_POINT:-$DEFAULT_MOUNT_POINT}

    if ! check_disk_space "$MOUNT_POINT"; then read -p "Enter..."; return; fi
    if ! touch "$MOUNT_POINT/.write_test" 2>/dev/null; then
        printf "${RED}Error: Cannot write to mount point %s. Check permissions or choose another location.${NC}\n" "$MOUNT_POINT"
        read -p "Press Enter to continue..."
        return
    fi
    rm -f "$MOUNT_POINT/.write_test"
    if [ ! -d "$MOUNT_POINT" ]; then
        read -p "Directory does not exist. Create it? (y/n): " confirm
        if [ "$confirm" = "y" ]; then mkdir -p "$MOUNT_POINT"; else return; fi
    fi

    local TEST_DIR="${MOUNT_POINT}/benchmark"
    TEST_DIR_TO_CLEAN=$TEST_DIR # Set global var for trap cleanup
    local DEVICE; DEVICE=$(df "$MOUNT_POINT" | tail -1 | awk '{print $1}')

    # --- Confirm Settings ---
    printf "\n${GREEN}Benchmark Configuration:${NC}\n"
    printf "  Name: %s\n  Directory: %s\n  Runs: %s\n  Files: %s\n" \
        "$BENCHMARK_NAME" "$MOUNT_POINT" "$DEFAULT_NUM_RUNS" "$DEFAULT_NUM_FILES"
    read -p "Proceed? (y/n): " confirm
    if [ "$confirm" != "y" ]; then return; fi

    # --- Environment Setup ---
    local TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    local RESULTS_DIR="${RESULTS_BASE_DIR}/${TIMESTAMP}_${BENCHMARK_NAME}"
    mkdir -p "$RESULTS_DIR" "$TEST_DIR"
    
    echo "DEBUG: Setting up CPU performance..."
    ORIGINAL_CPU_GOVERNOR=$(setup_cpu_performance)
    ORIGINAL_TURBO_STATE=$(disable_turbo)
    set_process_priority
    check_throttling
    
    # --- Start Monitoring ---
    echo "DEBUG: Capturing initial system state..."
    capture_system_state "$RESULTS_DIR/system_state_before.txt"
    echo "DEBUG: Capturing device information..."
    capture_device_info "$DEVICE" "$RESULTS_DIR/device_info.txt"
    echo "DEBUG: Starting iostat monitoring..."
    IOSTAT_PID=$(start_iostat_monitoring "$DEVICE" "$RESULTS_DIR/iostat.log")
    echo "DEBUG: iostat started with PID $IOSTAT_PID."
    echo "DEBUG: Starting temperature monitoring..."
    TEMP_MONITOR_PID=$(monitor_temperature "$RESULTS_DIR/temperature.log")
    echo "DEBUG: Temperature monitor started with PID $TEMP_MONITOR_PID."

    # --- Start Logging ---
    echo "DEBUG: Redirecting script output to log file..."
    exec > >(tee -a "$RESULTS_DIR/benchmark_full.log") 2>&1
    echo "DEBUG: Output redirected."
    
    printf "Benchmark started: %s\n" "$(date)"
    printf "Results directory: %s\n" "$RESULTS_DIR"
    
    # --- Arrays to store all run results for statistics ---
    declare -A results_seq_write results_seq_read results_rand_write results_rand_read results_mixed_read results_mixed_write results_file_create results_file_delete results_dir_create

    # --- Main Benchmark Loop ---
    for run in $(seq 1 "$DEFAULT_NUM_RUNS"); do
        printf "\n${BLUE}━━━━━━━━━━ RUN %s of %s ━━━━━━━━━━${NC}\n" "$run" "$DEFAULT_NUM_RUNS"
        
        # 1. Sequential Write
        print_test_header "Test 1: Sequential Write (dd)"
        clear_caches_thoroughly
        local dd_output; dd_output=$(timeout 60 taskset -c 0 dd if=/dev/zero of="${TEST_DIR}/testfile" bs=$BLOCK_SIZE count=262144 conv=fdatasync oflag=direct 2>&1)
        echo "$dd_output"
        local speed; speed=$(echo "$dd_output" | grep -oP '\d+\.?\d* [KMG]B/s' | tail -1 | awk '{print $1}')
        local unit; unit=$(echo "$dd_output" | grep -oP '\d+\.?\d* [KMG]B/s' | tail -1 | awk '{print $2}')
        if [ "$unit" = "GB/s" ]; then speed=$(echo "$speed * 1024" | bc);
        elif [ "$unit" = "KB/s" ]; then speed=$(echo "$speed / 1024" | bc -l); fi
        results_seq_write[$run]=$speed

        # 2. Sequential Read
        print_test_header "Test 2: Sequential Read (dd)"
        clear_caches_thoroughly
        dd_output=$(timeout 60 taskset -c 0 dd if="${TEST_DIR}/testfile" of=/dev/null bs=$BLOCK_SIZE iflag=direct 2>&1)
        echo "$dd_output"
        speed=$(echo "$dd_output" | grep -oP '\d+\.?\d* [KMG]B/s' | tail -1 | awk '{print $1}')
        unit=$(echo "$dd_output" | grep -oP '\d+\.?\d* [KMG]B/s' | tail -1 | awk '{print $2}')
        if [ "$unit" = "GB/s" ]; then speed=$(echo "$speed * 1024" | bc);
        elif [ "$unit" = "KB/s" ]; then speed=$(echo "$speed / 1024" | bc -l); fi
        results_seq_read[$run]=$speed
        rm -f "${TEST_DIR}/testfile"

        # 3. FIO Random Write
        print_test_header "Test 3: Random Write (fio)"
        clear_caches_thoroughly
        local fio_output_file="${RESULTS_DIR}/fio_randwrite_run${run}.json"
        timeout 60 taskset -c 0 fio --name=randwrite --ioengine=libaio --iodepth=32 --rw=randwrite --bs=4k --direct=1 --size=512M --numjobs=$DEFAULT_NUM_JOBS --runtime=30 --time_based --group_reporting --directory="$TEST_DIR" --filename="fio_temp" --output-format=json --output="$fio_output_file" >/dev/null 2>&1
        local iops; iops=$(jq -r '.jobs[0].write.iops' "$fio_output_file")
        results_rand_write[$run]=${iops:-0}
        printf "Result: %.0f IOPS\n" "${iops:-0}"
        rm -f "${TEST_DIR}/fio_temp"

        # 4. FIO Random Read
        print_test_header "Test 4: Random Read (fio)"
        dd if=/dev/zero of="${TEST_DIR}/fio_temp" bs=1M count=512 >/dev/null 2>&1
        clear_caches_thoroughly
        fio_output_file="${RESULTS_DIR}/fio_randread_run${run}.json"
        timeout 60 taskset -c 0 fio --name=randread --ioengine=libaio --iodepth=32 --rw=randread --bs=4k --direct=1 --size=512M --numjobs=$DEFAULT_NUM_JOBS --runtime=30 --time_based --group_reporting --directory="$TEST_DIR" --filename="fio_temp" --output-format=json --output="$fio_output_file" >/dev/null 2>&1
        iops=$(jq -r '.jobs[0].read.iops' "$fio_output_file")
        results_rand_read[$run]=${iops:-0}
        printf "Result: %.0f IOPS\n" "${iops:-0}"
        rm -f "${TEST_DIR}/fio_temp"

        # 5. Small File Creation
        print_test_header "Test 5: Small File Creation"
        local small_files_dir="${TEST_DIR}/small_files"
        mkdir -p "$small_files_dir" && sync
        local start_time; start_time=$(date +%s.%N)
        for i in $(seq 1 "$DEFAULT_NUM_FILES"); do
            echo "test" > "${small_files_dir}/file_${i}"
            if [ $((i % 100)) -eq 0 ]; then show_progress "$i" "$DEFAULT_NUM_FILES" "Creating files" "$start_time"; fi
        done
        show_progress "$DEFAULT_NUM_FILES" "$DEFAULT_NUM_FILES" "Creating files" "$start_time"
        sync
        local end_time; end_time=$(date +%s.%N)
        local elapsed; elapsed=$(echo "$end_time - $start_time" | bc)
        results_file_create[$run]=$elapsed

        # 6. Small File Deletion
        print_test_header "Test 6: Small File Deletion"
        start_time=$(date +%s.%N)
        rm -rf "$small_files_dir"
        sync
        end_time=$(date +%s.%N)
        elapsed=$(echo "$end_time - $start_time" | bc)
        results_file_delete[$run]=$elapsed

        # 7. Mixed Read/Write
        print_test_header "Test 7: Mixed Read/Write (fio)"
        clear_caches_thoroughly
        fio_output_file="${RESULTS_DIR}/fio_mixed_run${run}.json"
        timeout 60 taskset -c 0 fio --name=mixed --ioengine=libaio --iodepth=32 \
            --rw=randrw --rwmixread=70 --bs=4k --direct=1 --size=512M \
            --numjobs=$DEFAULT_NUM_JOBS --runtime=30 --time_based --group_reporting \
            --directory="$TEST_DIR" --output-format=json \
            --output="$fio_output_file" >/dev/null 2>&1
        results_mixed_read[$run]=$(jq -r '.jobs[0].read.iops' "$fio_output_file")
        results_mixed_write[$run]=$(jq -r '.jobs[0].write.iops' "$fio_output_file")
        printf "Result: Read %.0f IOPS, Write %.0f IOPS\n" "${results_mixed_read[$run]:-0}" "${results_mixed_write[$run]:-0}"
        rm -f "${TEST_DIR}/fio_temp"

        # 8. Directory Creation
        print_test_header "Test 8: Directory Creation"
        local dirs_dir="${TEST_DIR}/test_dirs"
        mkdir -p "$dirs_dir" && sync
        start_time=$(date +%s.%N)
        for i in $(seq 1 "$DEFAULT_NUM_FILES"); do
            mkdir "${dirs_dir}/dir_${i}"
            if [ $((i % 100)) -eq 0 ]; then show_progress "$i" "$DEFAULT_NUM_FILES" "Creating directories" "$start_time"; fi
        done
        show_progress "$DEFAULT_NUM_FILES" "$DEFAULT_NUM_FILES" "Creating directories" "$start_time"
        sync
        end_time=$(date +%s.%N)
        elapsed=$(echo "$end_time - $start_time" | bc)
        results_dir_create[$run]=$elapsed
        rm -rf "$dirs_dir"
        
        dmesg -T | tail -30 >> "$RESULTS_DIR/dmesg_after_run_${run}.log"
    done

    # --- Finalize and Summarize ---
    exec > /dev/tty 2>&1 # Restore stdout
    
    printf "\n\n${GREEN}╔════════════════════════════════════════╗${NC}\n"
    printf "${GREEN}║         BENCHMARK RESULTS SUMMARY        ║${NC}\n"
    printf "${GREEN}╚════════════════════════════════════════╝${NC}\n\n"

    # Convert associative arrays to indexed arrays for statistical functions
    local seq_write_vals=("${results_seq_write[@]}")
    local seq_read_vals=("${results_seq_read[@]}")
    local rand_write_vals=("${results_rand_write[@]}")
    local rand_read_vals=("${results_rand_read[@]}")
    local mixed_read_vals=("${results_mixed_read[@]}")
    local mixed_write_vals=("${results_mixed_write[@]}")
    local file_create_vals=("${results_file_create[@]}")
    local file_delete_vals=("${results_file_delete[@]}")
    local dir_create_vals=("${results_dir_create[@]}")

    print_enhanced_summary "Sequential Write (MB/s)" "${seq_write_vals[*]}"
    print_ascii_chart "Sequential Write (MB/s) - All Runs" "${seq_write_vals[*]}"
    print_enhanced_summary "Sequential Read (MB/s)" "${seq_read_vals[*]}"
    print_ascii_chart "Sequential Read (MB/s) - All Runs" "${seq_read_vals[*]}"
    print_enhanced_summary "Random Write (IOPS)" "${rand_write_vals[*]}"
    print_ascii_chart "Random Write (IOPS) - All Runs" "${rand_write_vals[*]}"
    print_enhanced_summary "Random Read (IOPS)" "${rand_read_vals[*]}"
    print_ascii_chart "Random Read (IOPS) - All Runs" "${rand_read_vals[*]}"
    print_enhanced_summary "Mixed Read (IOPS)" "${mixed_read_vals[*]}"
    print_ascii_chart "Mixed Read (IOPS) - All Runs" "${mixed_read_vals[*]}"
    print_enhanced_summary "Mixed Write (IOPS)" "${mixed_write_vals[*]}"
    print_ascii_chart "Mixed Write (IOPS) - All Runs" "${mixed_write_vals[*]}"
    print_enhanced_summary "File Creation Time (s)" "${file_create_vals[*]}"
    print_ascii_chart "File Creation Time (s) - All Runs" "${file_create_vals[*]}"
    print_enhanced_summary "File Deletion Time (s)" "${file_delete_vals[*]}"
    print_ascii_chart "File Deletion Time (s) - All Runs" "${file_delete_vals[*]}"
    print_enhanced_summary "Directory Creation Time (s)" "${dir_create_vals[*]}"
    print_ascii_chart "Directory Creation Time (s) - All Runs" "${dir_create_vals[*]}"

    # --- Save JSON Summary ---
    if command -v jq &> /dev/null; then
        cat > "$RESULTS_DIR/summary.json" << EOF
{
  "benchmark_name": "$BENCHMARK_NAME",
  "timestamp": "$TIMESTAMP",
  "kernel_version": "$(uname -r)",
  "device": "$DEVICE",
  "config": {
    "num_runs": $DEFAULT_NUM_RUNS,
    "num_files": $DEFAULT_NUM_FILES
  },
  "best_results": {
    "seq_write_mbps": $(get_max "${seq_write_vals[@]}"),
    "seq_read_mbps": $(get_max "${seq_read_vals[@]}"),
    "rand_write_iops": $(get_max "${rand_write_vals[@]}"),
    "rand_read_iops": $(get_max "${rand_read_vals[@]}"),
    "mixed_read_iops": $(get_max "${mixed_read_vals[@]}"),
    "mixed_write_iops": $(get_max "${mixed_write_vals[@]}"),
    "file_create_time": $(get_min "${file_create_vals[@]}"),
    "file_delete_time": $(get_min "${file_delete_vals[@]}"),
    "dir_create_time": $(get_min "${dir_create_vals[@]}")
  },
  "median_results": {
    "seq_write_mbps": $(get_median "${seq_write_vals[@]}"),
    "seq_read_mbps": $(get_median "${seq_read_vals[@]}"),
    "rand_write_iops": $(get_median "${rand_write_vals[@]}"),
    "rand_read_iops": $(get_median "${rand_read_vals[@]}"),
    "mixed_read_iops": $(get_median "${mixed_read_vals[@]}"),
    "mixed_write_iops": $(get_median "${mixed_write_vals[@]}"),
    "file_create_time": $(get_median "${file_create_vals[@]}"),
    "file_delete_time": $(get_median "${file_delete_vals[@]}"),
    "dir_create_time": $(get_median "${dir_create_vals[@]}")
  }
}
EOF
    fi
    
    check_throttling
    capture_system_state "$RESULTS_DIR/system_state_after.txt"
    
    printf "\n${GREEN}Benchmark Complete!${NC}\n"
    printf "Full logs and reports are in: %s\n" "$RESULTS_DIR"
    read -p "Press Enter to return to the main menu..."
    # Cleanup is handled by the trap
}

# Settings menu handler
handle_settings() {
    while true; do
        show_settings_menu
        local choice
        read -r choice

        case $choice in
            1)
                printf "\n"
                printf "Enter new mount point: "
                local new_mount
                read -r new_mount
                if [ -n "$new_mount" ]; then
                    DEFAULT_MOUNT_POINT="$new_mount"
                    printf "${GREEN}Mount point updated${NC}\n"
                fi
                sleep 1
                ;;
            2)
                printf "\n"
                printf "Enter number of runs (1-10): "
                local new_runs
                read -r new_runs
                if [[ "$new_runs" =~ ^[0-9]+$ ]] && [ "$new_runs" -ge 1 ] && [ "$new_runs" -le 10 ]; then
                    DEFAULT_NUM_RUNS="$new_runs"
                    printf "${GREEN}Number of runs updated${NC}\n"
                else
                    printf "${RED}Invalid number${NC}\n"
                fi
                sleep 1
                ;;
            3)
                printf "\n"
                printf "Enter number of test files (100-10000): "
                local new_files
                read -r new_files
                if [[ "$new_files" =~ ^[0-9]+$ ]] && [ "$new_files" -ge 100 ] && [ "$new_files" -le 10000 ]; then
                    DEFAULT_NUM_FILES="$new_files"
                    printf "${GREEN}Test files count updated${NC}\n"
                else
                    printf "${RED}Invalid number${NC}\n"
                fi
                sleep 1
                ;;
            4)
                printf "\n"
                printf "Enter number of FIO jobs (1-64): "
                local new_jobs
                read -r new_jobs
                if [[ "$new_jobs" =~ ^[0-9]+$ ]] && [ "$new_jobs" -ge 1 ] && [ "$new_jobs" -le 64 ]; then
                    DEFAULT_NUM_JOBS="$new_jobs"
                    printf "${GREEN}Number of FIO jobs updated${NC}\n"
                else
                    printf "${RED}Invalid number${NC}\n"
                fi
                sleep 1
                ;;
            5)
                printf "\n"
                printf "Enter new results location: "
                local new_location
                read -r new_location
                if [ -n "$new_location" ]; then
                    RESULTS_BASE_DIR="$new_location"
                    mkdir -p "$RESULTS_BASE_DIR"
                    printf "${GREEN}Results location updated${NC}\n"
                fi
                sleep 1
                ;;
            6)
                save_config
                ;;
            7)
                break
                ;;
            *)
                printf "${RED}Invalid option${NC}\n"
                sleep 1
                ;;
        esac
    done
}

# Main program loop
main() {
    load_config
    while true; do
        show_main_menu
        local choice
        read -r choice

        case $choice in
            1)
                run_benchmark
                ;;
            2)
                compare_benchmarks
                ;;
            3)
                list_benchmarks
                ;;
            4)
                delete_benchmark
                ;;
            5)
                view_benchmark_details
                ;;
            6)
                export_to_csv
                ;;
            7)
                handle_settings
                ;;
            8)
                show_performance_tips
                ;;
            9)
                clear
                printf "${GREEN}Thank you for using ext4 Benchmark Suite!${NC}\n"
                printf "\n"
                exit 0
                ;;
            *)
                printf "\n"
                printf "${RED}Invalid option. Please select 1-9.${NC}\n"
                sleep 1
                ;;
        esac
    done
}

# Create results directory if it doesn't exist
mkdir -p "$RESULTS_BASE_DIR"

# Start the program
main
