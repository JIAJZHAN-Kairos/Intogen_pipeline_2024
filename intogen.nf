nextflow.enable.dsl=2

// Set here a list of files or directories to use. E.g. Channel.fromPath(["/path/*", "/path2/file"], type: 'any')
OUTPUT = params.output
STEPS_FOLDER = params.stepsFolder

CUTOFFS = ['WXS': 1000, 'WGS': 10000]
REGIONS_PREFIX = ['WXS': 'cds', 'WGS': 'wg']


process DownloadDatasets {
    tag "Download datasets"
    label "core"

    output:
    path "./*"

    script:
    """
    mkdir -p ./datasets/
    aws s3 cp s3://grimmond-research-nextflow-980504796380-ap-southeast-2-an/intogen-plus-2024/datasets/ ./datasets/ --recursive
    mkdir -p ./config/
    aws s3 cp s3://grimmond-research-nextflow-980504796380-ap-southeast-2-an/intogen-plus-2024/config/annotations.txt ./config/
    """
    }


process ParseInput {
	tag "Parse input ${input}"
	label "core"
	publishDir "${STEPS_FOLDER}/inputs", mode: "copy"
	errorStrategy 'finish'
	input:
		path input
		path annotations

	output:
		path("*.parsed.tsv.gz")

	script:

		if (input.startsWith("s3://")) {
		    println "Processing S3 input path: ${input}"
		    if (input.endsWith(".bginfo")) {
		        """
		        aws s3 cp ${input} - | openvar groupby --header -g DATASET -q -s 'gzip > \${GROUP_KEY}.parsed.tsv.gz'
		        """
		    } else {
		        cohort = input.tokenize('/').last().split('\\.')[0]
		        """
		        aws s3 cp ${input} - | openvar cat --header | gzip > ${cohort}.parsed.tsv.gz
		        """
		    }
		} else {
		    println "Processing local input path: ${input}"
		    if (file(input).isDirectory() || input.endsWith(".bginfo")) {
		        """
		        openvar groupby ${input} --header -g DATASET -q -s 'gzip > \${GROUP_KEY}.parsed.tsv.gz'
		        """
		    } else {
		        cohort = file(input).baseName.split('\\.')[0]
		        """
		        openvar cat ${input} --header | gzip > ${cohort}.parsed.tsv.gz
		        """
		    }
		}
}


process LoadCancer {
	tag "Load cancer type ${cohort}"
	label "core"

	input:
		tuple val(cohort), path(input)

	output:
		tuple val(cohort), stdout

	script:
		"""
		get_field.sh ${input} CANCER
		"""
}


process LoadPlatform {
	tag "Load sequencing platform ${cohort}"
	label "core"

	input:
		tuple val(cohort), path(input)

	output:
		tuple val(cohort), stdout

	script:
		"""
		get_field.sh ${input} PLATFORM
		"""
}

process LoadGenome {
	tag "Load reference genome ${cohort}"
	label "core"

	input:
		tuple val(cohort), path(input)

	output:
		tuple val(cohort), stdout

	script:
		"""
		get_field.sh ${input} GENOMEREF
		"""
}

process ProcessVariants {
	tag "Process variants ${cohort}"
	label "core"
	errorStrategy 'ignore'  // if a cohort does not pass the filters, do not proceed with it
	publishDir "${STEPS_FOLDER}/variants", mode: "copy"

	input:
		tuple val(cohort), path(input), val(platform), val(genome)
		path referenceFiles
	output:
		tuple val(cohort), path(output), emit: variants
		tuple val(cohort), path("${output}.stats.json"), emit: stats

	script:
		cutoff = CUTOFFS[platform]
		output = "${cohort}.tsv.gz"
		if (cutoff)
			"""
			parse-variants --input ${input} --output ${output} \
				--genome ${genome.toLowerCase()} \
				--cutoff ${cutoff}
			"""
		else
			error "Invalid cutoff. Check platform: $platform"

}


process FormatSignature {
	tag "Prepare for signatures ${cohort}"
	label "core"
	publishDir "${STEPS_FOLDER}/signature", mode: "copy"

	input:
		tuple val(cohort), path(input)
		path referenceFiles
	output:
		tuple val(cohort), path(output)

	script:
		output = "${cohort}.in.tsv.gz"
		"""
		format-variants --input ${input} --output ${output} \
			--format signature
		"""

}


