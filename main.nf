#!/usr/bin/env nextflow
nextflow.enable.dsl=2

include { DRAGEN } from './modules/dragen/main'

// ─── Parameter validation ────────────────────────────────────────────────────

def validateParams() {
    def errors = []

    if (!params.samplesheet)
        errors << "Missing required parameter: --samplesheet"

    if (!params.project_id)
        errors << "Missing required parameter: --project_id"

    if (!params.bucket_name)
        errors << "Missing required parameter: --bucket_name"

    if (!params.reference_path)
        errors << "Missing required parameter: --reference_path"

    if (!params.license_credentials_path)
        errors << "Missing required parameter: --license_credentials_path"

    if (errors) {
        log.error(errors.join('\n'))
        System.exit(1)
    }
}

// ─── Workflow ────────────────────────────────────────────────────────────────

workflow {

    validateParams()

    log.info """
    ╔══════════════════════════════════════════════════════════╗
    ║              DRAGEN GCP Pipeline — Nextflow              ║
    ╚══════════════════════════════════════════════════════════╝
    Project ID    : ${params.project_id}
    Bucket        : gs://${params.bucket_name}
    DRAGEN version: ${params.dragen_version}
    Reference     : ${params.reference_path}
    Machine type  : ${params.machine_type}
    Queue size    : ${params.queue_size}
    Samplesheet   : ${params.samplesheet}
    """.stripIndent()

    // Parse samplesheet — expects a CSV with a header column named 'sample_id'
    Channel
        .fromPath(params.samplesheet, checkIfExists: true)
        .splitCsv(header: true, strip: true)
        .map { row ->
            if (!row.sample_id?.trim())
                error "Samplesheet row is missing a 'sample_id' value: ${row}"
            row.sample_id.trim()
        }
        .set { samples_ch }

    DRAGEN(samples_ch)

    DRAGEN.out.completed
        .collect()
        .map { samples -> log.info "Pipeline complete. ${samples.size()} sample(s) processed." }
}
