#' Estimate the optimal k for k-means clustering
#' 
#' Uses Tracy-Widom theory on random matrices to estimate the optimal number of
#' clusters k. Using the function \code{\link{estkTW}} to perform the estimation.
#' 
#' @param object an object of "SCESet" class
#' @return an estimated value of k
#' 
#' @export
sc3_estimate_k.SCESet <- function(object) {
    dataset <- object@consensus$sc3_processed_dataset
    if ( is.null(dataset) ) {
        warning(paste0("Please run sc3_process() first!"))
        return(object)
    }
    res <- estkTW(dataset = dataset)
    object@consensus$"sc3_k_prediction" <- res
    return(object)
}

#' @rdname sc3_estimate_k.SCESet
#' @aliases sc3_estimate_k
#' @importClassesFrom scater SCESet
#' @export
setMethod("sc3_estimate_k", signature(object = "SCESet"), function(object) {
    sc3_estimate_k.SCESet(object)
})

#' Prepare the SCESet object for SC3 clustering
#' 
#' This function prepares an object of "SCESet" class for SC3 clustering. It
#' creates and populates the following items of the object@consensus slot:
#' \itemize{
#'   \item sc3_processed_dataset - contains the expression matrix to be used for
#'   SC3 clustering.
#'   \item sc3_kmeans_nstart - contains a value of nstart parameter to be used
#'   in kmeans clustering.
#'   \item sc3_n_dim - contains values of the number of eigenvectors to be used
#'   in kmeans clustering.
#'   \item svm_train_inds - if SVM is used this item contains indexes of the 
#'   training cells to be used for SC3 clustering and further SVM prediction.
#'   \item svm_study_inds - if SVM is used this item contains indexes of the
#'    cells to be predicted by SVM.
#'   \item sc3_n_cores - contains a value of the number of available cores on the
#'   user's machine.
#'   \item rselenium - defines whether RSelenium is installed on the user's machine.
#' }
#' 
#' @param object an object of "SCESet" class
#' @param exprs_values character string 
#' indicating which values should be used
#' as the expression values for SC3 clustering. Valid arguments are \code{"tpm"}
#' (default; transcripts per million), \code{"norm_tpm"} (normalised TPM
#' values), \code{"fpkm"} (FPKM values), \code{"norm_fpkm"} (normalised FPKM
#' values), \code{"counts"} (counts for each feature), \code{"norm_counts"},
#' \code{"cpm"} (counts-per-million), \code{"norm_cpm"} (normalised
#' counts-per-million), \code{"exprs"} (whatever is in the \code{'exprs'} slot
#' of the \code{SCESet} object; default), \code{"norm_exprs"} (normalised
#' expression values) or \code{"stand_exprs"} (standardised expression values)
#' or any other named element of the \code{assayData} slot of the \code{SCESet}
#' object that can be accessed with the \code{get_exprs} function.
#' @param gene.filter a boolen variable which defines whether to perform gene 
#' filtering before SC3 clustering. Default is TRUE. The gene filter removes 
#' genes/transcripts that are either expressed (expression value is more than 
#' gene.reads.rare) 
#' in less than X% of cells (rare genes/transcripts) or expressed 
#' (expression value is more than gene.reads.ubiq) in at least (100*X)% of 
#' cells (ubiquitous 
#' genes/transcripts), where X is the gene.filter.fraction*100. The motivation 
#' for the gene filter is that ubiquitous and rare genes most
#' often are not informative for the clustering.
#' @param gene.filter.fraction fraction of cells. Default is 0.06.
#' @param gene.reads.rare expression value threshold for rare genes.
#' Default is 2.
#' @param gene.reads.ubiq expression value threshold for ubiquitous genes.
#' Default is 0.
#' @param log.scale a boolean variable which defines whether to perform log2 
#' scaling before SC3 clustering. Default is TRUE.
#' @param d.region.min defines the minimum number of eigenvectors used for 
#' kmeans clustering as a fraction of the total number of cells. Default is 0.04.
#' @param d.region.max defines the maximum number of eigenvectors used for 
#' kmeans clustering as a fraction of the total number of cells. Default is 0.07.
#' @param svm.num.cells number of randomly selected training cells to be used 
#' for SVM prediction. The default is NULL.
#' @param svm.train.inds a numeric vector defining indeces of training cells 
#' that should be used for SVM training. The default is NULL.
#' @param n.cores defines the number of cores to be used on the user's machine.
#' 
#' @return an object of "SCESet" class
#' 
#' @importFrom RSelenium startServer
#' @importFrom parallel detectCores
#' 
#' @export
sc3_process.SCESet <- function(
    object,
    exprs_values = "counts",
    gene.filter = TRUE,
    gene.filter.fraction = 0.06,
    gene.reads.rare = 2,
    gene.reads.ubiq = 0,
    log.scale = TRUE,
    d.region.min = 0.04,
    d.region.max = 0.07,
    svm.num.cells = NULL,
    svm.train.inds = NULL,
    n.cores = NULL) {
    dataset <- object@assayData[[exprs_values]]
    if ( is.null(dataset) ) {
        warning(paste0("The object does not contain ", exprs_values, " expression values. Returning NULL."))
        return(object)
    }
    # remove duplicated genes
    message("Removing duplicated genes...")
    dataset <- dataset[!duplicated(rownames(dataset)), ]
    
    # gene filter
    if(gene.filter) {
        dataset <- gene_filter(dataset, gene.filter.fraction, gene.reads.rare, gene.reads.ubiq)
        if(nrow(dataset) == 0) {
            message("All genes were removed after the gene filter! Stopping now...")
            return(object)
        }
    }
    
    # log2 transformation
    if(log.scale) {
        message("log2-scaling...")
        dataset <- log2(1 + dataset)
    }
    
    object@consensus$"sc3_processed_dataset" <- dataset
    
    if(ncol(dataset) > 2000) {
        object@consensus$"sc3_kmeans_nstart" <- 50
        message("Your dataset contains more than 2000 cells. Adjusting the nstart parameter of kmeans to 50 for faster performance...")
    } else {
        object@consensus$"sc3_kmeans_nstart" <- 1000
    }
    
    # define number of cells and region of dimensions
    n.dim <- floor(d.region.min * ncol(dataset)) : ceiling(d.region.max * ncol(dataset))
    
    # for large datasets restrict the region of dimensions to 15
    if(length(n.dim) > 15) {
        n.dim <- sample(n.dim, 15)
    }
    
    object@consensus$"sc3_n_dim" <- n.dim
    
    # prepare for SVM
    if(
        !is.null(svm.num.cells) | 
        !is.null(svm.train.inds) | 
        ncol(dataset) > 5000
    ) {
        # handle all possible errors
        if(!is.null(svm.num.cells)) {
            if(!is.null(svm.train.inds)) {
                return(
                    message(
                        "You have set both svm.num.cells and svm.train.inds parameters for SVM training. Please set only one of them and rerun sc3_process()."
                    )
                )
            }
            if(svm.num.cells >= ncol(dataset) - 1) return(
                message(
                    "Number of cells used for SVM training is larger (or equal) than the total number of cells in your dataset. Please make svm.num.cells parameter smaller and rerun sc3_process()."
                )
            )
            if(svm.num.cells < 10) {
                return(
                    message(
                        "Number of cells used for SVM training is less than 10. Please make sure the number of clusters k is smaller than 10 or increase the number of training cells."
                    )
                )
            }
        }
        if(!is.null(svm.train.inds)) {
            if(length(svm.train.inds) < 10) {
                return(
                    message(
                        "Number of cells used for SVM training is less than 10. Please make sure the number of clusters k is smaller than 10 or increase the number of training cells."
                    )
                )
            }
            if(max(svm.train.inds) > ncol(dataset) - 1) {
                return(
                    message(
                        "Number of cells used for SVM training is larger than the total number of cells in your dataset. Please adjust svm.train.inds parameter and rerun sc3_process()."
                    )
                )
            }
        }
        # run SVM
        tmp <- prepare_for_svm(ncol(dataset), svm.num.cells, svm.train.inds)
        
        object@consensus$"svm_train_inds" <- tmp$svm.train.inds
        object@consensus$"svm_study_inds" <- tmp$svm.study.inds
    }
    
    # register computing cluster (N-1 CPUs) on a local machine
    if(is.null(n.cores)) {
        n.cores <- parallel::detectCores()
        if(is.null(n.cores)) {
            return("Cannot define a number of available CPU cores that can be used by SC3. Try to set the n.cores parameter in the sc3() function call.")
        }
        # leave one core for the user
        if(n.cores > 1) {
            n.cores <- n.cores - 1
        }
    }
    
    object@consensus$"sc3_n_cores" <- n.cores
    
    if(file.exists(paste0(file.path(find.package("RSelenium"),
                                    "bin/selenium-server-standalone.jar")))) {
        RSelenium::startServer(args=paste("-log", tempfile()), log=FALSE)
        object@consensus$"rselenium" <- TRUE
    } else {
        object@consensus$"rselenium" <- FALSE
    }
    on.exit(stopSeleniumServer())
    
    return(object)
}

