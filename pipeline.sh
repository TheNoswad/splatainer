#!/bin/bash
set -e

WORKSPACE="/workspace"
DATABASE="$WORKSPACE/database.db"
IMAGES="$WORKSPACE/images"
SPARSE="$WORKSPACE/sparse"
INPUT_VIDEO="$WORKSPACE/input.mp4"
FPS=5
USE_COLMAP=false
FORCE_EXTRACT=false

# Color output - use echo -e for proper interpretation
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

check_ffmpeg() {
    if ! command -v ffmpeg &> /dev/null; then
        log_error "FFMPEG not found! Please install ffmpeg in the container."
        exit 1
    fi
}

detect_gpu() {
    # Check for NVIDIA GPU
    if command -v nvidia-smi &> /dev/null && nvidia-smi &> /dev/null; then
        echo "nvidia"
        return
    fi

    # Check for AMD GPU
    if [ -d "/dev/dri" ] && [ -e "/dev/dri/renderD128" ]; then
        echo "amd"
        return
    fi

    echo "cpu"
}

show_gpu_info() {
    local gpu_type=$(detect_gpu)

    case $gpu_type in
        nvidia)
            log_info "NVIDIA GPU detected - full acceleration available"
            ;;
        amd)
            log_info "AMD GPU detected - video decoding acceleration available"
            log_warn "COLMAP only supports NVIDIA CUDA - will use CPU for feature extraction/matching"
            ;;
        cpu)
            log_warn "No GPU detected - will use CPU for all operations (slower)"
            ;;
    esac
}

