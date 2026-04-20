#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# run_dragen_mock.sh — Dry-run stub for end-to-end GCP infrastructure testing.
#
# Mimics the output structure of run_dragen.sh without executing DRAGEN or
# consuming any DRAGEN license credits. All env vars are identical to the
# production run; only the processing step is replaced with a 20-second sleep.
#
# Invoked automatically when the pipeline is launched with -profile test
# (params.dry_run = true in nextflow.config).
#
# Required env vars (set by modules/dragen/main.nf):
#   SAMPLE_ID    — sample identifier
#   BUCKET_NAME  — GCS bucket (outputs written to gs://<bucket>/output_files/)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

echo "[MOCK] ── Dry-run DRAGEN ─────────────────────────────────────────────"
echo "[MOCK] Sample  : ${SAMPLE_ID}"
echo "[MOCK] Bucket  : gs://${BUCKET_NAME}"
echo "[MOCK] Simulating DRAGEN processing (sleeping 20 s) ..."
sleep 20

OUTPUT_DIR="gs://${BUCKET_NAME}/output_files/${SAMPLE_ID}"

echo "[MOCK] Writing dummy output files to ${OUTPUT_DIR}/"

# Write a one-line stub file to GCS
put() {
    echo "mock-file: ${SAMPLE_ID} $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        | gsutil cp -q - "$1"
}

put "${OUTPUT_DIR}/${SAMPLE_ID}.cram"
put "${OUTPUT_DIR}/${SAMPLE_ID}.cram.crai"
put "${OUTPUT_DIR}/${SAMPLE_ID}.hard-filtered.vcf.gz"
put "${OUTPUT_DIR}/${SAMPLE_ID}.hard-filtered.vcf.gz.tbi"
put "${OUTPUT_DIR}/${SAMPLE_ID}.gvcf.gz"
put "${OUTPUT_DIR}/${SAMPLE_ID}.gvcf.gz.tbi"
put "${OUTPUT_DIR}/${SAMPLE_ID}.cnv.vcf.gz"
put "${OUTPUT_DIR}/${SAMPLE_ID}.sv.vcf.gz"
put "${OUTPUT_DIR}/${SAMPLE_ID}.hla.tsv"
put "${OUTPUT_DIR}/${SAMPLE_ID}_metrics.csv"
put "${OUTPUT_DIR}/Software_run_$(date -u +%Y%m%dT%H%M%S)_usage.txt"
put "${OUTPUT_DIR}/logs/dragen.log"

# file_manifest.md5 is the completion sentinel checked by generate_samplesheet.py
put "${OUTPUT_DIR}/file_manifest.md5"

echo "[MOCK] Dry-run complete for sample: ${SAMPLE_ID}"