#' @rdname sc3_process.SCESet
#' @aliases sc3_process
#' @importClassesFrom scater SCESet
#' @export
setMethod("sc3_process", signature(object = "SCESet"),
          function(
              object,
              exprs_values = "counts",
              gene.filter = TRUE,
              gene.filter.fraction = 0.06,
              gene.reads.rare = 2,
              gene.reads.ubiq = 0,
              log.scale = TRUE,
              d.region.min = 0.04,
              d.region.max = 0.07,
              svm.num.cells = NULL,
              svm.train.inds = NULL,
              n.cores = NULL
          ) {
              sc3_process.SCESet(object,
                                exprs_values,
                                gene.filter,
                                gene.filter.fraction,
                                gene.reads.rare,
                                gene.reads.ubiq,
                                log.scale,
                                d.region.min,
                                d.region.max,
                                svm.num.cells,
                                svm.train.inds,
                                n.cores)
          })

#' Calculate distances between the cells.
#' 
#' This function calculates distances between the cells contained in 
#' the sc3_processed_dataset item of the object@consensus slot. It then
#' creates and populates the following items of the object@consensus slot:
#' \itemize{
#'   \item sc3_distances - contains a list of distance matrices corresponding to
#'   Euclidean, Pearson and Spearman distances.
#' }
#' 
#' @param object an object of "SCESet" class
#' 
#' @return an object of "SCESet" class
#' 
#' @importFrom doRNG %dorng%
#' @importFrom foreach foreach %dopar%
#' @importFrom parallel makeCluster stopCluster
#' @importFrom doParallel registerDoParallel
#' 
#' @export
sc3_calc_dists.SCESet <- function(object) {
    dataset <- object@consensus$sc3_processed_dataset
    if ( is.null(dataset) ) {
        warning(paste0("Please run sc3_process() first!"))
        return(object)
    }
    
    # check whether in the SVM regime
    if(!is.null(object@consensus$svm_train_inds)) {
        dataset <- dataset[ , object@consensus$svm_train_inds]
    }
    
    # NULLing the variables to avoid notes in R CMD CHECK
    i <- NULL
    
    distances <- c("euclidean", "pearson", "spearman")
    
    message("Calculating distances between the cells...")
    
    if(object@consensus$sc3_n_cores > length(distances)) {
        n.cores <- length(distances)
    } else {
        n.cores <- object@consensus$sc3_n_cores
    }
    
    cl <- parallel::makeCluster(n.cores, outfile="")
    doParallel::registerDoParallel(cl, cores = n.cores)
    
    # calculate distances in parallel
    dists <- foreach::foreach(i = distances) %dorng% {
        try({
            calculate_distance(dataset, i)
        })
    }

    # stop local cluster
    parallel::stopCluster(cl)
    
    names(dists) <- distances
    
    object@consensus$"sc3_distances" <- dists
    return(object)
}