process ComputeProfile {
	tag "ComputeProfile ${cohort}"
	label "bgsignature"
	publishDir "${STEPS_FOLDER}/signature", mode: "copy"

	input:
		tuple val(cohort), path(input), val(platform)
		path referenceFiles
	output:
		tuple val(cohort), path(output)

	script:
		prefix = REGIONS_PREFIX[platform]
		output = "${cohort}.sig.json"
		if (prefix)
			"""
			bgsignature normalize -m ${input} \
				-r ${params.datasets}/regions/${prefix}.regions.gz \
				--normalize ${params.datasets}/signature/${prefix}.counts.gz \
				-s 3 -g hg38 --collapse \
				--cores ${task.cpus} \
				-o ${output}
			"""
		else
			error "Invalid prefix. Check platform: $platform"

}


process FormatFML {
	tag "Prepare for FML ${cohort}"
	label "core"
	publishDir "${STEPS_FOLDER}/oncodrivefml", mode: "copy"

	input:
		tuple val(cohort), path(input)
		path referenceFiles
	output:
		tuple val(cohort), path(output)

	script:
		output = "${cohort}.in.tsv.gz"
		"""
		format-variants --input ${input} --output ${output} \
			--format fml
		"""

}

process OncodriveFML {
    tag "OncodriveFML ${cohort}"
    publishDir "${STEPS_FOLDER}/oncodrivefml", mode: "copy"

    input:
        tuple val(cohort), path(input), path(signature)
	path referenceFiles
    output:
        tuple val(cohort), path("out/*.tsv.gz")

	script:
		seedOpt = (params.seed == null)? '': "--seed ${params.seed}"
		debugOpt =  (params.debug)? '--debug': ''
		"""
		export LC_ALL=C.UTF-8
    		export LANG=C.UTF-8
		oncodrivefml -i ${input} -e ${params.datasets}/regions/cds.regions.gz --signature ${signature} \
			-c /oncodrivefml/oncodrivefml_v2.conf  --cores ${task.cpus} \
			-o out ${seedOpt} ${debugOpt}
		"""
}


process FormatCLUSTL {
	tag "Prepare for CLUSTL ${cohort}"
	label "core"
	publishDir "${STEPS_FOLDER}/oncodriveclustl", mode: "copy"

	input:
		tuple val(cohort), path(input)
		path referenceFiles
	output:
		tuple val(cohort), path(output)

	script:
		output = "${cohort}.in.tsv.gz"
		"""
		format-variants --input ${input} --output ${output} \
			--format clustl
		"""

}

process OncodriveCLUSTL {
    tag "OncodriveCLUSTL ${cohort}"
    publishDir "${STEPS_FOLDER}/oncodriveclustl", mode: "copy"

    input:
        tuple val(cohort), path(input), path(signature), val(cancer)
	path referenceFiles
    output:
        tuple val(cohort), path("${cohort}.elements_results.txt"), emit: elements
        tuple val(cohort), path("${cohort}.clusters_results.tsv"), emit: clusters

	script:
		seedOpt = (params.seed == null)? '': "--seed ${params.seed}"
		debugOpt =  (params.debug)? '--log-level debug': ''
		if (['CM', 'SBCC', 'SSCC'].contains(cancer))
			"""
			oncodriveclustl -i ${input} -r ${params.datasets}/regions/cds.regions.gz \
				-g hg38 -sim region_restricted -n 1000 -kmer 5 \
				-sigcalc region_normalized \
				--concatenate \
				-c ${task.cpus} \
				-o ${cohort} ${seedOpt} ${debugOpt}

			mv ${cohort}/elements_results.txt ${cohort}.elements_results.txt
			mv ${cohort}/clusters_results.tsv ${cohort}.clusters_results.tsv
			"""
		else
			"""
			oncodriveclustl -i ${input} -r ${params.datasets}/regions/cds.regions.gz \
				-g hg38 -sim region_restricted -n 1000 -kmer 3 \
				-sig ${signature} --concatenate \
				-c ${task.cpus} \
				-o ${cohort} ${seedOpt} ${debugOpt}

			mv ${cohort}/elements_results.txt ${cohort}.elements_results.txt
			mv ${cohort}/clusters_results.tsv ${cohort}.clusters_results.tsv
			"""
}


process FormatDNDSCV {
	tag "Prepare for DNDSCV ${cohort}"
	label "core"
	publishDir "${STEPS_FOLDER}/dndscv", mode: "copy"

	input:
		tuple val(cohort), path(input)
		path referenceFiles
	output:
		tuple val(cohort), path(output)

	script:
		output = "${cohort}.in.tsv.gz"
		"""
		format-variants --input ${input} --output ${output} \
			--format dndscv
		"""
}

