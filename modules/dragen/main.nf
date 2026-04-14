/*
 * DRAGEN process
 *
 * Runs a single-sample whole-genome DRAGEN analysis on Google Cloud Batch.
 *
 * All data I/O (download FASTQs from GCS, upload results to GCS) is handled
 * inside run_dragen.sh, which is baked into the container image. Nextflow's
 * role here is purely orchestration: it submits one Cloud Batch job per
 * sample, manages the retry / spot-to-standard fallback strategy, and
 * controls how many jobs run concurrently (queueSize in gcp.config).
 *
 * Input  : sample_id (string) — must match the folder name under
 *          gs://<bucket>/input_genomes/<sample_id>/
 *
 * Output : completed (val) — the sample_id, emitted after successful
 *          completion. Used by the workflow to count processed samples.
 *          Also enables Nextflow's -resume cache: if this task already
 *          succeeded in a previous run, it is skipped automatically.
 */

process DRAGEN {

    tag "$sample_id"

    input:
    val sample_id

    output:
    val sample_id, emit: completed

    script:
    // task.attempt is a Groovy integer: 1 on first try, 2 on first retry, etc.
    // This drives the USE_SPOT env var for logging inside run_dragen.sh.
    // The actual spot/standard decision is enforced by Nextflow via the
    // `spot` directive in conf/gcp.config — not by the script itself.
    def use_spot = task.attempt <= 3
    """
    export SAMPLE_ID="${sample_id}"
    export BUCKET_NAME="${params.bucket_name}"
    export PROJECT_ID="${params.project_id}"
    export DRAGEN_VERSION="${params.dragen_version}"
    export DRAGEN_BIN="dragen-softwaremode-${params.dragen_version}.el8.x86_64.bin"
    export REFERENCE_PATH="${params.reference_path}"
    export LICENSE_CREDENTIALS_PATH="${params.license_credentials_path}"
    export USE_SPOT="${use_spot}"

    /app/run_dragen.sh
    """
}