#' @rdname sc3_calc_dists.SCESet
#' @aliases sc3_calc_dists
#' @importClassesFrom scater SCESet
#' @export
setMethod("sc3_calc_dists", signature(object = "SCESet"), function(object) {
    sc3_calc_dists.SCESet(object)
})

#' Calculate transformations of the distance matrices.
#' 
#' This function calculates transforamtions of the distance matrices contained in 
#' the sc3_distances item of the object@consensus slot. It then
#' creates and populates the following items of the object@consensus slot:
#' \itemize{
#'   \item sc3_transformations - contains a list of transformations of the 
#'   distance matrices corresponding to PCA and graph Laplacian transformations.
#' }
#' 
#' @param object an object of "SCESet" class
#' 
#' @return an object of "SCESet" class
#' 
#' @importFrom doRNG %dorng%
#' @importFrom foreach foreach %dopar%
#' @importFrom parallel makeCluster stopCluster
#' @importFrom doParallel registerDoParallel
#' 
#' @export
sc3_calc_transfs.SCESet <- function(object) {
    dists <- object@consensus$sc3_distances
    if ( is.null(dists) ) {
        warning(paste0("Please run sc3_calc_dists() first!"))
        return(object)
    }
    
    # NULLing the variables to avoid notes in R CMD CHECK
    i <- NULL
    
    distances <- names(dists)
    transformations <- c("pca", "laplacian")
    
    hash.table <- expand.grid(
        dists = distances,
        transfs = transformations, 
        stringsAsFactors = FALSE
    )
    
    message("Performing transformations...")
    
    if(object@consensus$sc3_n_cores > nrow(hash.table)) {
        n.cores <- nrow(hash.table)
    } else {
        n.cores <- object@consensus$sc3_n_cores
    }
    
    cl <- parallel::makeCluster(n.cores, outfile="")
    doParallel::registerDoParallel(cl, cores = n.cores)

    # calculate the 6 distinct transformations in parallel
    transfs <- foreach::foreach(i = 1:nrow(hash.table)) %dopar% {
        try({
            transformation(
                get(hash.table[i, 1], dists),
                hash.table[i, 2]
            )
        })
    }

    # stop local cluster
    parallel::stopCluster(cl)
    
    names(transfs) <- paste(hash.table[ , 1], hash.table[ , 2], sep = "_")
    
    object@consensus$"sc3_transformations" <- transfs
    return(object)
}

