#!/usr/bin/env python3
"""
generate_samplesheet.py

Scans GCS for WGS samples, maintains a persistent status tracker, and
optionally generates a Nextflow-ready samplesheet for pending samples.

The tracker is stored at gs://<bucket>/tracking/sample_tracker.csv and is
shared across all operators. Run this script weekly (or on-demand) to pick
up new samples deposited by the sequencing vendor.

Sample lifecycle:
  pending    — detected in input_genomes/, not yet submitted to the pipeline
  submitted  — included in a samplesheet generated with --submit
  completed  — file_manifest.md5 found in output_files/<sample_id>/

Usage:
  # Report current status (read-only, no tracker changes except new discoveries)
  python scripts/generate_samplesheet.py

  # Generate samplesheet of all pending samples and mark them as submitted
  python scripts/generate_samplesheet.py --submit [--out pending.csv]

  # Use a different bucket
  python scripts/generate_samplesheet.py --bucket my-other-bucket

Requirements:
  pip install -r scripts/requirements.txt
"""

import argparse
import csv
import io
import sys
from datetime import datetime, timezone

from google.cloud import storage

# ─── Constants ────────────────────────────────────────────────────────────────

TRACKER_BLOB       = "tracking/sample_tracker.csv"
COMPLETION_SENTINEL = "file_manifest.md5"
COLS               = ["sample_id", "status", "date_detected", "date_submitted", "date_completed"]

# ─── GCS helpers ──────────────────────────────────────────────────────────────

def utcnow() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def list_subdirectories(client: storage.Client, bucket_name: str, prefix: str) -> set:
    """Return the set of immediate subdirectory names under prefix/."""
    blobs = client.list_blobs(bucket_name, prefix=prefix, delimiter="/")
    subdirs = set()
    for page in blobs.pages:
        for p in page.prefixes:
            name = p[len(prefix):].rstrip("/")
            if name:
                subdirs.add(name)
    return subdirs


def read_tracker(client: storage.Client, bucket_name: str) -> dict:
    """Load tracker CSV from GCS. Returns dict keyed by sample_id."""
    blob = client.bucket(bucket_name).blob(TRACKER_BLOB)
    if not blob.exists():
        return {}
    content = blob.download_as_text()
    return {row["sample_id"]: row for row in csv.DictReader(io.StringIO(content))}


def write_tracker(client: storage.Client, bucket_name: str, tracker: dict) -> None:
    """Write tracker dict back to GCS, sorted by date_detected."""
    output = io.StringIO()
    writer = csv.DictWriter(output, fieldnames=COLS)
    writer.writeheader()
    for row in sorted(tracker.values(), key=lambda r: r["date_detected"]):
        writer.writerow(row)
    client.bucket(bucket_name).blob(TRACKER_BLOB).upload_from_string(
        output.getvalue(), content_type="text/csv"
    )


def check_completed(client: storage.Client, bucket_name: str, sample_id: str) -> bool:
    """Return True if file_manifest.md5 exists for this sample."""
    blob = client.bucket(bucket_name).blob(
        f"output_files/{sample_id}/{COMPLETION_SENTINEL}"
    )
    return blob.exists()


# ─── Main ─────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Track WGS sample status and generate Nextflow samplesheets.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "--bucket",
        required=True,
        help="GCS bucket name containing input_genomes/, output_files/, and tracking/",
    )
    parser.add_argument(
        "--submit",
        action="store_true",
        help="Mark all pending samples as 'submitted' and write a samplesheet.",
    )
    parser.add_argument(
        "--out",
        default="pending_samples.csv",
        metavar="FILE",
        help="Output samplesheet path when using --submit (default: %(default)s)",
    )
    args = parser.parse_args()

    client = storage.Client()
    now    = utcnow()

    # ── 1. Load existing tracker ──────────────────────────────────────────────
    print(f"Reading tracker from gs://{args.bucket}/{TRACKER_BLOB} ...")
    tracker = read_tracker(client, args.bucket)

    # ── 2. Discover new samples from input_genomes/ ───────────────────────────
    print(f"Scanning gs://{args.bucket}/input_genomes/ ...")
    input_samples = list_subdirectories(client, args.bucket, "input_genomes/")
    new_count = 0
    for sample_id in sorted(input_samples):
        if sample_id not in tracker:
            tracker[sample_id] = {
                "sample_id"     : sample_id,
                "status"        : "pending",
                "date_detected" : now,
                "date_submitted": "",
                "date_completed": "",
            }
            new_count += 1

    # ── 3. Refresh completion status ──────────────────────────────────────────
    newly_completed = []
    for sample_id, row in tracker.items():
        if row["status"] in ("pending", "submitted"):
            if check_completed(client, args.bucket, sample_id):
                row["status"]         = "completed"
                row["date_completed"] = row["date_completed"] or now
                newly_completed.append(sample_id)

    # ── 4. Summarise ──────────────────────────────────────────────────────────
    by_status: dict[str, int] = {}
    for row in tracker.values():
        by_status[row["status"]] = by_status.get(row["status"], 0) + 1

    pending = sorted(sid for sid, row in tracker.items() if row["status"] == "pending")

    print()
    print("── Sample tracker summary ──────────────────────────────────")
    print(f"  Total tracked  : {len(tracker)}")
    for status in ("pending", "submitted", "completed"):
        print(f"  {status:<14}: {by_status.get(status, 0)}")
    if new_count:
        print(f"\n  Newly detected : {new_count}")
    if newly_completed:
        print(f"  Newly completed: {len(newly_completed)}")
    print(f"\n  Ready to submit: {len(pending)}")
    print("────────────────────────────────────────────────────────────")
    print()

    # ── 5. Save tracker (new samples + completions always written) ────────────
    write_tracker(client, args.bucket, tracker)
    print(f"Tracker saved to gs://{args.bucket}/{TRACKER_BLOB}")
    print()

    # ── 6. --submit: mark as submitted, write samplesheet ────────────────────
    if not args.submit:
        if pending:
            print(f"Tip: run with --submit to mark {len(pending)} sample(s) as submitted")
            print(f"     and write a samplesheet to '{args.out}'.")
        else:
            print("No pending samples. Nothing to submit.")
        return

    if not pending:
        print("No pending samples to submit.")
        return

    for sample_id in pending:
        tracker[sample_id]["status"]         = "submitted"
        tracker[sample_id]["date_submitted"] = now

    with open(args.out, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["sample_id"])
        for sample_id in pending:
            writer.writerow([sample_id])

    # Write tracker again with updated submitted states
    write_tracker(client, args.bucket, tracker)

    print(f"Samplesheet written : '{args.out}' ({len(pending)} sample(s))")
    print(f"Tracker updated     : gs://{args.bucket}/{TRACKER_BLOB}")
    print()
    print("Next step:")
    print(f"  nextflow run main.nf --samplesheet {args.out} -resume")


if __name__ == "__main__":
    main()
