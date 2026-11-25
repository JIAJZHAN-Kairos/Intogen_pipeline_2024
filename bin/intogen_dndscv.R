#!/usr/bin/env Rscript
# dNdScv for IntOGen (hg38, MANE Select / Ensembl 111 coding sequences).
# Replaces /dndscv/dndscv.R inside the container: same arguments, same outputs.
#
# Reads from $INTOGEN_DATASETS/dndscv:
#   RefCDS_MANE_ens111.rda      RefCDS (list), gr_df (data.frame), known_cancergenes; base R only
#   covariates_MANE_ens111.rds  numeric matrix, one row per gene in RefCDS
# gene_name matches the other IntOGen methods (one CDKN2A entry = p16, ENST00000304494).

suppressMessages({
    library("dndscv")
    library("GenomicRanges")
})

args = commandArgs(TRUE)
muts = as.data.frame(read.table(gzfile(args[1]), sep = '\t', header = TRUE))

# Reference problems must stop the task; they must not become an empty result
datadir = file.path(Sys.getenv("INTOGEN_DATASETS"), "dndscv")
ref = new.env()
load(file.path(datadir, "RefCDS_MANE_ens111.rda"), envir = ref)
covs = readRDS(file.path(datadir, "covariates_MANE_ens111.rds"))
genes = vapply(ref$RefCDS, function(x) x$gene_name, "")
stopifnot(is.matrix(covs), is.numeric(covs), !anyNA(covs), !anyDuplicated(genes),
          all(genes %in% rownames(covs)), all(ref$gr_df$gene %in% genes),
          "CDKN2A" %in% ref$known_cancergenes)

# dndscv() wants a file holding RefCDS and gr_genes; build gr_genes with the local Bioconductor
RefCDS = ref$RefCDS
gr_genes = GRanges(ref$gr_df$chr, IRanges(ref$gr_df$start, ref$gr_df$end))
mcols(gr_genes)$names = ref$gr_df$gene
refdb = tempfile(fileext = ".rda")
save(RefCDS, gr_genes, file = refdb, compress = FALSE)

# kc: genes left out of the indel background. The packaged list only has CDKN2A.p16INK4a/p14arf,
# so with MANE names CDKN2A indels would inflate the background.
# Small cohorts can fail in dndscv(); as upstream, they get empty tables
writeOutput = 0
tryCatch({
    result <- dndscv(muts, refdb = refdb, cv = covs, kc = ref$known_cancergenes)
    writeOutput <- 1
}, error=function(e) {
    message('Error: ', e)
    writeOutput <<- 2
})
unlink(refdb)

if (writeOutput == 1 && anyNA(result$sel_cv$pglobal_cv)) {
    stop("dndscv returned NA p-values: check that covariates and RefCDS match")
}

if (writeOutput == 1) {
    write.table(result$sel_cv, gzfile(args[2]), quote=FALSE, sep='\t', row.names = FALSE)
    write.table(result$annotmuts, gzfile(args[3]), sep = "\t", quote = FALSE, row.names = FALSE)
    write.table(result$genemuts, gzfile(args[4]), sep = "\t", quote = FALSE, row.names = FALSE)
} else {
    # TODO have the empty files existing and just copy them
    df = data.frame(
        gene_name=character(),
        n_syn=character(),
        n_mis=character(),
        n_non=character(),
        n_spl=character(),
        n_ind=character(),
        wmis_cv=character(),
        wnon_cv=character(),
        wspl_cv=character(),
        wind_cv=character(),
        pmis_cv=character(),
        ptrunc_cv=character(),
        pallsubs_cv=character(),
        pind_cv=character(),
        qmis_cv=character(),
        qtrunc_cv=character(),
        qallsubs_cv=character(),
        pglobal_cv=character(),
        qglobal_cv=character(),
        stringsAsFactors=FALSE
    )
    write.table(df, gzfile(args[2]), sep = "\t", quote = FALSE, row.names = FALSE)

    df = data.frame(
        sampleID=character(),
        chr=character(),
        pos=character(),
        ref=character(),
        mut=character(),
        gene=character(),
        strand=character(),
        ref_cod=character(),
        mut_cod=character(),
        ref3_cod=character(),
        mut3_cod=character(),
        aachange=character(),
        ntchange=character(),
        codonsub=character(),
        impact=character(),
        pid=character(),
        stringsAsFactors=FALSE
    )
    write.table(df, gzfile(args[3]), sep = "\t", quote = FALSE, row.names = FALSE)

    df = data.frame(
        gene_name=character(),
        n_syn=character(),
        n_mis=character(),
        n_non=character(),
        n_spl=character(),
        exp_syn=character(),
        exp_mis=character(),
        exp_non=character(),
        exp_spl=character(),
        exp_syn_cv=character(),
        stringsAsFactors=FALSE
    )
    write.table(df, gzfile(args[4]), sep = "\t", quote = FALSE, row.names = FALSE)
}