#' @rdname sc3_calc_transfs.SCESet
#' @aliases sc3_calc_transfs
#' @importClassesFrom scater SCESet
#' @export
setMethod("sc3_calc_transfs", signature(object = "SCESet"), function(object) {
    sc3_calc_transfs.SCESet(object)
})

#' Calculate transformations of the distance matrices.
#' 
#' This function calculates transforamtions of the distance matrices contained in 
#' the sc3_distances item of the object@consensus slot. It then
#' creates and populates the following items of the object@consensus slot:
#' \itemize{
#'   \item sc3_transformations - contains a list of transformations of the 
#'   distance matrices corresponding to PCA and graph Laplacian transformations.
#' }
#' 
#' By default the nstart parameter passed to \link[stats]{kmeans} is defined
#' in \code{\link{sc3_process.SCESet}}, is set 1000 and written to 
#' sc3_kmeans_nstart item of the object@consensus slot.
#' If the number of cells in the dataset is more than 2000, this parameter is 
#' set to 50.
#' 
#' @param object an object of "SCESet" class
#' @param ks a range of the number of clusters k used for SC3 clustering.
#' Can also be a single integer.
#' @param k.means.iter.max iter.max parameter passed to \link[stats]{kmeans} 
#' function. Default is 1e+09.
#' @param seed sets seed for the random number generator.
#' Can be used to check the stability of clustering results: if the results are 
#' the same after changing the seed several time, then the clustering solution 
#' is stable.
#' 
#' @return an object of "SCESet" class
#' 
#' @importFrom doRNG %dorng%
#' @importFrom foreach foreach %dopar%
#' @importFrom parallel makeCluster stopCluster
#' @importFrom doParallel registerDoParallel
#' @importFrom utils setTxtProgressBar txtProgressBar
#' @importFrom stats kmeans
#' 
#' @export
sc3_kmeans.SCESet <- function(
    object,
    ks = 3:5,
    k.means.iter.max = 1e+09,
    seed = 1
) {
    transfs <- object@consensus$sc3_transformations
    if ( is.null(transfs) ) {
        warning(paste0("Please run sc3_calc_transfs() first!"))
        return(object)
    }
    
    # NULLing the variables to avoid notes in R CMD CHECK
    i <- NULL
    
    n.dim <- object@consensus$sc3_n_dim

    hash.table <- expand.grid(
        transf = names(transfs),
        ks = ks,
        n.dim = n.dim, 
        stringsAsFactors = FALSE
    )
    
    message("Performing transformations...")
    
    n.cores <- object@consensus$sc3_n_cores

    cl <- parallel::makeCluster(n.cores, outfile="")
    doParallel::registerDoParallel(cl, cores = n.cores)
    
    pb <- utils::txtProgressBar(min = 1, max = nrow(hash.table), style = 3)
    
    # calculate the 6 distinct transformations in parallel
    labs <- foreach::foreach(i = 1:nrow(hash.table),
                                .options.RNG = seed) %dopar% {
        try({
            utils::setTxtProgressBar(pb, i)
            transf <- get(hash.table$transf[i], transfs)
            stats::kmeans(
                transf[, 1:hash.table$n.dim[i]],
                hash.table$ks[i],
                iter.max = k.means.iter.max,
                nstart = object@consensus$"sc3_kmeans_nstart"
            )$cluster
        })
    }
    
    close(pb)
    
    # stop local cluster
    parallel::stopCluster(cl)
    
    names(labs) <- paste(hash.table$transf, hash.table$ks, hash.table$n.dim, sep = "_")
    
    object@consensus$"sc3_kmeans" <- labs
    return(object)
}

