#!/bin/bash
set -e -o pipefail

echo "Starting DRAGEN pipeline execution..."
echo "Sample ID: ${SAMPLE_ID}"
echo "DRAGEN version: ${DRAGEN_VERSION}"
echo "Bucket: gs://${BUCKET_NAME}"
echo "Using spot instance: ${USE_SPOT}"

# Configure gcloud to use the compute engine service account
SERVICE_ACCOUNT=$(curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email)
echo "Service Account: ${SERVICE_ACCOUNT}"

# Set gcloud account and activate service account authentication
gcloud config set account ${SERVICE_ACCOUNT} > /dev/null 2>&1

# Get access token and authenticate
echo "Authenticating with service account..."
ACCESS_TOKEN=$(curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token | \
  python3 -c "import sys, json; print(json.load(sys.stdin)['access_token'])")

if [ -z "$ACCESS_TOKEN" ]; then
    echo "ERROR: Failed to obtain access token from metadata service"
    exit 1
fi

# Use the token for gcloud authentication
echo "$ACCESS_TOKEN" | gcloud auth application-default print-access-token > /dev/null 2>&1

# Verify authentication works
echo "Verifying GCS access..."
if ! gcloud storage ls gs://${BUCKET_NAME}/ > /dev/null 2>&1; then
    echo "ERROR: Cannot access bucket gs://${BUCKET_NAME}/"
    echo "Service account ${SERVICE_ACCOUNT} may not have storage permissions"
    exit 1
fi
echo "✓ GCS access verified"
echo ""

# Set ulimit
ulimit -n 65535

# Download DRAGEN license credentials file
echo "Downloading DRAGEN license credentials..."
mkdir -p /opt/dragen_license
gcloud storage cp "${LICENSE_CREDENTIALS_PATH}" /opt/dragen_license/dragen_credentials.txt 2>&1
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to download DRAGEN license credentials"
    exit 1
fi
echo "License credentials downloaded successfully"

# Download and install DRAGEN
echo "Downloading DRAGEN binary..."
mkdir -p /opt/dragen
gcloud storage cp "gs://${BUCKET_NAME}/tools/${DRAGEN_BIN}" /opt/dragen/ 2>&1
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to download DRAGEN binary"
    exit 1
fi
echo "DRAGEN binary downloaded successfully"

chmod +x "/opt/dragen/${DRAGEN_BIN}"
cd /opt/dragen
"./${DRAGEN_BIN}"

# Export DRAGEN to PATH
BASE_PATH=$(basename ${DRAGEN_BIN} .bin)
export PATH="/opt/dragen/${BASE_PATH}/bin:${PATH}"

# Create working directories
mkdir -p /mnt/disks/work/reference
mkdir -p /mnt/disks/work/sample
mkdir -p /mnt/disks/work/results

# Download reference genome (hash table)
echo "Downloading reference genome..."
gcloud storage cp -r "${REFERENCE_PATH}" /mnt/disks/work/reference/ 2>&1
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to download reference genome"
    exit 1
fi
echo "Reference genome downloaded successfully"

# Download input FASTQ files for this sample
echo "Downloading input FASTQ files..."
gcloud storage cp "gs://${BUCKET_NAME}/input_genomes/${SAMPLE_ID}/*.fastq.gz" /mnt/disks/work/sample/ 2>&1
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to download FASTQ files"
    exit 1
fi
echo "FASTQ files downloaded successfully"

# Set up variables
REF="/mnt/disks/work/reference/$(basename ${REFERENCE_PATH})"
OUT_DIR="/mnt/disks/work/results/${SAMPLE_ID}"
mkdir -p ${OUT_DIR}

# Create FASTQ list CSV file
echo "Creating FASTQ list CSV file..."
FASTQ_LIST="${OUT_DIR}/fastq_list.csv"

# Write CSV header
echo "RGID,RGSM,RGLB,Lane,Read1File,Read2File" > ${FASTQ_LIST}