process dNdScv {
    tag "dNdScv ${cohort}"
    publishDir "${STEPS_FOLDER}/dndscv", mode: "copy"

    input:
        tuple val(cohort), path(input)
	path referenceFiles
    output:
        tuple val(cohort), path("${cohort}.dndscv.tsv.gz"), emit: dndscv
        tuple val(cohort), path("${cohort}.dndscv_annotmuts.tsv.gz"), emit: annotmuts
        tuple val(cohort), path("${cohort}.dndscv_genemuts.tsv.gz"), emit: genemuts

	script:
		"""
		Rscript /dndscv/dndscv.R \
			${input} ${cohort}.dndscv.tsv.gz \
			${cohort}.dndscv_annotmuts.tsv.gz \
			${cohort}.dndscv_genemuts.tsv.gz
		"""
}

process FormatVEP {
	tag "Prepare for VEP ${cohort}"
	label "core"
	publishDir "${STEPS_FOLDER}/vep", mode: "copy"

	input:
		tuple val(cohort), path(input)
		path referenceFiles
	output:
		tuple val(cohort), path(output)

	script:
		output = "${cohort}.in.tsv.gz"
		"""
		format-variants --input ${input} --output ${output}.tmp \
			--format vep
		sort -k1V -k2n -k3n ${output}.tmp |gzip > ${output}
		"""

}

process VEP {
	tag "VEP ${cohort}"
	publishDir "${STEPS_FOLDER}/vep", mode: "copy"

    input:
        tuple val(cohort), path(input)
	path referenceFiles
    output:
        tuple val(cohort), path(output)

	script:
		output = "${cohort}.vep.tsv.gz"
		"""
		vep -i ${input} -o STDOUT --assembly GRCh38 \
			--no_stats --cache --offline --symbol \
			--protein --tab --canonical --mane \
			--dir ${params.datasets}/vep \
			| grep -v ^## | gzip > ${output}
		"""
}


process ProcessVEPoutput {
	tag "Process vep output ${cohort}"
	label "core"
	publishDir "${STEPS_FOLDER}/vep", mode: "copy"

    input:
        tuple val(cohort), path(input)

    output:
        tuple val(cohort), path(output), emit: parsed
        tuple val(cohort), path("${output}.stats.json"), emit: stats

	script:
		output = "${cohort}.tsv.gz"
		"""
		parse-vep --input ${input} --output ${output}
		"""
}


process FilterNonSynonymous {
	tag "Filter non synonymus ${cohort}"
	label "core"
	publishDir "${STEPS_FOLDER}/nonsynonymous", mode: "copy"

    input:
        tuple val(cohort), path(input)

    output:
        tuple val(cohort), path(output)

	script:
		output = "${cohort}.vep_nonsyn.tsv.gz"
		"""
		parse-nonsynonymous --input ${input} --output ${output}
		"""
}


process FormatSMRegions {
	tag "Prepare for SMRegions ${cohort}"
	label "core"
	publishDir "${STEPS_FOLDER}/smregions", mode: "copy"

	input:
		tuple val(cohort), path(input)
		path referenceFiles
	output:
		tuple val(cohort), path(output)

	script:
		output = "${cohort}.in.tsv.gz"
		"""
		format-variants --input ${input} --output ${output} \
			--format smregions
		"""
}

process SMRegions {
	tag "SMRegions ${cohort}"
	publishDir "${STEPS_FOLDER}/smregions", mode: "copy"

    input:
        tuple val(cohort), path(input), path(signature)
	path referenceFiles
    output:
        tuple val(cohort), path(output)

	script:
		output = "${cohort}.smregions.tsv.gz"
		seedOpt = (params.seed == null)? '': "--seed ${params.seed}"
		debugOpt =  (params.debug)? '--debug': ''
		"""
		smregions -m ${input} -e ${params.datasets}/regions/cds.regions.gz \
			-r ${params.datasets}/smregions/regions_pfam.tsv \
			-s ${signature} --cores ${task.cpus} \
			-c /smregions/smregions.conf \
			-o ${output} ${seedOpt} ${debugOpt}
		"""
}


process FormatCBaSE {
	tag "Prepare for CBaSE ${cohort}"
	label "core"
	publishDir "${STEPS_FOLDER}/cbase", mode: "copy"

	input:
		tuple val(cohort), path(input)
		path referenceFiles
	output:
		tuple val(cohort), path(output)

	script:
		output = "${cohort}.in.tsv"
		"""
		format-variants --input ${input} --output ${output} \
			--format cbase
		"""
}