extract_frames() {
    log_step "1/4 Extracting frames from video with FFMPEG..."

    check_ffmpeg

    # Check if images already exist
    if [ -d "$IMAGES" ] && [ -n "$(find "$IMAGES" -maxdepth 1 -name "*.jpg" -print -quit 2>/dev/null)" ]; then
        local existing_count=$(find "$IMAGES" -maxdepth 1 -name "*.jpg" | wc -l)

        if [ "$FORCE_EXTRACT" = true ]; then
            log_warn "Found $existing_count existing images - removing due to --force flag"
            rm -f "$IMAGES"/*.jpg
        else
            log_warn "Found $existing_count existing images in $IMAGES - skipping frame extraction"
            log_info "Use --force to re-extract frames"
            return 0
        fi
    fi

    if [ ! -f "$INPUT_VIDEO" ]; then
        log_error "Input video not found: $INPUT_VIDEO"
        log_info "Please place your video as 'input.mp4' in the workspace directory"
        exit 1
    fi

    mkdir -p "$IMAGES"

    # Get video info
    log_info "Video: $(basename "$INPUT_VIDEO")"

    # Detect GPU type and use appropriate acceleration
    local gpu_type=$(detect_gpu)

    case $gpu_type in
        nvidia)
            # NVIDIA GPU - try CUDA acceleration
            if ffmpeg -hwaccel cuda -i "$INPUT_VIDEO" \
                -vf "fps=$FPS,hwdownload,format=nv12,format=yuv420p" \
                -q:v 2 \
                "$IMAGES/frame_%04d.jpg" \
                -y 2>/dev/null; then
                log_info "✓ Used NVIDIA GPU acceleration (CUDA) for decoding"
            else
                log_warn "CUDA decoding failed, falling back to CPU..."
                ffmpeg -i "$INPUT_VIDEO" \
                    -vf "fps=$FPS" \
                    -q:v 2 \
                    "$IMAGES/frame_%04d.jpg" \
                    -y
            fi
            ;;
        amd)
            # AMD GPU - try VAAPI acceleration
            if ffmpeg -hwaccel vaapi -hwaccel_device /dev/dri/renderD128 \
                -hwaccel_output_format vaapi \
                -i "$INPUT_VIDEO" \
                -vf "fps=$FPS,hwdownload,format=nv12" \
                -q:v 2 \
                "$IMAGES/frame_%04d.jpg" \
                -y 2>/dev/null; then
                log_info "✓ Used AMD GPU acceleration (VAAPI) for decoding"
            else
                log_warn "VAAPI decoding failed, falling back to CPU..."
                ffmpeg -i "$INPUT_VIDEO" \
                    -vf "fps=$FPS" \
                    -q:v 2 \
                    "$IMAGES/frame_%04d.jpg" \
                    -y
            fi
            ;;
        cpu)
            # No GPU - CPU only
            log_info "Using CPU for decoding..."
            ffmpeg -i "$INPUT_VIDEO" \
                -vf "fps=$FPS" \
                -q:v 2 \
                "$IMAGES/frame_%04d.jpg" \
                -y
            ;;
    esac

    local frame_count=$(find "$IMAGES" -maxdepth 1 -name "*.jpg" 2>/dev/null | wc -l)
    log_info "✓ Extracted $frame_count frames at ${FPS} fps"
}

extract_features() {
    log_step "2/4 Extracting image features with COLMAP..."

    if [ ! -d "$IMAGES" ] || [ -z "$(ls -A $IMAGES/*.jpg 2>/dev/null)" ]; then
        log_error "No images found in $IMAGES"
        log_info "Run 'extract-frames' first"
        exit 1
    fi

    local image_count=$(find "$IMAGES" -maxdepth 1 -name "*.jpg" | wc -l)
    log_info "Processing $image_count images..."

    # Check GPU availability
    local gpu_type=$(detect_gpu)

    case $gpu_type in
        nvidia)
            log_info "Attempting GPU-accelerated feature extraction..."
            ;;
        amd)
            log_warn "AMD GPU detected but COLMAP only supports NVIDIA CUDA"
            log_info "Using CPU for feature extraction (this may be slower)..."
            ;;
        cpu)
            log_info "Using CPU for feature extraction..."
            ;;
    esac

    # Always disable GPU to avoid CUDA errors - COLMAP will use GPU if available and working
    # The --SiftExtraction.use_gpu flag is unreliable, so we let COLMAP auto-detect
    CUDA_VISIBLE_DEVICES="" colmap feature_extractor \
        --image_path "$IMAGES" \
        --database_path "$DATABASE" \
        --ImageReader.camera_model SIMPLE_RADIAL \
        --ImageReader.single_camera 1

    log_info "✓ Feature extraction complete"
}

match_features() {
    log_step "3/4 Matching features across images..."

    if [ ! -f "$DATABASE" ]; then
        log_error "Database not found: $DATABASE"
        log_info "Run 'extract-features' first"
        exit 1
    fi

    # Check GPU availability
    local gpu_type=$(detect_gpu)

    case $gpu_type in
        nvidia)
            log_info "Attempting GPU-accelerated matching..."
            ;;
        amd)
            log_warn "AMD GPU detected but COLMAP only supports NVIDIA CUDA"
            log_info "Running exhaustive matching on CPU (this may be slower)..."
            ;;
        cpu)
            log_info "Running exhaustive matching on CPU..."
            ;;
    esac

    # Disable GPU to avoid CUDA errors
    CUDA_VISIBLE_DEVICES="" colmap exhaustive_matcher \
        --database_path "$DATABASE"

    log_info "✓ Feature matching complete"
}

reconstruct_colmap() {
    log_step "4/4 Running COLMAP incremental mapper..."

    mkdir -p "$SPARSE"

    log_info "This may take a while for large datasets..."

    colmap mapper \
        --database_path "$DATABASE" \
        --image_path "$IMAGES" \
        --output_path "$SPARSE"

    log_info "✓ COLMAP reconstruction complete"
}

reconstruct_glomap() {
    log_step "4/4 Running GLOMAP global mapper..."

    mkdir -p "$SPARSE"

    log_info "GLOMAP is typically 10-100x faster than COLMAP!"

    glomap mapper \
        --database_path "$DATABASE" \
        --output_path "$SPARSE" \
        --image_path "$IMAGES"

    log_info "✓ GLOMAP reconstruction complete"
}

full_pipeline() {
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}  COLMAP/GLOMAP Reconstruction Pipeline${NC}"
    echo -e "${GREEN}=========================================${NC}"
    echo ""

    # Show system info
    show_gpu_info
    echo ""

    extract_frames
    echo ""
    extract_features
    echo ""
    match_features
    echo ""

    if [ "$USE_COLMAP" = true ]; then
        reconstruct_colmap
    else
        reconstruct_glomap
    fi

    echo ""
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}  Pipeline Complete!${NC}"
    echo -e "${GREEN}=========================================${NC}"
    log_info "Results available in: $SPARSE"

    # Check if reconstruction was successful
    if [ -d "$SPARSE/0" ] && [ -f "$SPARSE/0/cameras.bin" ]; then
        log_info "✓ Reconstruction successful"
        log_info "  - Camera parameters: $SPARSE/0/cameras.bin"
        log_info "  - Camera poses: $SPARSE/0/images.bin"
        log_info "  - 3D points: $SPARSE/0/points3D.bin"
    else
        log_warn "Reconstruction may have failed. Check output above for errors."
    fi
}

show_usage() {
    echo -e "${GREEN}COLMAP/GLOMAP Photogrammetry Pipeline${NC}"
    echo ""
    echo -e "${YELLOW}Usage:${NC} $0 [COMMAND] [OPTIONS]"
    echo ""
    echo -e "${YELLOW}Commands:${NC}"
    echo -e "  ${BLUE}full-pipeline${NC}       Run entire pipeline (DEFAULT if no command given)"
    echo "  extract-frames       Extract frames from input video with FFMPEG"
    echo "  extract-features     Extract image features with COLMAP"
    echo "  match-features       Match features across images"
    echo "  reconstruct-colmap   3D reconstruction with COLMAP (slower, robust)"
    echo "  reconstruct-glomap   3D reconstruction with GLOMAP (faster, recommended)"
    echo ""
    echo -e "${YELLOW}Options:${NC}"
    echo "  --fps <rate>         Frame extraction rate (default: 5)"
    echo "  --input <file>       Input video file (default: input.mp4)"
    echo "  --use-colmap         Use COLMAP instead of GLOMAP for reconstruction"
    echo "  --force              Force re-extraction of frames even if they exist"
    echo "  -h, --help           Show this help message"
    echo ""
    echo -e "${YELLOW}Examples:${NC}"
    echo "  # Run full pipeline (automatic)"
    echo "  $0"
    echo ""
    echo "  # Run full pipeline (explicit)"
    echo "  $0 full-pipeline"
    echo ""
    echo "  # Force re-extract frames"
    echo "  $0 full-pipeline --force"
    echo ""
    echo "  # Custom frame rate"
    echo "  $0 full-pipeline --fps 10"
    echo ""
    echo "  # Specific video file"
    echo "  $0 full-pipeline --input drone_footage.mp4"
    echo ""
    echo "  # Use COLMAP instead of GLOMAP"
    echo "  $0 full-pipeline --use-colmap"
    echo ""
    echo "  # Individual steps"
    echo "  $0 extract-frames --fps 8"
    echo "  $0 extract-features"
    echo "  $0 match-features"
    echo "  $0 reconstruct-glomap"
    echo ""
    echo -e "${YELLOW}GPU Support:${NC}"
    echo "  - NVIDIA: Full GPU acceleration (CUDA) for all stages"
    echo "  - AMD: GPU acceleration for video decoding (VAAPI), CPU for COLMAP"
    echo "  - CPU-only: All processing on CPU (slower but functional)"
    echo ""
    echo -e "${YELLOW}Requirements:${NC}"
    echo "  - Place video as 'input.mp4' in workspace directory"
    echo "  - GPU recommended for feature extraction/matching"
    echo "  - Minimum 8GB VRAM recommended for large datasets with GPU"
    echo ""
}

# Parse arguments
COMMAND="${1:-full-pipeline}"

# If first arg is an option, default to full-pipeline
if [[ "$COMMAND" == --* ]]; then
    COMMAND="full-pipeline"
else
    shift || true
fi

while [[ $# -gt 0 ]]; do
    case $1 in
        --fps)
            FPS="$2"
            shift 2
            ;;
        --input)
            INPUT_VIDEO="$WORKSPACE/$2"
            shift 2
            ;;
        --use-colmap)
            USE_COLMAP=true
            shift
            ;;
        --force)
            FORCE_EXTRACT=true
            shift
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Execute command
case $COMMAND in
    extract-frames)
        extract_frames
        ;;
    extract-features)
        extract_features
        ;;
    match-features)
        match_features
        ;;
    reconstruct-colmap)
        reconstruct_colmap
        ;;
    reconstruct-glomap)
        reconstruct_glomap
        ;;
    full-pipeline)
        full_pipeline
        ;;
    help|--help|-h)
        show_usage
        exit 0
        ;;
    *)
        log_error "Unknown command: $COMMAND"
        echo ""
        show_usage
        exit 1
        ;;
esac
