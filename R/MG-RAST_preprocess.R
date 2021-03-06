#' @importFrom magrittr "%>%"
processMGRAST <- function(ID, TMP_DIR, output,e = environment()){
  logging<-("")



  # for example,
  ORG_DB <- "RefSeq"
  ONT_DB <- "COG"
  # ID <- "mgm4762935.3"
  EVALUE <- 10
  #TMP_DIR <- file.path(".","tmp")
  THIS_TMP_DIR <- file.path(TMP_DIR, ID)
  taxlevel_for_matching <- "species"
  logging<-paste(logging,"Creating folder ",  THIS_TMP_DIR,"\n")
  shinyjs::html("progress",logging)
  # make a place to download our results, with a subdir for each new dataset
  if(!exists(THIS_TMP_DIR)){
    dir.create(THIS_TMP_DIR)
  }

  ANNO_BASE <- "http://api.metagenomics.anl.gov/annotation/sequence/"

  # get the Annotation file
  ANNO_PARAMS <- paste0(ID, "?evalue=", EVALUE, "&type=ontology&source=", ONT_DB)

  full_annotation_path <- paste0(ANNO_BASE, ANNO_PARAMS)
  ontology_dest_file <- file.path(THIS_TMP_DIR, "ontology")
  if (!file.exists(ontology_dest_file)){
    logging<-paste(logging,"Downloading from",  full_annotation_path)
    logging<-paste(logging,"\nThis can take a while, depending on how large the dataset is")
    # output$Status<-renderPrint(logging)
    shinyjs::html("progress",logging)
    # shiny::showNotification(paste("Downloading from",  full_annotation_path))
    # shiny::showNotification("This can take a while, depending on how large the dataset is")


    download.file(url=full_annotation_path, destfile = ontology_dest_file)
  }
  # if we have a file less then 200b, its probably empty.
  if (file.info(ontology_dest_file)$size < 200){stop("Ontology File Empty!")}



  # get the Tax file
  ORG_PARAMS <- paste0(ID, "?evalue=", EVALUE, "&type=organism&source=", ORG_DB)
  full_organism_path <- paste0(ANNO_BASE, ORG_PARAMS)
  organism_dest_file <- file.path(THIS_TMP_DIR, "organism")
  if (!file.exists(organism_dest_file)){
    logging <- paste(logging,"\nDownloading from",  full_organism_path)
    logging <- paste(logging,"\nThis can take a while, depending on how large the dataset is")
    shinyjs::html("progress",logging)
    download.file(url=full_organism_path, destfile = organism_dest_file)
  }
  if (file.info(organism_dest_file)$size < 200){stop("Organism File Empty!")}

  # Get the input data to match up the sequences

  DOWNLOAD_BASE <- "https://api.metagenomics.anl.gov/download/"
  # see a call like this to find the stage: http://api.metagenomics.anl.gov/download/history/mgm4447943.3
  ORIGINAL_FILE_STAGE = "050.1"
  raw_input_path <- paste0(DOWNLOAD_BASE, ID, "?file=", ORIGINAL_FILE_STAGE)
  input_dest_file <- file.path(THIS_TMP_DIR, "input_data")
  if (!file.exists(input_dest_file)){

    logging <- paste(logging,"\nDownloading from",  raw_input_path)
    logging <- paste(logging,"\nThis can take a while, depending on how large the dataset is")
    shinyjs::html("progress",logging)
    download.file(url=raw_input_path, destfile = input_dest_file)
  }


  #############  Download NCBI Tax file
  ##########  There are python libraries that would make this nightmare a bit easier,
  ########## but given that the rest of the pipeline is in R, lets keep it simple for now.



  taxdump_dest <- file.path(TMP_DIR, "ncbi_taxdump")
  taxdmp <- file.path(taxdump_dest, "taxdmp")
  if (!dir.exists(taxdump_dest)){
    dir.create(taxdump_dest)
  }
  if (!file.exists(file.path(taxdump_dest, "taxdmp.zip"))){
    logging <- paste(logging,"\nDownload NCBI taxonomy names database")
    logging <- paste(logging,"\nMG-RAST doesn't include taxids, so we have to try to match them up")
    shinyjs::html("progress",logging)
    download.file(url = "ftp://ftp.ncbi.nih.gov/pub/taxonomy/taxdmp.zip",
                  destfile = file.path(taxdump_dest, "taxdmp.zip"))
    unzip(file.path(taxdump_dest, "taxdmp.zip"), exdir = taxdmp)
  }
  simple_tax_names <- file.path(taxdump_dest, "simple_names.tab")
  if (!file.exists(simple_tax_names)){
    logging <- paste(logging,"\ncleaning up taxonomy names file to make matching easier down the road")
    shinyjs::html("progress",logging)
    tax_raw<- data.table::fread(file.path(taxdmp, "names.dmp"), quote = "")
    tax_raw$all <- apply( tax_raw[ , c(3,5,7) ] , 1, paste , collapse = "-" )
    tax <- tax_raw[, c(1, 9)]
    rm(tax_raw)
    gc()
    for (query in c("--scientific name","--scientific", "--equivalent", "<type strain>-type material","--synonym",  "--authority")){
      tax$all <- gsub(query,"", tax$all, fixed=T)
    }
    tax$short <- gsub("(.*?)\\s(.*?)\\s.*", "\\1 \\2", tax$all)
    tax$short <- gsub("\\\"", "", tax$short)

    tax <- tax[!duplicated(tax$short), c("V1", "short")]
    write.table(x = tax, file=simple_tax_names, sep = "\t", row.names = F, quote = c(2))
  } else {
    tax <- data.table::fread(simple_tax_names, stringsAsFactors = F)
  }

  ################  Reading in and processing MG-RAST results
  # read in data, drop 3 to avoid reading in DNA sequence
  # it will automatically drop out the footer:
  #  <<Download complete. 49900 rows retrieved>>
  # Yay!
  names <- c("id", "m5nr", "annotations")

  ont <- data.table::fread(ontology_dest_file, drop = 3, col.names = names)
  n_ont <- nrow(ont)
  org <- data.table::fread(organism_dest_file,  drop = 3, col.names = names)
  n_org <- nrow(org)
  org <- org %>% transform(annotations = strsplit(annotations, ";")) %>% tidyr::unnest(annotations)
  org$annotations <- gsub("\\[", "", gsub("\\]", "", org$annotations))
  unique_org_names <- unique(gsub("(.*?)\\s(.*?)\\s.*", "\\1 \\2", org$annotations))
  #unique_org_names <- unique(org$annotations)


  #  This nightmare loops through and does terrible regex calls looking for the right
  # taxids. it is far, far, from ideal, but as was mentioned before, there are no packages
  # that interface properly with a local database.
  # https://github.com/ropensci/taxize doesnt do ncbi
  # ncbit:: doesnt actually let you do anything other than download
  # myTAI only allows you to query over entrez, not a local copy

  if (taxlevel_for_matching == "species"){
    logging <- paste(logging,"\nmatching scientific name at the species level to taxid; this can take some time")
    shinyjs::html("progress",logging)
    for (i in 1:length(unique_org_names) ){
      if (i %% 5 ==0){shinyjs::html("progress", paste0(logging, paste("\nmaching taxid to organism", i , "of", length(unique_org_names) )))}
      query  <- unique_org_names[i]
      # This is not fantastic but we are going to just take the first 20 for later LCA analysis
      these_names <- tax$V1[grepl(query, tax$short, fixed=T)]
      #print(these_names)
      if (length(these_names) > 20){
        these_names <- these_names[1:20]
      }
      combined_names <- paste(unique(these_names), collapse=";")
      org[grepl(query, org$annotations, fixed = T), "taxids"] <- paste(unique(these_names), collapse=";")
    }
  } else if (taxlevel_for_matching == "genus"){
    simple_org_names <- unique(gsub("(.*?)\\s.*", "\\1", unique_org_names))
    for (i in 1:length(simple_org_names) ){
      if (i %% 50 ==0){
        shinyjs::html("progress", paste0(logging, paste("\nmaching taxid at genus level to organism", i , "of", length(simple_org_names) )),add = F)}

      query <- simple_org_names[i]
      #names <- tax$V1[grepl(query, tax$all, fixed=T)]
      these_names <- tax$V1[grepl(query, tax$short, fixed=T)]
      org[grepl(query, org$annotations, fixed = T), "taxids"] <- paste(unique(these_names), collapse=";")
    }
  }
  logging <- paste0(logging,"\ncomplete \nmerging data")
  shinyjs::html("progress",logging)
  #  we need to get rid of the bit they put after the seqname
  ont$id <- gsub("(.*)\\|(.*)\\|.*", "\\1|\\2", ont$id)
  org$id <- gsub("(.*)\\|(.*)\\|.*", "\\1|\\2", org$id)

  ont_names <- unique(ont$id)
  org_names <- unique(org$id)
  #  Most sequences with ontology have organism
  table(ont_names %in% org_names)
  #  But only half sequences with organism have ontology
  table(org_names %in% ont_names)


  # dplyr to the rescue
  # we need to unnest the possible taxids, and then, for each sequence,
  # merge them to a single column so we can join witht he oontology data later
  min_org <- org %>%
    transform(taxids = strsplit(taxids, ";")) %>%
    tidyr::unnest(taxids) %>%
    dplyr::group_by(id) %>%
    dplyr::mutate(taxids_by_seq = paste0(taxids,collapse =  ";")) %>%
    dplyr::select(-"annotations", -"taxids", -"m5nr")  %>%
    dplyr::distinct() %>%
    dplyr::ungroup()

  # process the ontology data
  # 1) extract the COG (I didn't see any that had more than 1 per row)
  ont$annotations <- gsub(".*COG(.*?)\\].*", "COG\\1", ont$annotations)
  # 2) as we did before, summarize by sequence
  min_ont <- ont %>%
    dplyr::ungroup() %>%
    dplyr::group_by(id) %>%
    dplyr::mutate(COGs_by_seq = paste0(unique(annotations), collapse =  ";")) %>%
    dplyr::select(-"annotations", -"m5nr") %>%
    dplyr::distinct() %>%
    dplyr::ungroup()

  # merge, but only keep the union of the dataset
  combined <- merge(min_org, min_ont, by="id", all = T)
  #path to stats
  stats_api <- paste0("https://api-ui.mg-rast.org/metagenome/", ID, "?verbosity=stats&detail=sequence_stats")
  total_sequences <- as.numeric(gsub(".*sequence_count_raw\\:(\\d+).*", "\\1", gsub("\"","", readLines(stats_api, warn = F))))
  combined_all <- combined
  for(i in 1:(total_sequences-nrow(combined))){
    combined_all <- rbind(combined_all, data.frame(id=paste0("dummy",i),taxids_by_seq=NA,COGs_by_seq=NA))
  }
  write.table(combined_all, file.path(THIS_TMP_DIR, "merged_taxonomy_and_function.tab"), sep = "\t", row.names = F)


  ###########################################  make a summary file #######################
  logging <- paste0(logging,"\nprinting summary file")
  shinyjs::html("progress",logging)

  summary_text<- c("# Summary of MG-RAST merging")
  lines_of_input <- readLines(input_dest_file)
  seqnames <- lines_of_input[grepl(">",lines_of_input, fixed = T)]
  rm(lines_of_input)
  gc()
  summary_text <-c(summary_text, paste("sequences in input", length(seqnames), sep="\t"))
  summary_text <-c(summary_text, paste("ontology hits", n_ont, sep="\t"))
  summary_text <-c(summary_text, paste("unique ontology hits", length(unique(ont$annotations)), sep="\t"))
  summary_text <-c(summary_text, paste("organism hits", n_org, sep="\t"))
  summary_text <-c(summary_text, paste("unique organism hits", length(unique(org$annotations)), sep="\t"))
  summary_text <-c(summary_text, paste("mergable", nrow(combined), sep="\t"))
  summary_text <-c(summary_text, paste("dummy rows added", total_sequences-nrow(combined), sep="\t"))
  writeLines(summary_text, file.path(THIS_TMP_DIR, "merge_summary.tab"))


  logging <- paste0(logging, "\nFinished getting data")

  assign(x="logging", logging,envir = e)
  shinyjs::html("progress",logging)

  return(combined_all)
}