# Get all R1 files and pair them with R2 files
R1_FILES=$(ls /mnt/disks/work/sample/*_R1*.fastq.gz | sort)

# Generate CSV entries
LANE=1
for R1_FILE in $R1_FILES; do
    # Derive R2 file name from R1 file name
    R2_FILE=$(echo $R1_FILE | sed 's/_R1/_R2/')
    
    # Verify R2 file exists
    if [ ! -f "$R2_FILE" ]; then
        echo "ERROR: R2 file not found for $R1_FILE"
        exit 1
    fi
    
    # Generate read group ID based on sample and lane
    RGID="${SAMPLE_ID}.${LANE}"
    
    # Add entry to CSV
    echo "${RGID},${SAMPLE_ID},UnknownLibrary,${LANE},${R1_FILE},${R2_FILE}" >> ${FASTQ_LIST}
    
    LANE=$((LANE + 1))
done

echo "FASTQ list CSV created:"
cat ${FASTQ_LIST}
echo ""

# Run DRAGEN
echo "Running DRAGEN..."
dragen -f \
  --sw-mode \
  -r $REF \
  --fastq-list ${FASTQ_LIST} \
  --fastq-list-sample-id ${SAMPLE_ID} \
  --output-file-prefix $SAMPLE_ID \
  --output-directory $OUT_DIR \
  --enable-map-align true \
  --enable-map-align-output true \
  --enable-sort true \
  --enable-duplicate-marking true \
  --enable-cram-indexing true \
  --output-format CRAM \
  --cram-version 3.1 \
  --enable-variant-caller true \
  --vc-emit-ref-confidence GVCF \
  --vc-enable-vcf-output true \
  --enable-hla true \
  --enable-cnv true \
  --cnv-enable-self-normalization true \
  --enable-sv true \
  --repeat-genotype-enable true \
  --repeat-genotype-use-catalog expanded \
  --enable-targeted true \
  --targeted-merge-vc true \
  --enable-pgx true \
  --enable-mrjd true \
  --mrjd-enable-high-sensitivity-mode true \
  --logging-to-output-dir true \
  --syslogging-to-output-dir true \
  --lic-no-print \
  --lic-credentials /opt/dragen_license/dragen_credentials.txt 2>&1 | tee -a ${OUT_DIR}/stdouterr.txt

DRAGEN_EXIT_CODE=${PIPESTATUS[0]}
if [ $DRAGEN_EXIT_CODE -ne 0 ]; then
    echo "ERROR: DRAGEN failed with exit code $DRAGEN_EXIT_CODE"
    exit 1
fi
echo "DRAGEN completed successfully"

# Upload results to GCS
echo "Uploading results to GCS..."

# First, move logs to logs subdirectory before uploading
echo "Organizing log files..."
mkdir -p ${OUT_DIR}/logs
mv ${OUT_DIR}/*.log ${OUT_DIR}/logs/ 2>/dev/null || true
cp ${OUT_DIR}/stdouterr.txt ${OUT_DIR}/logs/ 2>/dev/null || true

# Create a manifest file with checksums for data integrity verification
echo "Generating file manifest with checksums..."
MANIFEST_FILE="${OUT_DIR}/file_manifest.md5"
cd ${OUT_DIR}
# Use -print0 and xargs -0 to handle filenames with special characters
find . -type f -print0 | xargs -0 md5sum | sort -k 2 > ${MANIFEST_FILE}
if [ -f ${MANIFEST_FILE} ] && [ -s ${MANIFEST_FILE} ]; then
    echo "Manifest created with $(wc -l < ${MANIFEST_FILE}) files"
else
    echo "WARNING: Manifest file is empty or not created, but continuing..."
fi

# Upload files, handling non-existent files gracefully
echo "Uploading output files..."
for item in *; do
    if [ -e "$item" ]; then
        echo "Uploading $item..."
        gcloud storage cp -r "${OUT_DIR}/${item}" "gs://${BUCKET_NAME}/output_files/${SAMPLE_ID}/" 2>&1 || {
            echo "WARNING: Failed to upload ${item}, continuing..."
        }
    fi
done

# Verify DRAGEN reported success by checking the log file
echo "Verifying DRAGEN completion status..."
DRAGEN_LOG=$(ls ${OUT_DIR}/logs/dragen_run_*.log 2>/dev/null | head -n1)
if [ -n "$DRAGEN_LOG" ]; then
    if grep -q "DRAGEN finished normally" "$DRAGEN_LOG"; then
        echo "✓ DRAGEN log confirms successful completion"
    else
        echo "ERROR: DRAGEN log does not contain 'DRAGEN finished normally' message"
        echo "Pipeline may have failed - check logs for details"
        exit 1
    fi
else
    echo "ERROR: Could not find DRAGEN log file to verify completion"
    exit 1
fi

echo "Results uploaded successfully"

echo "=========================================="
echo "DRAGEN pipeline completed successfully!"
echo "=========================================="

# Display DRAGEN usage statistics
echo ""
echo "=========================================="
echo "DRAGEN License Usage for this run:"
echo "=========================================="

# Find and display the usage file
USAGE_FILE=$(find ${OUT_DIR} -name "Software_run_*_usage.txt" 2>/dev/null | head -n1)
if [ -n "$USAGE_FILE" ]; then
    echo "Usage file: $(basename $USAGE_FILE)"
    cat "$USAGE_FILE"
    
    # Convert bases to Tbases for easier reading
    BASES_USED=$(grep "Genome:" "$USAGE_FILE" | awk '{print $2}')
    if [ -n "$BASES_USED" ]; then
        TBASES_USED=$(echo "scale=6; $BASES_USED / 1000000000000" | bc)
        echo ""
        echo "Converted: ${TBASES_USED} Tbases used"
    fi
else
    echo "WARNING: Usage file not found in output directory"
fi

echo "=========================================="
echo ""

exit 0