#' @rdname sc3_kmeans.SCESet
#' @aliases sc3_kmeans
#' @importClassesFrom scater SCESet
#' @export
setMethod("sc3_kmeans", signature(object = "SCESet"),
          function(
              object,
              ks = 3:5,
              k.means.iter.max = 1e+09,
              seed = 1
          ) {
              sc3_kmeans.SCESet(
                  object,
                  ks,
                  k.means.iter.max,
                  seed)
          })

#' Calculate consensus matrix.
#' 
#' This function calculates consensus matrices based on the clustering solutions
#' contained in the sc3_kmeans item of the object@consensus slot. It then
#' creates and populates the following items of the object@consensus slot:
#' \itemize{
#'   \item sc3_consensus - contains a list of consensus matrices. In addition 
#'   to consensus matrices it also contains the Silhouette
#'   indeces of the clusters and original cell labels corresponding to the clusters.
#' }
#' 
#' 
#' 
#' @param object an object of "SCESet" class
#' 
#' @return an object of "SCESet" class
#' 
#' @importFrom doRNG %dorng%
#' @importFrom foreach foreach %dopar%
#' @importFrom parallel makeCluster stopCluster
#' @importFrom doParallel registerDoParallel
#' @importFrom cluster silhouette
#' @importFrom stats hclust dist as.dist
#' 
#' @useDynLib SC3
#' @importFrom Rcpp sourceCpp
#' 
#' @export
sc3_calc_consens.SCESet <- function(object) {
    k.means <- object@consensus$sc3_kmeans
    if ( is.null(k.means) ) {
        warning(paste0("Please run sc3_kmeans() first!"))
        return(object)
    }
    
    # NULLing the variables to avoid notes in R CMD CHECK
    i <- NULL
    
    ks <- as.numeric(unique(unlist(lapply(strsplit(names(k.means), "_"), "[[", 3))))
    n.cores <- object@consensus$sc3_n_cores
    
    message("Calculate consensus matrix...")
    
    cl <- parallel::makeCluster(n.cores, outfile="")
    doParallel::registerDoParallel(cl, cores = n.cores)

    cons <- foreach::foreach(i = min(ks):max(ks)) %dorng% {
        try({
            d <- k.means[grep(paste0("_", i, "_"), names(k.means))]
            d <- unlist(lapply(d, function(x) paste(x, collapse = " ")))

            dat <- consensus_matrix(d)
            tmp <- ED2(dat)
            colnames(tmp) <- as.character(colnames(dat))
            rownames(tmp) <- as.character(colnames(dat))
            diss <- stats::as.dist(as.matrix(stats::as.dist(tmp)))
            hc <- stats::hclust(diss)
            clusts <- get_clusts(hc, i)

            silh <- cluster::silhouette(clusts, diss)
            
            labs <- NULL
            for(j in unique(clusts[hc$order])) {
                labs <- rbind(labs, paste(names(clusts[clusts == j]),
                                          collapse = " "))
            }
            
            labs <- as.data.frame(labs)
            colnames(labs) <- "Labels"
            
            list(
                consensus = dat, 
                labels = labs, 
                hc = hc, 
                silhouette = silh
            )
        })
    }

    # stop local cluster
    parallel::stopCluster(cl)
    
    names(cons) <- ks
    
    object@consensus$"sc3_consensus" <- cons
    return(object)
}

