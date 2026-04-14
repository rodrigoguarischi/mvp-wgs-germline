# DRAGEN MVP — Google Cloud Platform

A production-ready Nextflow pipeline for running [Illumina DRAGEN](https://www.illumina.com/products/by-type/informatics-products/dragen-secondary-analysis.html) whole-genome analysis at scale on Google Cloud Batch.

DRAGEN performs alignment, variant calling (SNV/INDEL), copy number variant (CNV) detection, structural variant (SV) detection, HLA typing, repeat genotyping, pharmacogenomics (PGx), and multi-region joint detection (MRJD) — all in a single pass per sample.

This pipeline was validated on a 16-sample pilot at **~$2/sample** on GCP Spot instances and is designed to scale to **200,000+ samples**.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Repository Structure](#repository-structure)
3. [Prerequisites](#prerequisites)
4. [GCS Data Layout](#gcs-data-layout)
5. [Step-by-Step: First-Time Setup](#step-by-step-first-time-setup)
6. [Running the Pipeline](#running-the-pipeline)
7. [Monitoring](#monitoring)
8. [Outputs](#outputs)
9. [Spot Instance Strategy & Cost](#spot-instance-strategy--cost)
10. [Upgrading DRAGEN](#upgrading-dragen)
11. [Troubleshooting](#troubleshooting)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│  GCE VM (head node)                                             │
│                                                                 │
│  nextflow run main.nf --samplesheet my_samples.csv             │
│       │                                                         │
│       │  submits one Cloud Batch job per sample                 │
│       ▼                                                         │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  Google Cloud Batch  (c3d-standard-90, 2 TB SSD)         │   │
│  │                                                          │   │
│  │  Docker container (Rocky Linux 8 + gcloud CLI)           │   │
│  │       1. Authenticate via GCE metadata service           │   │
│  │       2. Download DRAGEN binary from GCS, install it     │   │
│  │       3. Download reference genome hash table            │   │
│  │       4. Download input FASTQs for this sample           │   │
│  │       5. Run DRAGEN (full WGS analysis)                  │   │
│  │       6. Upload results + MD5 manifest to GCS            │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                 │
│  Nextflow manages retries, concurrency, and resume             │
└─────────────────────────────────────────────────────────────────┘
```

**Retry strategy — spot preemption is handled automatically:**

| Attempt | Instance type | Reason |
|---------|--------------|--------|
| 1 | Spot | ~70% cost saving |
| 2 | Spot | Retry after transient preemption |
| 3 | Spot | Final spot attempt |
| 4 | Standard | Guaranteed completion |

Every sample is guaranteed to complete unless DRAGEN itself reports an error.

---

## Repository Structure

```
.
├── main.nf                        # Workflow entry point
├── nextflow.config                # All parameters and defaults
├── conf/
│   └── gcp.config                 # GCP Batch executor, machine, retry config
├── modules/
│   └── dragen/
│       └── main.nf                # DRAGEN process definition
├── app/
│   ├── Dockerfile                 # Container image definition
│   └── run_dragen.sh              # Core pipeline logic (runs inside container)
├── assets/
│   └── samplesheet_template.csv  # Sample sheet template
└── legacy/                        # Pre-Nextflow code — kept for reference only
```

---

## Prerequisites

### 1. GCP infrastructure (one-time setup)

The following GCP services must be enabled in project `YOUR_PROJECT_ID`:

```bash
gcloud services enable \
  batch.googleapis.com \
  compute.googleapis.com \
  storage.googleapis.com \
  logging.googleapis.com \
  artifactregistry.googleapis.com \
  --project YOUR_PROJECT_ID
```

The service account attached to Cloud Batch VMs needs these IAM roles:
- `roles/storage.objectAdmin` — read inputs, write outputs
- `roles/logging.logWriter` — write Cloud Logging entries
- `roles/batch.agentReporter` — required by Cloud Batch agents

### 2. ⚠️ GCP quota increase — MANDATORY before large-scale runs

> **This step is required before running more than ~50 samples in parallel.**

By default, GCP projects have a hard quota on the number of concurrent `c3d-standard-90` VMs in `us-west1` (typically 50–200). At 200k samples, this ceiling will be hit immediately.

**Action required:** Contact your Google account team and request a quota increase for `c3d-standard-90` instances in `us-west1` before starting any large batch. Confirm the new quota in the GCP Console under **IAM & Admin → Quotas** before proceeding.

The `queue_size` parameter in `nextflow.config` controls how many jobs Nextflow submits concurrently — set it to match (or stay safely below) your approved quota.

### 3. Head node GCE VM

Nextflow must run on a **persistent GCE VM** for the duration of a batch. It acts as the job controller — if it goes down, the run pauses (it can be resumed with `-resume`).

Recommended machine type: `e2-standard-2` (2 vCPU, 8 GB RAM) — inexpensive and more than sufficient.

**Install Java and Nextflow:**
```bash
sudo apt-get update && sudo apt-get install -y default-jdk curl
curl -s https://get.nextflow.io | bash
sudo mv nextflow /usr/local/bin/
nextflow -version   # verify installation, requires >=23.10.0
```

**Authenticate with GCP:**
```bash
gcloud auth application-default login
gcloud config set project YOUR_PROJECT_ID
```

### 4. Docker + Artifact Registry

The container image must be built and pushed before the first run. Rebuild it whenever `app/Dockerfile` or `app/run_dragen.sh` changes.

```bash
export PROJECT_ID=YOUR_PROJECT_ID
export REGION=us-west1

# Authenticate Docker with Artifact Registry
gcloud auth configure-docker ${REGION}-docker.pkg.dev

# Build and push
docker build -t dragen-runner:latest -f app/Dockerfile .
docker tag dragen-runner:latest \
  ${REGION}-docker.pkg.dev/${PROJECT_ID}/dragen/dragen-runner:latest
docker push \
  ${REGION}-docker.pkg.dev/${PROJECT_ID}/dragen/dragen-runner:latest
```

---

## GCS Data Layout

All data lives in a single GCS bucket. This layout must be in place before running the pipeline.

```
gs://YOUR_BUCKET/
│
├── tools/
│   └── dragen-softwaremode-4.4.7.el8.x86_64.bin   ← DRAGEN installer binary
│
├── reference/
│   └── hg38-alt_masked.graph.cnv.hla.methyl_cg.rna_v5/  ← Reference hash table
│
├── dragen_credentials.txt                           ← DRAGEN BYOL license file
│
├── input_genomes/
│   ├── SAMPLE001/
│   │   ├── SAMPLE001_R1.fastq.gz
│   │   └── SAMPLE001_R2.fastq.gz
│   ├── SAMPLE002/
│   │   └── ...
│   └── ...
│
└── output_files/                                    ← Written by the pipeline
    ├── SAMPLE001/
    │   ├── SAMPLE001.cram + .crai
    │   ├── SAMPLE001.hard-filtered.vcf.gz
    │   ├── SAMPLE001.gvcf.gz
    │   ├── SAMPLE001.cnv.vcf.gz
    │   ├── SAMPLE001.sv.vcf.gz
    │   ├── SAMPLE001.hla.tsv
    │   ├── *_metrics.csv
    │   ├── file_manifest.md5
    │   ├── Software_run_*_usage.txt
    │   └── logs/
    └── ...
```

**Important naming requirements:**
- Input FASTQs must follow the pattern `*_R1*.fastq.gz` / `*_R2*.fastq.gz`. The pipeline pairs R1 and R2 files automatically.
- Each sample's FASTQs must live in a folder named exactly after the `sample_id` in the samplesheet.

---

## Step-by-Step: First-Time Setup

This checklist takes a new deployment from zero to first run:

- [ ] Enable required GCP APIs (see [Prerequisites §1](#1-gcp-infrastructure-one-time-setup))
- [ ] Verify service account IAM roles
- [ ] Request and confirm `c3d-standard-90` quota increase (**mandatory**)
- [ ] Create and start the head node GCE VM
- [ ] Install Java and Nextflow on the head node
- [ ] Authenticate `gcloud` on the head node
- [ ] Upload DRAGEN binary to `gs://<bucket>/tools/`
- [ ] Upload reference genome hash table to `gs://<bucket>/reference/`
- [ ] Upload `dragen_credentials.txt` to `gs://<bucket>/dragen_credentials.txt`
- [ ] Upload input FASTQs to `gs://<bucket>/input_genomes/<sample_id>/`
- [ ] Build and push Docker image to Artifact Registry
- [ ] Clone this repository onto the head node
- [ ] Prepare samplesheet CSV
- [ ] Run a small test batch (2–3 samples) to validate end-to-end before the full run

---

## Running the Pipeline

### Prepare a samplesheet

Create a CSV with one `sample_id` per row. The sample ID must match the folder name under `gs://<bucket>/input_genomes/`.

```bash
cp assets/samplesheet_template.csv my_samples.csv
# Edit my_samples.csv — add one sample ID per line under the header
```

Example:
```
sample_id
SAMPLE001
SAMPLE002
SAMPLE003
```

### Launch the pipeline

```bash
nextflow run main.nf --samplesheet my_samples.csv
```

### Resume after interruption

If the head node VM stopped or the run was interrupted, resume from where it left off — already-completed samples are skipped:

```bash
nextflow run main.nf --samplesheet my_samples.csv -resume
```

### Override defaults at runtime

All parameters defined in `nextflow.config` can be overridden on the command line:

```bash
# Limit concurrency (e.g. while quota is being increased)
nextflow run main.nf --samplesheet my_samples.csv --queue_size 50

# Specify a different DRAGEN version
nextflow run main.nf --samplesheet my_samples.csv --dragen_version 4.4.9

# Run against a different bucket (e.g. staging environment)
nextflow run main.nf --samplesheet my_samples.csv \
  --bucket_name my-staging-bucket \
  --work_dir gs://my-staging-bucket/nextflow-work
```

---

## Monitoring

### Live pipeline progress (head node terminal)

Nextflow prints per-sample status to stdout while running. Keep the terminal session alive (use `tmux` or `screen` on the head node).

```bash
# Recommended: run inside a tmux session so it survives SSH disconnections
tmux new -s dragen
nextflow run main.nf --samplesheet my_samples.csv
```

### Cloud Batch job status

```bash
# List all active jobs
gcloud batch jobs list --location=us-west1

# Describe a specific job
gcloud batch jobs describe <job-name> --location=us-west1
```

### Cloud Logging (per-sample logs)

```bash
# Stream recent DRAGEN pipeline logs
gcloud logging read \
  'resource.type="batch.googleapis.com/Job" AND labels."project-name"="dragen-poc"' \
  --project YOUR_PROJECT_ID \
  --limit 100 \
  --format "value(timestamp, textPayload)"
```

Full per-sample DRAGEN logs are also uploaded to GCS at the end of each job:
```
gs://<bucket>/output_files/<sample_id>/logs/
```

---

## Outputs

For each sample, the pipeline writes to `gs://<bucket>/output_files/<sample_id>/`:

| File | Description |
|------|-------------|
| `<sample>.cram` + `.crai` | Aligned reads (CRAM v3.1) |
| `<sample>.hard-filtered.vcf.gz` | SNV/INDEL variant calls |
| `<sample>.gvcf.gz` | GVCF for joint genotyping |
| `<sample>.cnv.vcf.gz` | Copy number variants |
| `<sample>.sv.vcf.gz` | Structural variants |
| `<sample>.hla.tsv` | HLA typing results |
| `*_metrics.csv` | Mapping, coverage, and QC metrics |
| `file_manifest.md5` | MD5 checksums for all output files |
| `Software_run_*_usage.txt` | DRAGEN license usage (Tbases consumed) |
| `logs/` | Full DRAGEN run logs |

---

## Spot Instance Strategy & Cost

The pipeline was validated at **~$2/sample** using Spot VMs (`c3d-standard-90`, us-west1).

Spot VMs can be preempted by Google at any time. The pipeline handles this transparently:

1. **Attempts 1–3** use Spot VMs. Each retry starts fresh — DRAGEN downloads its inputs again and runs from scratch. This is intentional: DRAGEN analysis cannot be checkpointed.
2. **Attempt 4** uses a Standard (on-demand) VM, which guarantees capacity. Cost is approximately 3× higher than Spot for that one sample.

At scale, most samples will complete on the first or second Spot attempt. The Standard fallback exists to prevent any sample from getting stuck indefinitely due to sustained regional Spot scarcity.

**Cost note on the Standard fallback:** If Spot scarcity is high in `us-west1`, many samples may fall through to the Standard attempt, increasing average cost significantly. Monitor the ratio of Spot vs Standard completions in Cloud Logging if cost deviates from the expected $2/sample baseline.

---

## Upgrading DRAGEN

DRAGEN releases patch versions regularly (e.g. 4.4.4 → 4.4.6 → 4.4.7). To upgrade:

1. Upload the new binary to GCS:
   ```bash
   gsutil cp dragen-softwaremode-<new_version>.el8.x86_64.bin \
     gs://YOUR_BUCKET/tools/
   ```

2. Update `dragen_version` in `nextflow.config`:
   ```groovy
   dragen_version = '4.4.9'   // replace with new version
   ```

3. Test on a small batch (2–3 samples) before running at full scale.

> **Note:** The DRAGEN analysis flags in `app/run_dragen.sh` are intentionally not parameterised. They represent the validated production configuration and should only be changed after a formal validation run against a new DRAGEN major release.

---

## Troubleshooting

**Pipeline exits immediately with "Missing required parameter"**
→ Ensure `--samplesheet` is provided and the file exists.

**Jobs fail on all 4 attempts**
→ Check DRAGEN logs in `gs://<bucket>/output_files/<sample_id>/logs/`. Common causes: malformed FASTQs, missing R2 file, reference genome not found, license credentials expired.

**All Spot jobs are preempted instantly**
→ `us-west1` may have sustained Spot scarcity for `c3d-standard-90`. Consider temporarily switching to a different region or running with `--queue_size 10` to reduce competition.

**Jobs fail with "cannot access bucket" error**
→ The service account attached to the Cloud Batch VMs does not have `roles/storage.objectAdmin` on the bucket.

**Nextflow reports "work directory not writable"**
→ Verify the head node service account has write access to `gs://<bucket>/nextflow-work`.

**Cost significantly higher than $2/sample**
→ Check what fraction of samples fell back to Standard instances (attempt 4) using Cloud Logging. High Spot preemption rates in the region drive cost up.
