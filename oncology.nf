
// Parameters
params.input_dir = '/domino/datasets/local/nextfuse/oncology_data'
params.output_dir = '/domino/datasets/local/nextfuse/oncology_results'
params.min_coverage = 10
params.min_variant_freq = 0.05

// Create sample VCF and clinical data files
process CREATE_SAMPLE_DATA {
    tag "setup_data"
    publishDir "${params.output_dir}/input_data", mode: 'copy'
    
    output:
    path 'sample_variants.vcf', emit: vcf
    path 'clinical_data.csv', emit: clinical
    path 'gene_panel.txt', emit: genes

    script:
    """
    # Create sample VCF file with oncology-relevant variants
    cat > sample_variants.vcf << 'EOF'
##fileformat=VCFv4.2
##source=SampleGenerator
##INFO=<ID=DP,Number=1,Type=Integer,Description="Total Depth">
##INFO=<ID=AF,Number=A,Type=Float,Description="Allele Frequency">
##FORMAT=<ID=GT,Number=1,Type=String,Description="Genotype">
##FORMAT=<ID=AD,Number=R,Type=Integer,Description="Allelic depths">
#CHROM	POS	ID	REF	ALT	QUAL	FILTER	INFO	FORMAT	SAMPLE001
chr7	140753336	rs121913343	A	T	999	PASS	DP=150;AF=0.45	GT:AD	0/1:82,68
chr17	7675088	rs11575992	G	A	850	PASS	DP=120;AF=0.52	GT:AD	0/1:58,62
chr3	179234297	rs121913530	G	A	920	PASS	DP=95;AF=0.38	GT:AD	0/1:59,36
chr13	32337804	rs80359550	C	T	780	PASS	DP=110;AF=0.41	GT:AD	0/1:65,45
EOF

    # Create clinical data
    cat > clinical_data.csv << 'EOF'
sample_id,age,gender,cancer_type,stage,treatment,response
SAMPLE001,65,M,lung_adenocarcinoma,IIIA,chemotherapy,partial_response
SAMPLE002,58,F,breast_carcinoma,IIA,targeted_therapy,complete_response
SAMPLE003,72,M,colorectal_carcinoma,IIIB,immunotherapy,stable_disease
EOF

    # Create gene panel
    cat > gene_panel.txt << 'EOF'
BRAF
TP53
PIK3CA
BRCA2
EOF
    """
}

// Quality control of VCF file
process VCF_QC {
    tag "vcf_qc"
    label 'process_low'
    publishDir "${params.output_dir}/qc", mode: 'copy'
    
    input:
    path vcf_file

    output:
    path 'qc_report.txt', emit: qc_report
    path 'filtered_variants.vcf', emit: filtered_vcf

    script:
    """
    echo "=== VCF Quality Control Report ===" > qc_report.txt
    echo "Input file: ${vcf_file}" >> qc_report.txt
    echo "Analysis date: \$(date)" >> qc_report.txt
    echo "" >> qc_report.txt
    
    # Count total variants
    total_variants=\$(grep -v '^#' ${vcf_file} | wc -l)
    echo "Total variants: \$total_variants" >> qc_report.txt
    
    # Filter variants by coverage and frequency
    echo "Filtering variants (min coverage: ${params.min_coverage}, min freq: ${params.min_variant_freq})" >> qc_report.txt
    
    # Copy header
    grep '^#' ${vcf_file} > filtered_variants.vcf
    
    # Filter variants (simplified - in real pipeline would use proper VCF tools)
    grep -v '^#' ${vcf_file} | awk -F'\\t' '
    {
        split(\$8, info, ";")
        dp = 0; af = 0
        for(i in info) {
            if(info[i] ~ /^DP=/) dp = substr(info[i], 4)
            if(info[i] ~ /^AF=/) af = substr(info[i], 4)
        }
        if(dp >= ${params.min_coverage} && af >= ${params.min_variant_freq}) print \$0
    }' >> filtered_variants.vcf
    
    filtered_variants=\$(grep -v '^#' filtered_variants.vcf | wc -l)
    echo "Variants after filtering: \$filtered_variants" >> qc_report.txt
    echo "Filtering completed successfully" >> qc_report.txt
    """
}

// Annotate variants with gene information
process ANNOTATE_VARIANTS {
    tag "annotation"
    label 'process_low'
    publishDir "${params.output_dir}/annotation", mode: 'copy'
    
    input:
    path vcf_file
    path gene_panel

    output:
    path 'annotated_variants.tsv', emit: annotated_variants

    script:
    """
    echo "Creating annotated variant file..."
    
    # Create header
    echo -e "chromosome\\tposition\\tref_allele\\talt_allele\\tgene\\tvariant_type\\tfrequency\\tcoverage" > annotated_variants.tsv
    
    # Process variants and add gene annotations
    grep -v '^#' ${vcf_file} | while read line; do
        chrom=\$(echo "\$line" | cut -f1)
        pos=\$(echo "\$line" | cut -f2)
        ref=\$(echo "\$line" | cut -f4)
        alt=\$(echo "\$line" | cut -f5)
        info=\$(echo "\$line" | cut -f8)
        
        # Extract coverage and frequency
        dp=\$(echo "\$info" | grep -o 'DP=[0-9]*' | cut -d'=' -f2)
        af=\$(echo "\$info" | grep -o 'AF=[0-9.]*' | cut -d'=' -f2)
        
        # Simple gene mapping based on chromosome position
        gene="UNKNOWN"
        case "\$chrom:\$pos" in
            "chr7:140753336") gene="BRAF" ;;
            "chr17:7675088") gene="TP53" ;;
            "chr3:179234297") gene="PIK3CA" ;;
            "chr13:32337804") gene="BRCA2" ;;
        esac
        
        var_type="SNV"
        
        echo -e "\$chrom\\t\$pos\\t\$ref\\t\$alt\\t\$gene\\t\$var_type\\t\$af\\t\$dp" >> annotated_variants.tsv
    done
    
    echo "Annotation completed"
    """
}