process CBaSE {
	tag "CBaSE ${cohort}"
	publishDir "${STEPS_FOLDER}/cbase", mode: "copy"

    input:
        tuple val(cohort), path(input)
	path referenceFiles
    output:
        tuple val(cohort), path(output)

	script:
		output = "${cohort}.cbase.tsv.gz"
		"""
		mkdir -p Output/

		python /cbase/cbase.py ${input} ${params.datasets}/cbase 0 output
		tail -n+2 Output/q_values_output.txt | gzip > ${output}
		"""
}

process FormatMutPanning {
	tag "Prepare for MutPanning ${cohort}"
	label "core"
	publishDir "${STEPS_FOLDER}/mutpanning", mode: "copy"

	input:
		tuple val(cohort), path(input)
		path referenceFiles
	output:
		tuple val(cohort), path(muts), path(samples)

	script:
		muts = "${cohort}.in_muts.tsv"
		samples = "${cohort}.in_samples.tsv"
		"""
		format-variants --input ${input} --output ${muts} \
			--format mutpanning-mutations
		format-variants --input ${input} --output ${samples} \
			--format mutpanning-samples
		"""
}

process MutPanning {
	tag "MutPanning ${cohort}"
	publishDir "${STEPS_FOLDER}/mutpanning", mode: "copy"

    input:
        tuple val(cohort), path(mutations), path(samples)
	path referenceFiles
    output:
        tuple val(cohort), path("out/SignificanceFiltered/Significance${cohort}.txt")

	script:
		// TODO remove the creation of the out file or move to the container
		"""
		mkdir -p out/SignificanceFiltered
		echo "Name\tTargetSize\tTargetSizeSyn\tCount\tCountSyn\tSignificance\tFDR\n" \
			> out/SignificanceFiltered/Significance${cohort}.txt
		java -cp /mutpanning/MutPanning.jar MutPanning \
			out ${mutations} ${samples} ${params.datasets}/mutpanning/Hg19/
		"""
}


process FormatHotMAPS {
	tag "Prepare for HotMAPS ${cohort}"
	label "core"
	publishDir "${STEPS_FOLDER}/hotmaps", mode: "copy"

	input:
		tuple val(cohort), path(input)
		path referenceFiles
	output:
		tuple val(cohort), path(output)

	script:
		output = "${cohort}.in.maf"
		"""
		format-variants --input ${input} --output ${output} \
			--format hotmaps
		"""
}

process HotMAPS {
	tag "HotMAPS ${cohort}"
	publishDir "${STEPS_FOLDER}/hotmaps", mode: "copy"
    input:
        tuple val(cohort), path(input), path(signatures)
	path referenceFiles
    output:
        tuple val(cohort), path("*.out.gz"), emit: hotmaps
        tuple val(cohort), path("*.clusters.gz"), emit: clusters

	script:
		"""
		/bin/sh /hotmaps/hotmaps.sh ${input} . ${signatures} \
			${params.datasets}/hotmaps ${task.cpus}
		"""
}


process Combination {
	tag "Combination ${cohort}"
	publishDir "${STEPS_FOLDER}/combination", mode: "copy"

    input:
        tuple val(cohort), path(fml), path(clustl), path(dndscv), path(smregions), path(cbase), path(mutpanning), path(hotmaps)
	path referenceFiles
    output:
        tuple val(cohort), path("${cohort}.05.out.gz")

	script:
		"""
		intogen-combine -o ${cohort} \
			--oncodrivefml ${fml} \
			--oncodriveclustl ${clustl} \
			--dndscv ${dndscv} \
			--smregions ${smregions} \
			--cbase ${cbase} \
			--mutpanning ${mutpanning} \
			--hotmaps ${hotmaps}
		"""

}


process FormatdeconstructSigs {
	tag "Prepare for deconstructSigs ${cohort}"
	label "core"
	publishDir "${STEPS_FOLDER}/deconstructSigs", mode: "copy"

	input:
		tuple val(cohort), path(input)
		path referenceFiles
	output:
		tuple val(cohort), path(output)

	script:
		output = "${cohort}.in.tsv.gz"
		"""
		format-variants --input ${input} --output ${output} \
			--format deconstructsigs
		"""
}

