# Quick Start
## 1. Set up your workspace
```sh
WORKSPACE="/home/noswad/Desktop/my_reconstruction"
mkdir -p "$WORKSPACE"/images
```

## 2. Place your source video
Place your video file as `input.mp4` in the workspace directory, or adjust the extraction command accordingly.

Extraction of frames using FFMPEG
```sh
ffmpeg -i $WORKSPACE/input.mp4 \
  -vf "fps=5" \
  -q:v 2 \
  $WORKSPACE/images/frame_%04d.jpg
```

COLMAP feature extraction (what do it do?)
```sh
colmap feature_extractor \
	--image_path IMAGES \
	--database_path DATABASE
```

COLMAP exhaustive matching (what do it do?)
```sh
colmap exhaustive_matcher \
	--database_path DATABASE
```

COLMAP mapping
```sh
colmap mapper \
	--database_path $WORKSPACE/database.db \
   --image_path    $WORKSPACE/images \
   --output_path   $WORKSPACE/sparse
```

Or the better, faster option (why?)

GLOMAP global mapping
```sh
glomap mapper \
	--database_path $WORKSPACE/database.db \
	--output_path $WORKSPACE/sparse \
	--image_path $WORKSPACE/images
```

# Pipeline Stages Explained
### 1. Frame Extraction (extract-frames)
Extracts individual frames from your input video using FFMPEG.

- Rate: 5 frames per second (adjustable)
- Quality: High quality JPEG (q:v 2)
- Output: Sequential frames in images/ directory

### 2. Feature Extraction (extract-features)
Detects and describes keypoints in each image using SIFT (Scale-Invariant Feature Transform).

- Purpose: Identifies distinctive visual features that can be matched across images
- GPU accelerated: Significantly faster than CPU processing
- Output: Features stored in database.db

### 3. Feature Matching (match-features)
Finds correspondences between features across all image pairs.

Method: Exhaustive matching (compares every image to every other image)
Purpose: Establishes which features represent the same 3D points
GPU accelerated: Essential for large datasets
Output: Match relationships stored in database.db

### 4. 3D Reconstruction
#### COLMAP Mapper (reconstruct-colmap)

- Traditional incremental Structure-from-Motion (SfM)
- Builds reconstruction by progressively adding images
- More robust for difficult sequences
- Slower but handles complex scenarios well

#### GLOMAP Mapper (reconstruct-glomap) ⭐ Recommended

- Global Structure-from-Motion approach
- Processes all images simultaneously
- Significantly faster (often 10-100x speedup)
- More efficient memory usage
- Better for drone footage and well-distributed camera positions
- Output: Sparse 3D point cloud and camera poses in sparse/ directory



## Output Structure
```sh
$WORKSPACE/
├── input.mp4              # Your source video
├── database.db            # COLMAP feature database
├── images/                # Extracted frames
│   ├── frame_0001.jpg
│   ├── frame_0002.jpg
│   └── ...
└── sparse/                # 3D reconstruction output
    └── 0/
        ├── cameras.bin    # Camera intrinsics
        ├── images.bin     # Camera poses
        └── points3D.bin   # 3D point cloud
```