// Generate oncology report
process GENERATE_REPORT {
    tag "report"
    label 'process_low'
    publishDir "${params.output_dir}/reports", mode: 'copy'
    
    input:
    path annotated_variants
    path clinical_data
    path qc_report

    output:
    path 'oncology_report.html', emit: final_report
    path 'summary_stats.txt', emit: summary

    script:
    """
    echo "Generating oncology genomics report..."
    
    # Create summary statistics
    cat > summary_stats.txt << 'EOF'
=== Oncology Genomics Analysis Summary ===
Analysis Date: \$(date)
Pipeline Version: 1.0

Variant Analysis:
EOF
    
    # Count variants by gene
    echo "Variants by Gene:" >> summary_stats.txt
    tail -n +2 ${annotated_variants} | cut -f5 | sort | uniq -c | sort -nr >> summary_stats.txt
    
    # Generate HTML report
    cat > oncology_report.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Oncology Genomics Report</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        th { background-color: #f2f2f2; }
        .header { color: #2c3e50; }
        .gene { font-weight: bold; color: #e74c3c; }
    </style>
</head>
<body>
    <h1 class="header">Oncology Genomics Analysis Report</h1>
    <p><strong>Generated:</strong> \$(date)</p>
    
    <h2>Quality Control Summary</h2>
    <pre>
EOF
    
    cat ${qc_report} >> oncology_report.html
    
    cat >> oncology_report.html << 'EOF'
    </pre>
    
    <h2>Annotated Variants</h2>
    <table>
        <tr>
            <th>Chromosome</th>
            <th>Position</th>
            <th>Gene</th>
            <th>Ref</th>
            <th>Alt</th>
            <th>Frequency</th>
            <th>Coverage</th>
        </tr>
EOF
    
    # Add variant data to HTML table
    tail -n +2 ${annotated_variants} | while IFS='\t' read chrom pos ref alt gene type freq cov; do
        echo "        <tr>" >> oncology_report.html
        echo "            <td>\$chrom</td>" >> oncology_report.html
        echo "            <td>\$pos</td>" >> oncology_report.html
        echo "            <td class=\"gene\">\$gene</td>" >> oncology_report.html
        echo "            <td>\$ref</td>" >> oncology_report.html
        echo "            <td>\$alt</td>" >> oncology_report.html
        echo "            <td>\$freq</td>" >> oncology_report.html
        echo "            <td>\$cov</td>" >> oncology_report.html
        echo "        </tr>" >> oncology_report.html
    done
    
    cat >> oncology_report.html << 'EOF'
    </table>
    
    <h2>Clinical Data</h2>
    <table>
        <tr>
            <th>Sample ID</th>
            <th>Age</th>
            <th>Gender</th>
            <th>Cancer Type</th>
            <th>Stage</th>
            <th>Treatment</th>
            <th>Response</th>
        </tr>
EOF
    
    # Add clinical data to HTML table
    tail -n +2 ${clinical_data} | while IFS=',' read sample age gender cancer stage treatment response; do
        echo "        <tr>" >> oncology_report.html
        echo "            <td>\$sample</td>" >> oncology_report.html
        echo "            <td>\$age</td>" >> oncology_report.html
        echo "            <td>\$gender</td>" >> oncology_report.html
        echo "            <td>\$cancer</td>" >> oncology_report.html
        echo "            <td>\$stage</td>" >> oncology_report.html
        echo "            <td>\$treatment</td>" >> oncology_report.html
        echo "            <td>\$response</td>" >> oncology_report.html
        echo "        </tr>" >> oncology_report.html
    done
    
    echo "    </table>" >> oncology_report.html
    echo "</body>" >> oncology_report.html
    echo "</html>" >> oncology_report.html
    
    echo "Report generation completed"
    """
}

// Workflow
workflow {
    main:
    // Create sample data
    CREATE_SAMPLE_DATA()
    
    // Quality control
    VCF_QC(CREATE_SAMPLE_DATA.out.vcf)
    
    // Annotate variants
    ANNOTATE_VARIANTS(
        VCF_QC.out.filtered_vcf,
        CREATE_SAMPLE_DATA.out.genes
    )
    
    // Generate final report
    GENERATE_REPORT(
        ANNOTATE_VARIANTS.out.annotated_variants,
        CREATE_SAMPLE_DATA.out.clinical,
        VCF_QC.out.qc_report
    )
    
    emit:
    report = GENERATE_REPORT.out.final_report
    summary = GENERATE_REPORT.out.summary
}

workflow.onComplete {
    println """
    ===========================================
    Oncology Pipeline Execution Complete
    ===========================================
    Success: ${workflow.success}
    Duration: ${workflow.duration}
    Work directory: ${workflow.workDir}
    
    Output files are organized in: ${params.output_dir}
    ├── input_data/          (sample data files)
    ├── qc/                  (quality control results)
    ├── annotation/          (annotated variants)
    └── reports/             (final reports)
    
    Key files:
    - Final report: ${params.output_dir}/reports/oncology_report.html
    - Summary statistics: ${params.output_dir}/reports/summary_stats.txt
    - QC report: ${params.output_dir}/qc/qc_report.txt
    - Annotated variants: ${params.output_dir}/annotation/annotated_variants.tsv
    """
}