process deconstructSigs {
	tag "deconstructSigs ${cohort}"
	publishDir "${STEPS_FOLDER}/deconstructSigs", mode: "copy"

    input:
        tuple val(cohort), path(input)
	path referenceFiles
    output:
        tuple val(cohort), path(output), emit: weights
        tuple val(cohort), path("*.signature_likelihood"), emit: likelihood

	script:
		output = "${cohort}.deconstructsigs.tsv.gz"
		likelihood = "${cohort}.signature_likelihood"
		"""
		python3 /deconstructsig/run_deconstruct.py \
			--input-file ${input} --weights ${output} \
			--build hg38
		python3 /deconstructsig/signature_assignment.py \
			--input-file ${output} \
			--output-file ${likelihood}
		"""
}

// TODO add a process to combine all stats

process CohortCounts {
	tag "Count variants ${cohort}"
        label "core"
    input:
        tuple val(cohort), path(input), val(cancer), val(platform)

    output:
		tuple val(cohort), path("*.counts")

	script:
		"""
		variants=`zcat ${input} |tail -n+2 |wc -l`
		samples=`zcat ${input} |tail -n+2 |cut -f1 |uniq |sort -u| wc -l`
		echo "${cohort}\t${cancer}\t${platform}\t\$variants\t\$samples" > ${cohort}.counts
		"""
}

process CohortSummary {
	tag "Count variants"
	publishDir "${OUTPUT}", mode: "copy"

    input:
        path(input)
	path referenceFiles
    output:
		path(output)

	script:
		output="cohorts.tsv"
		"""
		echo 'COHORT\tCANCER_TYPE\tPLATFORM\tMUTATIONS\tSAMPLES' > ${output}
		cat ${input} >> ${output}
		"""
}


process MutationsSummary {
	tag "Mutations"
	publishDir "${OUTPUT}", mode: "copy"
	label "core"

    input:
        path(input)

    output:
		path(output)

	script:
		output="mutations.tsv"
		"""
		mutations-summary --output ${output} \
			${input}
		"""
}


process DriverDiscovery {
	tag "Driver discovery ${cohort}"
	publishDir "${STEPS_FOLDER}/drivers", mode: "copy"
	label "core"

    input:
        tuple val(cohort), path(combination), path(deconstruct_in), path(sig_likelihood), path(smregions), path(clustl_clusters), path(hotmaps_clusters), path(dndscv), val(cancer)
	path referenceFiles
    output:
		path(output_drivers), emit: drivers
		path(output_vet), emit: vet

	script:
		output_drivers = "${cohort}.drivers.tsv"
		output_vet = "${cohort}.vet.tsv"
		"""
		drivers-discovery --output_drivers ${output_drivers} \
			--output_vet ${output_vet} \
			--combination ${combination} \
			--mutations ${deconstruct_in} \
			--sig_likelihood ${sig_likelihood} \
			--smregions ${smregions} \
			--clustl_clusters ${clustl_clusters} \
			--hotmaps ${hotmaps_clusters} \
			--dndscv ${dndscv} \
			--ctype ${cancer} \
			--cohort ${cohort}
		"""
}

process DriverSummary {
	tag "Driver summary"
	publishDir "${OUTPUT}", mode: "copy"
	label "core"

    input:
        path (input)
        path (input_vet)
        path (mutations)
        path (cohortsSummary)
	path referenceFiles
    output:
		path("drivers.tsv"), emit: drivers
		path("unique_drivers.tsv"), emit: unique
		path("unfiltered_drivers.tsv"), emit: unfiltered

	script:
		"""
		drivers-summary \
			--mutations ${mutations} \
			--cohorts ${cohortsSummary} \
			${input} "${input_vet}"
		"""
}


process ParseProfile {
	tag "Parsing profile ${cohort}"
	publishDir "${STEPS_FOLDER}/boostDM/mutrate", mode: "copy"
	label "core"

    input:
        tuple val(cohort), path(signature)

    output:
		tuple val(cohort), path("*.mutrate.json")

	script:
		"""
		parse-profile -i ${signature} -o ${cohort}
		"""

}


process DriverSaturation {
	tag "Driver saturation"
	publishDir "${STEPS_FOLDER}/boostDM/saturation", mode: "copy"
	label "core"

    input:
        path (drivers)
	path referenceFiles
    output:
		path("*.vep.gz")

	script:
		"""

		drivers-saturation --drivers ${drivers}

		"""
}

process FilterMNVS {
	tag "MNVs filter"
	publishDir "${STEPS_FOLDER}/boostDM", mode: "copy"
	label "core"

	input:
		path(input)

	output:
		path("mnvs.tsv.gz")

	script:
		"""

		parse-mnvs ${input}

		"""
}


