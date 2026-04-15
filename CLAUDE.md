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

3. **GCP quota increase — MANDATORY before large-scale runs:**  
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

### Prepare a samplesheet
One sample ID per row, matching the folder name under `gs://<bucket>/input_genomes/<sample_id>/`.
```bash
# Copy and edit the template
cp assets/samplesheet_template.csv my_samples.csv
```

### Run the pipeline
```bash
nextflow run main.nf \
  --samplesheet my_samples.csv \
  -profile gcp
```

### Resume a failed or interrupted run
```bash
nextflow run main.nf \
  --samplesheet my_samples.csv \
  -profile gcp \
  -resume
```
Nextflow skips any sample that already completed successfully, using its local cache (`./work/` bookkeeping in GCS).

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
| `modules/dragen/main.nf` | DRAGEN process. Exports env vars and calls `run_dragen.sh`. |
| `app/run_dragen.sh` | Core pipeline logic: auth, download, DRAGEN execution, upload. Not Nextflow-aware. |
| `app/Dockerfile` | Container image (Rocky Linux 8 + Python 3.11 + gcloud CLI). DRAGEN binary is downloaded at runtime, not baked in. |
| `assets/samplesheet_template.csv` | Sample sheet template. |

---

## GCS Data Layout

```
gs://<bucket>/
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
└── nextflow-work/          ← Nextflow bookkeeping only (not DRAGEN outputs)
```

---

## Important Constraints

- **FASTQ naming**: Input files must follow `*_R1*` / `*_R2*` pattern — this is required by the pairing logic in `app/run_dragen.sh`.
- **DRAGEN binary naming**: Must follow `dragen-softwaremode-<version>.el8.x86_64.bin`. Controlled by the `dragen_version` parameter.
- **Container base**: Rocky Linux 8 (`rockylinux/rockylinux:8`) — required for DRAGEN binary compatibility.
- **DRAGEN version upgrades**: Update `params.dragen_version` in `nextflow.config`, place the new binary under `gs://<bucket>/tools/`, rebuild and push the Docker image if any install-step behaviour changed. The analysis flags in `run_dragen.sh` are intentionally fixed and should only be changed after validating against a new DRAGEN release.
- **License quota**: Track cumulative usage against `20251222_license_quota.json`. Past pilots have exhausted quotas; verify remaining capacity before large runs.
- **`-resume` behaviour**: Nextflow caches completed tasks. If you change `run_dragen.sh` or `nextflow.config` parameters between runs, cached results for affected samples will be invalidated and those samples will re-run.