#' @rdname sc3_calc_consens.SCESet
#' @aliases sc3_calc_consens
#' @importClassesFrom scater SCESet
#' @export
setMethod("sc3_calc_consens", signature(object = "SCESet"), function(object) {
    sc3_calc_consens.SCESet(object)
})


#' Calculate DE genes, marker genes and cell outliers.
#' 
#' This function calculates DE genes, marker genes and cell outliers based on 
#' the consensus clusterings
#' contained in the sc3_consensus item of the object@consensus slot. It then
#' creates and populates the following items of the object@consensus slot:
#' \itemize{
#'   \item sc3_biology - contains lists of DE genes, marker genes and 
#'   cell outliers data frames.
#' }
#' 
#' @param object an object of "SCESet" class
#' 
#' @return an object of "SCESet" class
#' 
#' @importFrom doRNG %dorng%
#' @importFrom foreach foreach %dopar%
#' @importFrom parallel makeCluster stopCluster
#' @importFrom doParallel registerDoParallel
#' 
#' @export
sc3_calc_biology.SCESet <- function(object) {
    consensus <- object@consensus$sc3_consensus
    if ( is.null(consensus) ) {
        warning(paste0("Please run sc3_consensus() first!"))
        return(object)
    }
    
    dataset <- object@consensus$sc3_processed_dataset
    # check whether in the SVM regime
    if(!is.null(object@consensus$svm_train_inds)) {
        dataset <- dataset[ , object@consensus$svm_train_inds]
    }
    
    # NULLing the variables to avoid notes in R CMD CHECK
    i <- NULL
    
    ks <- names(consensus)
    n.cores <- object@consensus$sc3_n_cores
    
    message("Calculate consensus matrix...")
    
    cl <- parallel::makeCluster(n.cores, outfile="")
    doParallel::registerDoParallel(cl, cores = n.cores)
    
    biol <- foreach::foreach(i = min(ks):max(ks)) %dorng% {
        try({
            hc <- consensus[[as.character(i)]]$hc
            clusts <- get_clusts(hc, i)

            markers <- get_marker_genes(
                dataset,
                clusts
            )
            
            de.genes <- get_de_genes(
                dataset,
                clusts
            )
            
            cell.outl <- get_outl_cells(
                dataset,
                clusts
            )
            
            list(
                markers = markers,
                de.genes = de.genes,
                cell.outl = cell.outl
            )
        })
    }

    # stop local cluster
    parallel::stopCluster(cl)
    
    names(biol) <- ks
    
    object@consensus$"sc3_biology" <- biol
    return(object)
}