workflow {

	// ---- input channels ----
	// each cohort is a directory (metadata.yaml + mutations.maf), so match
	// directories (not files); fail loudly if the glob matches nothing
	input_ch = Channel.fromPath(params.input.tokenize(), type: 'dir', checkIfExists: true)
	annotations_ch = Channel.value(params.annotations)

	// ---- reference datasets (value channel: a no-input process emits a value
	// channel, so it is reused by every per-cohort task) ----
	DownloadDatasets()
	ref = DownloadDatasets.out

	// ---- parse input into per-cohort files ----
	ParseInput(input_ch, annotations_ch)
	cohorts = ParseInput.out
		.flatten()
		.map { it -> [it.baseName.split('\\.')[0], it] }

	// ---- per-cohort metadata ----
	LoadCancer(cohorts)
	LoadPlatform(cohorts)
	LoadGenome(cohorts)
	cancers   = LoadCancer.out
	platforms = LoadPlatform.out
	genomes   = LoadGenome.out

	// ---- variant processing / filtering ----
	ProcessVariants(cohorts.join(platforms).join(genomes), ref)
	variants = ProcessVariants.out.variants

	// ---- mutational profile / signatures ----
	FormatSignature(variants, ref)
	ComputeProfile(FormatSignature.out.join(platforms), ref)
	signatures = ComputeProfile.out

	// ---- OncodriveFML ----
	FormatFML(variants, ref)
	OncodriveFML(FormatFML.out.join(signatures), ref)

	// ---- OncodriveCLUSTL ----
	FormatCLUSTL(variants, ref)
	OncodriveCLUSTL(FormatCLUSTL.out.join(signatures).join(cancers), ref)

	// ---- dNdScv ----
	FormatDNDSCV(variants, ref)
	dNdScv(FormatDNDSCV.out, ref)

	// ---- VEP annotation ----
	FormatVEP(variants, ref)
	VEP(FormatVEP.out, ref)
	ProcessVEPoutput(VEP.out)
	parsed_vep = ProcessVEPoutput.out.parsed

	// ---- SMRegions ----
	FilterNonSynonymous(parsed_vep)
	FormatSMRegions(FilterNonSynonymous.out, ref)
	SMRegions(FormatSMRegions.out.join(signatures), ref)

	// ---- CBaSE ----
	FormatCBaSE(parsed_vep, ref)
	CBaSE(FormatCBaSE.out, ref)

	// ---- MutPanning ----
	FormatMutPanning(parsed_vep, ref)
	MutPanning(FormatMutPanning.out, ref)

	// ---- HotMAPS ----
	FormatHotMAPS(parsed_vep, ref)
	HotMAPS(FormatHotMAPS.out.join(signatures), ref)

	// ---- combination of the 7 methods ----
	Combination(
		OncodriveFML.out
			.join(OncodriveCLUSTL.out.elements)
			.join(dNdScv.out.dndscv)
			.join(SMRegions.out)
			.join(CBaSE.out)
			.join(MutPanning.out)
			.join(HotMAPS.out.hotmaps),
		ref
	)

	// ---- deconstructSigs ----
	FormatdeconstructSigs(parsed_vep, ref)
	deconstructSigs(FormatdeconstructSigs.out, ref)

	// ---- cohort / mutation summaries ----
	CohortCounts(cohorts.join(cancers).join(platforms))
	cohort_counts_list = CohortCounts.out.map { it -> it[1] }
	CohortSummary(cohort_counts_list.collect(), ref)

	mutations_inputs = parsed_vep.map { it -> it[1] }
	MutationsSummary(mutations_inputs.collect())

	// ---- driver discovery ----
	DriverDiscovery(
		Combination.out
			.join(FormatdeconstructSigs.out)
			.join(deconstructSigs.out.likelihood)
			.join(SMRegions.out)
			.join(OncodriveCLUSTL.out.clusters)
			.join(HotMAPS.out.clusters)
			.join(dNdScv.out.dndscv)
			.join(cancers),
		ref
	)

	DriverSummary(
		DriverDiscovery.out.drivers.collect(),
		DriverDiscovery.out.vet.collect(),
		MutationsSummary.out,
		CohortSummary.out,
		ref
	)

	// ---- boostDM inputs ----
	ParseProfile(signatures)
	DriverSaturation(DriverSummary.out.drivers, ref)

	filt_mnvs_inputs = parsed_vep.map { it -> it[1] }
	FilterMNVS(filt_mnvs_inputs.collect())
}
