# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This project deploys [Illumina DRAGEN](https://www.illumina.com/products/by-type/informatics-products/dragen-secondary-analysis.html) (Dynamic Read Analysis for GENomics) at scale on Google Cloud Platform using [Nextflow](https://nextflow.io) as the workflow manager. DRAGEN performs whole-genome alignment, variant calling, CNV/SV detection, HLA typing, and pharmacogenomics. The production target is 200k+ samples.

**GCP Project:** `YOUR_PROJECT_ID`  
**Region:** `us-west1` (fixed)  
**GCS Bucket:** `YOUR_BUCKET`  
**Reference genome:** `hg38-alt_masked.graph.cnv.hla.methyl_cg.rna_v5` (fixed for all samples)

---

## Prerequisites (head node GCE VM)

The Nextflow process runs on a persistent GCE VM. Before first use:

1. **Install Java and Nextflow:**
   ```bash
   sudo apt-get install -y default-jdk
   curl -s https://get.nextflow.io | bash
   sudo mv nextflow /usr/local/bin/
   ```

2. **Authenticate with GCP:**
   ```bash
   gcloud auth application-default login
   gcloud config set project YOUR_PROJECT_ID
   ```

3. **Install Python dependencies for the samplesheet script:**
   ```bash
   pip install -r scripts/requirements.txt
   ```

4. **GCP quota increase — MANDATORY before large-scale runs:**  
   The default quota for concurrent `c3d-standard-90` VMs in `us-west1` is typically 50–200. This will be exhausted immediately at production scale (200k samples). A quota increase must be requested from Google and confirmed **before** starting any large batch. This team has direct Google contact — this step should be straightforward but cannot be skipped.

---

## Key Commands

### Build and push Docker image
Rebuild whenever `app/Dockerfile` or `app/run_dragen.sh` changes.
```bash
export PROJECT_ID=YOUR_PROJECT_ID
export REGION=us-west1

docker build -t dragen-runner:latest -f app/Dockerfile .
docker tag dragen-runner:latest ${REGION}-docker.pkg.dev/${PROJECT_ID}/dragen/dragen-runner:latest
docker push ${REGION}-docker.pkg.dev/${PROJECT_ID}/dragen/dragen-runner:latest
```

### Prepare a samplesheet (manual)
One sample ID per row, matching the folder name under `gs://<bucket>/input_genomes/<sample_id>/`.
```bash
cp assets/samplesheet_template.csv my_samples.csv
```

### Generate samplesheet automatically (recommended for ongoing vendor ingestion)
Scans GCS for new samples and maintains a persistent status tracker in GCS.
```bash
pip install -r scripts/requirements.txt   # once, on the head node

# Check status (report only)
python scripts/generate_samplesheet.py

# Generate samplesheet of pending samples and mark them as submitted
python scripts/generate_samplesheet.py --submit --out my_samples.csv
```
Tracker stored at `gs://<bucket>/tracking/sample_tracker.csv`. States: `pending` → `submitted` → `completed` (detected via `file_manifest.md5`).

### Run the pipeline
```bash
nextflow run main.nf --samplesheet my_samples.csv
```

### Resume a failed or interrupted run
```bash
nextflow run main.nf --samplesheet my_samples.csv -resume
```
Nextflow skips any sample that already completed successfully, using its local cache (`./work/` bookkeeping in GCS).

### Dry-run — test GCP infrastructure without DRAGEN credits
Submits real Cloud Batch jobs (`e2-standard-4`) with a mock DRAGEN step (20 s sleep + dummy output files).
```bash
nextflow run main.nf --samplesheet test_samples.csv -profile test
```

### Override defaults at runtime
```bash
# Change DRAGEN version (e.g. when upgrading)
nextflow run main.nf --samplesheet my_samples.csv --dragen_version 4.4.9

# Reduce concurrency during a quota-constrained run
nextflow run main.nf --samplesheet my_samples.csv --queue_size 100

# Switch machine type — 5 options validated by Illumina (GCP-only costs, ~35x WGS):
# n2d-standard-96  2h51  $3.19/sample Spot   $10.03/sample Standard
# c3d-standard-60  3h15  $2.63/sample Spot   $9.75/sample  Standard
# c3d-standard-90  2h13  $2.39/sample Spot   $9.65/sample  Standard  ← default
# c4d-standard-64  2h29  $3.97/sample Spot   $8.55/sample  Standard
# c4d-standard-96  1h44  $3.78/sample Spot   $8.56/sample  Standard  ← fastest
nextflow run main.nf --samplesheet my_samples.csv --machine_type c4d-standard-96
```

### Monitor a running pipeline
```bash
# View submitted Cloud Batch jobs
gcloud batch jobs list --location=us-west1

# Stream logs for a specific job
gcloud logging read \
  'resource.type="batch.googleapis.com/Job"' \
  --project YOUR_PROJECT_ID \
  --limit 100
```

---

## Architecture

```
nextflow run main.nf
        │
        ▼
main.nf  ─── parses samplesheet → one value per sample ──────────────────┐
                                                                          │
                                                               (per sample, in parallel)
                                                                          │
                                                                          ▼
modules/dragen/main.nf  ── exports env vars ── calls /app/run_dragen.sh
                                                         │
                          ┌──────────────────────────────┤
                          │      Google Cloud Batch       │
                          │  (c3d-standard-90, 2000 GB)  │
                          │                              │
                          │  1. Authenticate via metadata │
                          │  2. Download DRAGEN binary   │
                          │  3. Install DRAGEN           │
                          │  4. Download reference + FASTQs
                          │  5. Run DRAGEN (full WGS)    │
                          │  6. Upload results to GCS    │
                          └──────────────────────────────┘
```

