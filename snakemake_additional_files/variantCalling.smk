#------------------------------
# Merge all tumor-only runs to create 1 bam file
#----------------------------------------

rule mergeBAMS:
    input:
        lambda wildcards: expand(
            "mapped_reads/{cell_line}/sorted_{SRA}.bam",
            cell_line=wildcards.cell_line,
            SRA=config["metadata"][wildcards.cell_line])
    output:
        temp("mapped_reads/{cell_line}/{cell_line}_merged.bam")
    threads: 4
    shell:
        """
        samtools merge -@ {threads} {output} {input}
        """


#-------------------------
# MarkDuplicatesSpark (GATK)
#----------------------------
rule markDups:
    input:
        "mapped_reads/{cell_line}/{cell_line}_merged.bam"
    output:
        bam=temp("mapped_reads/{cell_line}/{cell_line}_merged_sorted_dedup.bam"),
        mark="results/{cell_line}/marked_duplicates.txt"
    log:
        "logs/{cell_line}_markDups.txt"
    threads:4
    shell:
        """
        gatk MarkDuplicates \
            -I {input} \
            -O {output.bam} \
            -M {output.mark} 2> {log}
        """

#-------------------------
# Recalibrate Base Quality scores (BaseRecalibrator + ApplyBQSR (GATK))
#---------------------------
rule ModelBuild:
    input:
        marked_bam="mapped_reads/{cell_line}/{cell_line}_merged_sorted_dedup.bam",
        fa="data/GRCh38/Homo_sapiens.GRCh38.dna.primary_assembly.fa",
        vcf_known="supporting_Files/Homo_sapiens_assembly38.dbsnp138.vcf",
    output:
        "results/{cell_line}/recal_data.table"
    shell:
        """
        gatk BaseRecalibrator -I {input.marked_bam} -R {input.fa} --known-sites {input.vcf_known} -O {output}
        """

rule ApplyBaseQualityScore:
    input:
        marked_bam="mapped_reads/{cell_line}/{cell_line}_merged_sorted_dedup.bam",
        fa="data/GRCh38/Homo_sapiens.GRCh38.dna.primary_assembly.fa",
        bqsr_file="results/{cell_line}/recal_data.table",
    output:
        "mapped_reads/{cell_line}/{cell_line}_processed_merged.bam"
    shell:
        """
        gatk ApplyBQSR -I {input.marked_bam} -R {input.fa} --bqsr-recal-file {input.bqsr_file} -O {output}
        """

#------------------
# Collect Alignment Summary metrics
#------------------

rule SummaryMetrics:
    input:
        bam="mapped_reads/{cell_line}/{cell_line}_processed_merged.bam",
        fa="data/GRCh38/Homo_sapiens.GRCh38.dna.primary_assembly.fa",
    output:
        align="results/{cell_line}/alignmentReports/{cell_line}_alignment_metrics.txt",
        insert_file="results/{cell_line}/alignmentReports/{cell_line}_insert_size_metrics.txt",
        histo="results/{cell_line}/alignmentReports/{cell_line}_insert_size_histogram.pdf",
    shell:
        """
        gatk CollectAlignmentSummaryMetrics R={input.fa} I={input.bam} O={output.align}
        gatk CollectInsertSizeMetrics INPUT={input.bam} OUTPUT={output.insert_file} HISTOGRAM_FILE={output.histo}
        """

#------------------------
# MultiQC reports
#------------------------
rule MultiQC_alignment:
    input:
        insert_metrics="results/{cell_line}/alignmentReports/{cell_line}_insert_size_metrics.txt",
        alignment_metrics="results/{cell_line}/alignmentReports/{cell_line}_alignment_metrics.txt",
    output:
        "results/{cell_line}/{cell_line}_alignmentMultiQC.html"
    shell:
        """
        mutliqc results/{wildcards.cell_line}/alignmentReports/ -o results/{wildcards.cell_line}/ --filename {wildcards.cell_line}_alignmentMultiQC.html
        """



#---------------------------
# Calling somatic variants - Tumor only mode
#-----------------------------

rule SomaticVariantsCall:
    input:
        fa="data/GRCh38/Homo_sapiens.GRCh38.dna.primary_assembly.fa",
        bam="mapped_reads/{cell_line}/{cell_line}_processed_merged.bam",
        germline="supporting_Files/mutect2_supporting_files/af-only-gnomad.hg38.vcf.gz",
        pon="supporting_files/mutect2_supporting_files/1000g_pon.hg38.vcf.gz",
    output:
        variants="variants/{cell_line}/{cell_line}_somatic_variants_mutect2.vcf.gz",
        read_orient="variants/{cell_line}/{cell_line}_fir2.tar.gz",
    shell:
        """
        gatk Mutect2 -R {input.fa} \
            -I {input.bam} \
            --germline-resource {input.germline} \
            --panel-of-normals {input.pon} \
            -O {output.variants} \
            --fir2-tar-gz {output.read_orient}
        """

#--------------------
# Cross-Sample Contamination
#-----------------------
rule GetPileUpSummaries:
    input:
        bam="mapped_reads/{cell_line}/{cell_line}_processed_merged.bam",
        germline="supporting_Files/mutect2_supporting_files/af-only-gnomad.hg38.vcf.gz",
        interval="supporting_Files/mutect2_supporting_files/exome_calling_regions.v1.1.interval_list",
    output:
        pileup="variants/{cell_line}/{cell_line}_getpileupsummaries.table"
    shell:
        """
        gatk GetPileupSummaries \
            --java-options "--Xmx24G" --tmp-dir temp/ \
            -I {input.bam} \
            -V {input.germline} \
            -L {input.interval} \
            -O {output.pileup}
        """

#---------------------------
# Contaminate Calculation
#---------------------------
rule CalculateContamination:
    input:
        pileup="variants/{cell_line}/{cell_line}_getpileupsummaries.table"
    output:
        contam_table="variants/{cell_line}/{cell_line}_contamination.table"
    shell:
        """
        gatk CalculateContamination \
            -I {input.pileup} \
            -O {output.contam_table}
        """

#--------------------------
# Estimate read orientation artifacts
#--------------------------
