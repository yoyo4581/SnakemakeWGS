import os

configfile: "config.yaml"
include: "snakemake_additional_files/readMapping.smk"
include: "snakemake_additional_files/alignmentQC.smk"
include: "snakemake_additional_files/variantCalling.smk"

def get_sra_dirs():
    # List directories under "data/samples/"
    return [d for d in os.listdir("data/samples") if os.path.isdir(os.path.join("data/samples", d))]



# Generate all (cell_line, SRA) pairs
cell_line_sra_pairs = [(cell_line, sra) for cell_line, sras in config["metadata"].items() for sra in sras]


rule all:
    input:
        expand("results/{cell_line}/alignmentReports/{cell_line}_alignment_metrics.txt", 
               zip, 
               cell_line=[pair[0] for pair in cell_line_sra_pairs], 
               SRA=[pair[1] for pair in cell_line_sra_pairs]),
    log:
        "logs/all_rule_log.txt"
    shell:
        "echo {input} > {log}"

#1 Gets called first because directories_created.txt is not found
rule createDirectories:
    input:
        "data/SraRunTable.csv"
    output:
        "data/directories_created.txt"  # Mark that directories have been created
    shell:
        """
        tail -n +2 {input} | cut -d, -f1 | while read -r srr; do 
            mkdir -p data/samples/$srr
            echo "Created directory for: $srr" >> {output}
        done
        touch {output}  # Ensure the output file is touched after directories are created
        """

# Gets called second, creates a directory where the SRA.sra data files are stored.
rule retrieveData:
    input:
        "data/samples/{SRA}/"
    output:
        temp("sra/{SRA}/{SRA}.sra")  # Place .sra files in a relative directory called 'sra/'
    shell:
        """
        prefetch {wildcards.SRA} --output-directory sra
        """

# Gets called third, unpacks and deletes the .sra file into protected gunziped files of split paired-end data
rule unpackData:
    input:
        "sra/{SRA}/{SRA}.sra"
    output:
        "data/samples/{SRA}/{SRA}_1.fastq.gz",
        "data/samples/{SRA}/{SRA}_2.fastq.gz"
    shell:
        """
        fastq-dump --split-files --gzip --outdir data/samples/{wildcards.SRA}/ {input} && \
        rm -f {input}
        """