#' @rdname sc3_calc_biology.SCESet
#' @aliases sc3_calc_biology
#' @importClassesFrom scater SCESet
#' @export
setMethod("sc3_calc_biology", signature(object = "SCESet"), function(object) {
    sc3_calc_biology.SCESet(object)
})


#' Run SVM on training cells
#' 
#' This function performs training of the SVM classifier on the training cells,
#' which indeces are  
#' contained in the svm_train_inds item of the object@consensus slot. Then it 
#' predicts the labels of the remaining cells using the SVM classifier. Finally it
#' creates and populates the following items of the object@consensus slot:
#' \itemize{
#'   \item svm_result - contains labels of the cells predicted by the SVM ordered
#'   as the cells in the original dataset.
#' }
#' 
#' @param object an object of "SCESet" class
#' @param k the number of clusters k for which the SVM should be run
#' 
#' @return an object of "SCESet" class
#' 
#' @export
sc3_run_svm.SCESet <- function(
    object,
    k
) {
    if ( is.null(object@consensus$svm_train_inds) ) {
        warning(paste0("Please rerun sc3_process() defining the training cells!"))
        return(object)
    }
    
    dataset <- object@consensus$sc3_processed_dataset
    hc <- object@consensus$sc3_consensus[[as.character(k)]]$hc
    clusts <- get_clusts(hc, k)

    train.dataset <- dataset[, object@consensus$svm_train_inds]
    colnames(train.dataset) <- clusts
    
    study.labs <-
        support_vector_machines(
            train.dataset,
            dataset[, object@consensus$svm_study_inds],
            "linear"
        )
    
    svm.labs <- c(clusts, study.labs)
    
    ord <- order(c(object@consensus$svm_train_inds, object@consensus$svm_study_inds))
    
    object@consensus$"svm_result" <- svm.labs[ord]
    return(object)
}

#' @rdname sc3_run_svm.SCESet
#' @aliases sc3_run_svm
#' @importClassesFrom scater SCESet
#' @export
setMethod("sc3_run_svm", signature(object = "SCESet"),
          function(
              object,
              k
          ) {
              sc3_run_svm.SCESet(
                  object,
                  k
              )
          })

#' Summarise SC3 results
#' 
#' This function summarised all SC3 results into a single list and populates 
#' it to the following item of the object@consensus slot:
#' \itemize{
#'   \item sc3_results - contains all SC3 results
#' }
#' 
#' @param object an object of "SCESet" class
#' @param k the number of clusters k for which the results should be summarised
#' 
#' @return an object of "SCESet" class
#' 
#' @export
sc3_summarise_results.SCESet <- function(
    object,
    k
) {
    if ( is.null(object@consensus$svm_result) ) {
        hc <- object@consensus$sc3_consensus[[as.character(k)]]$hc
        clusts <- get_clusts(hc, k)
        names(clusts) <- rownames(object@phenoData@data)
        res <- list(
            labels = cbind(object@phenoData@data, clusts),
            de.genes = object@consensus$sc3_biology[[as.character(k)]]$de.genes,
            markers = object@consensus$sc3_biology[[as.character(k)]]$markers,
            cell.outliers = object@consensus$sc3_biology[[as.character(k)]]$cell.outl
        )
    } else {
        clusts <- object@consensus$svm_result
        names(clusts) <- rownames(object@phenoData@data)
        res <- list(
            labels = cbind(object@phenoData@data, clusts)
        )
    }
    
    object@consensus$"sc3_results" <- res
    return(object)
}

#' @rdname sc3_summarise_results.SCESet
#' @aliases sc3_summarise_results
#' @importClassesFrom scater SCESet
#' @export
setMethod("sc3_summarise_results", signature(object = "SCESet"),
          function(
              object,
              k
          ) {
              sc3_summarise_results.SCESet(
                  object,
                  k
              )
          })