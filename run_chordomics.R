#!/usr/bin/Rscript
# Use script to run the Chordomics Shiny app (installing any dependencies along the way)
args <- commandArgs(trailingOnly = TRUE)
if (length(args) > 0 ){
  if (args[1] != "--local"){
    stop("only available argument is --local for installing a local git version of Chordomics. Exiting...")
  } else{
    USE_LOCAL <- TRUE
  }
  }else{
    USE_LOCAL <- FALSE
  }
if(!"devtools" %in% rownames(installed.packages())) {
  print("Installing devtools...")
  install.packages("devtools", repos='http://cran.us.r-project.org', dependencies = T)
}

if(!"chorddiag" %in% rownames(installed.packages())) {
  print("Installing chorddiag...")
  devtools::install_github("KevinMcDonnell6/chorddiag", dependencies = T)
}
if (!USE_LOCAL){
  if(!"chordomics" %in% rownames(installed.packages())) {
    print("Installing chordomics")
    devtools::install_github("KevinMcDonnell6/chordomics", dependencies = T)
  }
} else{
  devtools::install_local(".", dependencies = T)
}
chordomics::launchApp()