**Retry / spot strategy** (configured in `conf/gcp.config`):

| Attempt | Instance type | Reason |
|---------|--------------|--------|
| 1 | Spot | ~70% cost saving |
| 2 | Spot | Transient preemption retry |
| 3 | Spot | Final spot attempt |
| 4 | Standard | Guaranteed completion |

---

## File Roles

| File | Role |
|------|------|
| `main.nf` | Workflow entry point. Parses samplesheet, emits sample IDs into the DRAGEN process. |
| `nextflow.config` | All default parameters. The only file that needs editing for most operational changes (DRAGEN version, queue size, bucket name). |
| `conf/gcp.config` | GCP Batch executor settings: machine type, disk, spot directive, retry strategy, API rate limiting. |
| `modules/dragen/main.nf` | DRAGEN process. Exports env vars and calls `run_dragen.sh` (or `run_dragen_mock.sh` when `params.dry_run = true`). |
| `app/run_dragen.sh` | Core pipeline logic: auth, download, DRAGEN execution, upload. Not Nextflow-aware. |
| `app/run_dragen_mock.sh` | Dry-run stub: sleeps 20 s and writes dummy output files. Used by `-profile test`. |
| `app/Dockerfile` | Container image (Rocky Linux 8 + Python 3.11 + gcloud CLI). DRAGEN binary is downloaded at runtime, not baked in. |
| `scripts/generate_samplesheet.py` | Scans GCS for new samples, maintains `tracking/sample_tracker.csv`, generates samplesheets. |
| `scripts/requirements.txt` | Python dependency (`google-cloud-storage`) for `generate_samplesheet.py`. Install once on the head node. |
| `assets/samplesheet_template.csv` | Samplesheet template. |
| `secrets/dragen_credentials.txt` | Local reference copy of DRAGEN BYOL credentials (gitignored). The authoritative copy is in GCS at `gs://<bucket>/secrets/dragen_credentials.txt`. |

---

## GCS Data Layout

```
gs://<bucket>/
├── secrets/
│   └── dragen_credentials.txt  ← DRAGEN BYOL license file
├── tools/
│   └── dragen-softwaremode-<version>.el8.x86_64.bin
├── reference/
│   └── hg38-alt_masked.graph.cnv.hla.methyl_cg.rna_v5/
├── input_genomes/
│   └── <SAMPLE_ID>/
│       ├── *_R1*.fastq.gz
│       └── *_R2*.fastq.gz
├── output_files/
│   └── <SAMPLE_ID>/
│       ├── *.cram, *.crai
│       ├── *.hard-filtered.vcf.gz, *.gvcf.gz
│       ├── *.cnv.vcf.gz, *.sv.vcf.gz, *.hla.tsv
│       ├── *_metrics.csv
│       ├── file_manifest.md5
│       ├── Software_run_*_usage.txt
│       └── logs/
├── tracking/
│   └── sample_tracker.csv  ← Written by generate_samplesheet.py
└── nextflow-work/          ← Nextflow bookkeeping only (not DRAGEN outputs)
```

---

## Important Constraints

- **FASTQ naming**: Input files must follow `*_R1*` / `*_R2*` pattern — this is required by the pairing logic in `app/run_dragen.sh`.
- **DRAGEN binary naming**: Must follow `dragen-softwaremode-<version>.el8.x86_64.bin`. Controlled by the `dragen_version` parameter.
- **Container base**: Rocky Linux 8 (`rockylinux/rockylinux:8`) — required for DRAGEN binary compatibility.
- **Credentials location**: The DRAGEN license file must be at `gs://<bucket>/secrets/dragen_credentials.txt`. This path is the default value of `params.license_credentials_path` in `nextflow.config`. The local `secrets/` directory is gitignored — never commit credentials.
- **DRAGEN version upgrades**: Update `params.dragen_version` in `nextflow.config`, place the new binary under `gs://<bucket>/tools/`, rebuild and push the Docker image if any install-step behaviour changed. The analysis flags in `run_dragen.sh` are intentionally fixed and should only be changed after validating against a new DRAGEN release.
- **License quota**: Track cumulative usage against `legacy/20251222_license_quota.json`. Past pilots have exhausted quotas; verify remaining capacity before large runs.
- **`-resume` behaviour**: Nextflow caches completed tasks. If you change `run_dragen.sh` or `nextflow.config` parameters between runs, cached results for affected samples will be invalidated and those samples will re-run.
- **Dry-run profile**: `-profile test` sets `params.dry_run = true`, `e2-standard-4`, 50 GB disk, queue size 5. Rebuild the Docker image before testing if `run_dragen_mock.sh` has changed.
- **Shell safety**: Both `run_dragen.sh` and `run_dragen_mock.sh` use `set -euo pipefail`. Any unset environment variable or failed command will abort the job immediately, causing Nextflow to retry per the configured strategy.
- **GCS tool consistency**: Both scripts use `gcloud storage` (the modern CLI). Do not introduce `gsutil` calls — the two tools have different flag syntax and `gsutil` is deprecated in favour of `gcloud storage`.
