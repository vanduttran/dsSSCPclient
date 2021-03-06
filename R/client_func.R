#' @title Encode function  arguments
#' @description Serialize to JSON, then encode base64,
#'  then replace '+', '/' and '=' in the result in order to play nicely with the opal sentry.
#'  Used to encode non-scalar function arguments prior to sending to the opal server.
#'  There's a corresponding function in the server package calle .decode_args
#' @param some.object the object to be encoded
#' @return encoded text with offending characters replaced by strings
#' @keywords internal
.encode.arg <- function(some.object) {
    encoded <- RCurl::base64Encode(jsonlite::toJSON(some.object, null = 'null'));
    # go fishing for '+', '/' and '=', opal rejects them :
    my.dictionary <- c('\\/' = '-slash-', '\\+' = '-plus-', '\\=' = '-equals-')
    sapply(names(my.dictionary), function(x){
        encoded[1] <<- gsub(x, my.dictionary[x], encoded[1])
    })
    return(paste0(encoded[1],'base64'))
}


#' @title Garbage collection
#' @description Call gc on the federated server
#' @export
garbageCollect <- function() {
    gc(reset=T)
    return (NULL)
}


#' @title Push a symmetric matrix
#' @description Push symmetric matrix data into the federated server
#' @param value An encoded value to be pushed
#' @import bigmemory parallel
#' @return Description of the pushed value
#' @export
# pushValue.bak <- function(value, name) {
#     valued <- dsSwissKnife:::.decode.arg(value)
#     stopifnot(is.list(valued) && length(valued)>0)
#     if (is.list(valued[[1]])) {
#         dscbigmatrix <- mclapply(valued, mc.cores=min(length(valued), detectCores()), function(x) {
#             x.mat <- do.call(rbind, x)
#             stopifnot(ncol(x.mat)==1)
#             return (describe(as.big.matrix(x.mat)))
#         })
#     } else {
#         valued.mat <- do.call(rbind, valued)
#         stopifnot(isSymmetric(valued.mat))
#         dscbigmatrix <- list(describe(as.big.matrix(valued.mat)))
#     }
#     return (dscbigmatrix)
# }
pushSymmMatrix <- function(value) {
    print("symmetric")
    valued <- dsSwissKnife:::.decode.arg(value)
    print("decoded")
    stopifnot(is.list(valued) && length(valued)>0)
    if (FALSE) {#is.list(valued[[1]])) {
        dscbigmatrix <- mclapply(valued, mc.cores=min(length(valued), detectCores()), function(x) {
            x.mat <- do.call(rbind, x)
            stopifnot(ncol(x.mat)==1)
            return (describe(as.big.matrix(x.mat)))
        })
    } else {
        # dscbigmatrix <- mclapply(valued, mc.cores=length(valued), function(y) {
        #     ## N.B. mclapply with length(y) cores allows allocating memory for all blocks. 
        #     ##      or only last mc.cores blocks are allocated.
        #     ##      lapply allocates memory only for the last block in the list.
        #     return (mclapply(y, mc.cores=length(y), function(x) {
        #         x.mat <- do.call(rbind, dsSwissKnife:::.decode.arg(x))
        #         return (describe(as.big.matrix(x.mat)))
        #     }))
        # })
        ## Possible solution: Rebuild the whole matrix here, and return its only allocation
        matblocks <- mclapply(valued, mc.cores=length(valued), function(y) {
            mclapply(y, mc.cores=length(y), function(x) {
                return (do.call(rbind, dsSwissKnife:::.decode.arg(x)))
            })
        })
        rm(list=c("valued"))
        uptcp <- lapply(matblocks, function(bl) do.call(cbind, bl))
        ## combine the blocks into one matrix
        if (length(uptcp)>1) {
            ## without the first layer of blocks
            no1tcp <- lapply(2:length(uptcp), function(i) {
                cbind(do.call(cbind, lapply(1:(i-1), function(j) {
                    t(matblocks[[j]][[i-j+1]])
                })), uptcp[[i]])
            })
            ## with the first layer of blocks
            tcp <- rbind(uptcp[[1]], do.call(rbind, no1tcp))
        } else {
            tcp <- uptcp[[1]]
        }
        stopifnot(isSymmetric(tcp))
        dscbigmatrix <- describe(as.big.matrix(tcp))
        rm(list=c("matblocks", "uptcp", "no1tcp", "tcp"))
    }
    return (dscbigmatrix)
}


#' @title Push a one-column matrix
#' @description Push one-column matrix data into the federated server
#' @param value An encoded value to be pushed
#' @import bigmemory parallel
#' @return Description of the pushed value
#' @export
pushSingMatrix <- function(value) {
    print("singular")
    valued <- dsSwissKnife:::.decode.arg(value)
    print(class(valued))
    print(lapply(valued, class))
    print(lapply(valued, head))
    print("decoded")
    stopifnot(is.list(valued) && length(valued)>0)
    dscbigmatrix <- mclapply(valued, mc.cores=min(length(valued), detectCores()), function(x) {
        x.mat <- do.call(rbind, dsSwissKnife:::.decode.arg(x))
        stopifnot(ncol(x.mat)==1)
        return (describe(as.big.matrix(x.mat)))
    })
    
    return (dscbigmatrix)
}


#' @title Find X from XX' and X'X
#' @description Find X from XX' and X'X
#' @param XXt XX'
#' @param XtX X'X
#' @param r A non-null vector of length \code{ncol(t(X)*X)}
#' @param Xr A vector of length \code{nrow(X * t(X))}, equals to the product X %*% r
#' @param TOL Tolerance of 0
#' @import parallel
#' @importFrom Matrix rankMatrix
#' @keywords internal
#' @return X
solveSSCP <- function(XXt, XtX, r, Xr, TOL = 1e-10) {
    if (length(r) != ncol(XtX)) {
        stop("r length shoud match ncol(XtX).")
    }
    if (length(Xr) != nrow(XXt)) {
        print(head(Xr))
        print(XXt[1:3,1:3])
        print(length(Xr))
        print(nrow(XXt))
        stop("Xr length shoud match nrow(XXt).")
    }
    if (max(abs(r)) < TOL) {
        stop("Cannot solve with r = 0.")
    }
    
    B1 <- XXt
    B2 <- XtX
    N1 <- nrow(B1)
    N2 <- nrow(B2)
    
    eB1 <- eigen(B1, symmetric=T)
    eB2 <- eigen(B2, symmetric=T)
    vecB1 <- eB1$vectors                    # not unique
    vecB2 <- eB2$vectors                    # not unique
    valB1 <- eB1$values
    valB2 <- eB2$values                     # valB2 == union(valB1, 0)
    vecs <- list("XXt"=vecB1, "XtX"=vecB2)
    vals <- list("XXt"=valB1, "XtX"=valB2)
    poseignum <- min(Matrix::rankMatrix(B1), Matrix::rankMatrix(B2))
    vals <- mclapply(vals, mc.cores=length(vals), function(x) {
        x[(poseignum+1):length(x)] <- 0
        return (x)
    })
    # if (N2 > N1) {
    #     tol <- max(abs(valB2[(N1+1):N2]))*10
    # } else if (N1 > N2) {
    #     tol <- max(abs(valB1[(N2+1):N1]))*10
    # } else {
    #     tol <- TOL
    # }
    # vals <- mclapply(vals, mc.cores=length(vals), function(x) {
    #     x[abs(x) < tol] <- 0
    #     return (x)
    # })
    # eignum <- length(vals[[1]])
    # poseignum <- unique(sapply(vals, function(x) {
    #     print(head(x, 10))
    #     max(which(x > 0))
    # }))
    # cat("Number of strictly positive eigenvalues:", poseignum, "with tolerance of", tol, "\n")
    # stopifnot(length(poseignum)==1)
    ## verify deduced info
    invisible(lapply(1:length(vecs), function(j) {
        vec <- vecs[[j]]
        cat("------", names(vecs)[j], "------\n")
        cat("Determinant:", det(vec), "\n")
        cat("Precision on v' = 1/v:", max(abs(t(vec) - solve(vec))), "\n")
        cat("Precision on Norm_col = 1:", max(abs(apply(vec, 2, function(x) norm(as.matrix(x), "2")) - 1)), "\n")
        cat("Precision on Norm_row = 1:", max(abs(apply(vec, 1, function(x) norm(as.matrix(x), "2")) - 1)), "\n")
        cat("Precision on Orthogonal:", max(sapply(1:(ncol(vec)-1), function(i) {
            max(sum(vec[i,] * vec[i+1,]), sum(vec[, i] * vec[, i+1]))
        })), "\n")
    }))
    
    ## solution S: X * r = vecB1 * E * S * vecB2' * r = Xr
    ## E * S * vecB2' * r = vecB1' * Xr = tmprhs1
    tmprhs1 <- crossprod(vecs[[1]], Xr)
    if (poseignum < N1) cat("Precision on tmprhs1's zero:", max(abs(tmprhs1[(poseignum+1):N1, 1])), "\n")
    ## S * vecB2' * rmX2 = S * lhs1 = 1/E * tmprhs1 = rhs1
    E <- diag(sqrt(vals[[1]][1:poseignum]))
    invE <- diag(1/diag(E))
    rhs1 <- crossprod(t(invE), tmprhs1[1:poseignum, , drop=F])
    lhs1 <- crossprod(vecs[[2]], r)
    signs1 <- rhs1[1:poseignum,]/lhs1[1:poseignum,]
    S <- cbind(diag(signs1), matrix(0, nrow=poseignum, ncol=N2-poseignum)) # S = [signs1 0]
    D <- rbind(crossprod(t(E), S), matrix(0, nrow=N1-poseignum, ncol=N2))  # D = E %*% S
    a1 <- tcrossprod(tcrossprod(vecs[[1]], t(D)), vecs[[2]]) # a = vecs[["A*A'"]] %*% D %*% t(vecs[["A'*A"]])
    
    cat("----------------------\n")
    cat("Precision on XXt = a1*a1':", max(abs(B1 - tcrossprod(a1))), "\n")
    cat("Precision on XtX = a1'*a1:", max(abs(B2 - crossprod(a1))), "\n")
    
    return (a1)
    
    # ## solution S: A' * r = vecB2 * S' * E' * vecB1' * r = Xr
    # ## S' * E' * vecB1' * r = S' * lhs2 = vecB2' * Xr = rhs2
    # rhs2 <- crossprod(vecs[[2]], Xr)
    # if (poseignum < N2) cat("Precision on rhs2's zero:", max(abs(rhs2[(poseignum+1):N2, 1])), "\n")
    # E <- diag(sqrt(vals[[1]][1:poseignum]))
    # 
    # lhs2 <- crossprod(E, crossprod(vecs[[1]][,1:poseignum], r))
    # signs2 <- rhs2[1:poseignum,]/lhs2[1:poseignum,]
    # 
    # ## check signs: signs2 should be identical to signs1
    # cat("Precision on signs double-check:", max(abs(signs1-signs2)), "\n")
    # 
    # S <- cbind(diag(signs2), matrix(0, nrow=poseignum, ncol=N2-poseignum)) # S = [signs1 0]
    # D <- rbind(crossprod(t(E), S), matrix(0, nrow=N1-poseignum, ncol=N2))  # D = E %*% S
    # a2 <- tcrossprod(tcrossprod(vecs[[1]], t(D)), vecs[[2]]) # a = vecs[["A*A'"]] %*% D %*% t(vecs[["A'*A"]])
    # 
    # cat("----------------------\n")
    # cat("Precision on XXt = a2*a2':", max(abs(B1 - tcrossprod(a2))), "\n")
    # cat("Precision on XtX = a2'*a2:", max(abs(B2 - crossprod(a2))), "\n")
    
    # return (a2)
}


#' @title Federated SSCP
#' @description Function for computing the federated SSCP matrix
#' @param loginFD Login information of the FD server
#' @param logins Login information of data repositories
#' @param querytab Encoded name of a table reference in data repositories
#' @param queryvar Encoded variables from the table reference
#' @param TOL Tolerance of 0
#' @import DSOpal parallel bigmemory
#' @keywords internal
federateSSCP <- function(loginFD, logins, querytab, queryvar, TOL = 1e-10) {
    require(DSOpal)

    loginFDdata    <- dsSwissKnife:::.decode.arg(loginFD)
    logindata      <- dsSwissKnife:::.decode.arg(logins)
    querytable     <- dsSwissKnife:::.decode.arg(querytab)
    queryvariables <- dsSwissKnife:::.decode.arg(queryvar)
    
    opals <- DSI::datashield.login(logins=logindata)
    nNode <- length(opals)

    datashield.assign(opals, "rawData", querytable, variables=queryvariables, async=T)
    datashield.assign(opals, "centeredData", as.symbol('center(rawData)'), async=T)
    datashield.assign(opals, "crossProdSelf", as.symbol('crossProd(centeredData)'), async=T)
    datashield.assign(opals, "tcrossProdSelf", as.symbol('tcrossProd(centeredData, chunk=50)'), async=T)

    ##- received by node i from other nodes ----
    invisible(mclapply(names(opals), mc.cores=1, function(opn) {
        logindata.opn <- logindata[logindata$server != opn, , drop=F]
        logindata.opn$user <- logindata.opn$userserver
        logindata.opn$password <- logindata.opn$passwordserver
        opals.loc <- paste0("crossLogin('", .encode.arg(logindata.opn), "')")
        datashield.assign(opals[opn], 'mates', as.symbol(opals.loc), async=F)
        
        command.opn <- list(paste0("crossAssign(mates, symbol='rawDataMate', value='", 
                                   querytab, 
                                   "', value.call=F, variables='",
                                   queryvar,
                                   "', async=F)"),
                            paste0("crossAssign(mates, symbol='centeredDataMate', value='",
                                   .encode.arg("center(rawDataMate)"),
                                   "', value.call=T, async=F)")
        )
        for (command in command.opn) {
            cat("Command: ", command, "\n")
            print(datashield.aggregate(opals[opn], as.symbol(command), async=F))
        }
        
        command.opn <- paste0("crossAggregate(mates, '", .encode.arg('singularProd(centeredDataMate)'), "', async=F)")
        cat("Command: ", command.opn, "\n")
        print(datashield.assign(opals[opn], "singularProdMate", as.symbol(command.opn), async=F))
        
        command.opn <- paste0("crossAggregate(mates, '", 
                              .encode.arg(paste0("as.call(list(as.symbol('pushValue'), dsSSCP:::.encode.arg(crossProdSelf), dsSSCP:::.encode.arg('", opn, "')))")), 
                              "', async=F)")
        cat("Command: ", command.opn, "\n")
        print(datashield.assign(opals[opn], "pidMate", as.symbol(command.opn), async=F))
    }))
    datashield.symbols(opals)
    #-----
    
    ## (X_i) * (X_i)': push this symmetric matrix from server i to FD
    #crossProdSelf     <- datashield.aggregate(opals, as.symbol('tcrossProd(centeredData)'), async=T)
    datashield.assign(opals, 'FD', as.symbol(paste0("crossLogin('", loginFD, "')")), async=T)
    
    # command <- paste0("crossAggregate(FD, '", 
    #                   .encode.arg(paste0("as.call(list(as.symbol('garbageCollect')", "))")), 
    #                   "', async=T)")
    # cat("Command: ", command, "\n")
    # datashield.assign(opals, "GC", as.symbol(command), async=T)
    
    command <- paste0("dscPush(FD, '", 
                      .encode.arg(paste0("as.call(list(as.symbol('pushSymmMatrix'), dsSSCP:::.encode.arg(tcrossProdSelf)", "))")), 
                      "', async=T)")
    cat("Command: ", command, "\n")
    crossProdSelfDSC <- datashield.aggregate(opals, as.symbol(command), async=T)
    
    crossProdSelf <- mclapply(crossProdSelfDSC, mc.cores=min(length(opals), detectCores()), function(dscblocks) {
        return (as.matrix(attach.big.matrix(dscblocks[[1]])))
        ## retrieve the blocks as matrices: on FD
        matblocks <- lapply(dscblocks[[1]], function(dscblock) {
            lapply(dscblock, function(dsc) {
                as.matrix(attach.big.matrix(dsc))
            })
        })
        uptcp <- lapply(matblocks, function(bl) do.call(cbind, bl))
        ## combine the blocks into one matrix
        if (length(uptcp)>1) {
            ## without the first layer of blocks
            no1tcp <- lapply(2:length(uptcp), function(i) {
                cbind(do.call(cbind, lapply(1:(i-1), function(j) {
                    t(matblocks[[j]][[i-j+1]])
                })), uptcp[[i]])
            })
            ## with the first layer of blocks
            tcp <- rbind(uptcp[[1]], do.call(rbind, no1tcp))
        } else {
            tcp <- uptcp[[1]]
        }
        stopifnot(isSymmetric(tcp))
        return (tcp)
    })
    gc(reset=F)

    ## (X_i) * (X_j)' * ((X_j) * (X_j)')[,1]: push this single-column matrix from server i to FD
    #singularProdCross <- datashield.aggregate(opals, as.symbol('tcrossProd(centeredData, singularProdMate)'), async=T)
    datashield.assign(opals, "singularProdCross", as.symbol('tcrossProd(centeredData, singularProdMate)'), async=T)
    
    command <- paste0("dscPush(FD, '", 
                      .encode.arg(paste0("as.call(list(as.symbol('pushSingMatrix'), dsSSCP:::.encode.arg(singularProdCross)", "))")), 
                      "', async=T)")
    cat("Command: ", command, "\n")
    singularProdCrossDSC <- datashield.aggregate(opals, as.symbol(command), async=T)
    
    singularProdCross <- mclapply(singularProdCrossDSC, mc.cores=length(singularProdCrossDSC), function(dscbigmatrix) {
        dscMatList <- lapply(dscbigmatrix[[1]], function(dsc) {
            dscMat <- matrix(as.matrix(attach.big.matrix(dsc)), ncol=1) #TOCHECK: with more than 2 servers
            stopifnot(ncol(dscMat)==1)
            return (dscMat)
        })
        return (dscMatList)
    })
    gc(reset=F)
    #return(singularProdCross)
    ##  (X_i) * (X_j)' * (X_j) * (X_i)'
    #prodDataCross     <- datashield.aggregate(opals, as.symbol('tripleProd(centeredData, crossProdMate)'), async=F)
    ## N.B. save-load increase numeric imprecision!!!
    prodDataCross     <- datashield.aggregate(opals, as.call(list(as.symbol("tripleProd"), 
                                                                  as.symbol("centeredData"), 
                                                                  .encode.arg(names(opals)))), async=T)
    ## deduced from received info by federation
    crossProductPair <- lapply(1:(nNode-1), function(opi) {
        crossi <- lapply((opi+1):(nNode), function(opj) {
            opni <- names(opals)[opi]
            opnj <- names(opals)[opj]

            a1 <- solveSSCP(XXt=prodDataCross[[opni]][[opnj]],
                            XtX=prodDataCross[[opnj]][[opni]],
                            r=crossProdSelf[[opnj]][, 1, drop=F],
                            Xr=singularProdCross[[opni]][[opnj]],
                            TOL=TOL)
            a2 <- solveSSCP(XXt=prodDataCross[[opnj]][[opni]],
                            XtX=prodDataCross[[opni]][[opnj]],
                            r=crossProdSelf[[opni]][, 1, drop=F],
                            Xr=singularProdCross[[opnj]][[opni]],
                            TOL=TOL)
            cat("Precision on a1 = t(a2):", max(abs(a1 - t(a2))), "\n")
            return (a1)
        })
        names(crossi) <- names(opals)[(opi+1):(nNode)]
        return (crossi)
    })
    names(crossProductPair) <- names(opals)[1:(nNode-1)]
    
    ## SSCP whole matrix
    XXt <- do.call(rbind, lapply(1:nNode, function(opi) {
        upper.opi <- do.call(cbind, as.list(crossProductPair[[names(opals)[opi]]]))
        lower.opi <- do.call(cbind, lapply(setdiff(1:opi, opi), function(opj) {
            t(crossProductPair[[names(opals)[opj]]][[names(opals)[opi]]])
        }))
        return (cbind(lower.opi, crossProdSelf[[opi]], upper.opi))
    }))
    datashield.logout(opals)
    
    return (XXt)
}


#' @title Federated ComDim
#' @description Function for ComDim federated analysis on the virtual cohort combining multiple cohorts
#' Finding common dimensions in multitable data (Xk, k=1...K)
#' @usage federateComDim(loginFD, logins, queryvar, querytab, size = NA, H = 2, scale = "none", option = "uniform", threshold = 1e-10, TOL = 1e-10)
#'
#' @param loginFD Login information of the FD server
#' @param logins Login information of data repositories
#' @param querytab Encoded name of a table reference in data repositories
#' @param queryvar Encoded list of variables from the table reference
#' @param TOL Tolerance of 0, deprecated
#' @param H :           number of common dimensions
#' @param scale  either value "none" / "sd" indicating the same scaling for all tables or a vector of scaling ("none" / "sd") for each table
#' @param option weighting of te tables \cr
#'        "none" :  no weighting of the tables - (default) \cr
#'      "uniform": weighting to set the table at the same inertia \cr
#' @param threshold if the difference of fit<threshold then break the iterative loop (default 1E-10)
#' @return \item{group}{ input parameter group }
#' @return \item{scale}{ scaling factor applied to the dataset X}
#' @return \item{Q}{common scores (nrow x ndim)}
#' @return \item{saliences}{weights associated to each table for each dimension}
#' @return \item{explained}{retun total variance explained}
#' @return \item{RV}{RV coefficients between each table (Xk) and compromise table}
#' @return \item{Block}{results associated with each table. You will find block component ...
#'         \itemize{
#'                \item {Qk}{: Block component}
#'                \item {Wk}{: Block component}
#'                \item {Pk}{: Block component}
#'        }}
#'
#' @return \item{call}{: call of the method }
#' @importFrom utils setTxtProgressBar
#' @importFrom DSI datashield.aggregate
#' @export
federateComDim <- function(loginFD, logins, queryvar, querytab, H = 2, scale = "none", option = "none", threshold = 1e-10, TOL = 1e-10) {
    queryvariables <- dsSwissKnife:::.decode.arg(queryvar)
    querytable     <- dsSwissKnife:::.decode.arg(querytab)
    
    ## compute SSCP matrix for each centered data table
    XX <- lapply(queryvariables, function(variables) {
        federateSSCP(loginFD, logins, querytable, .encode.arg(variables), TOL)
    })
    
    ## set up the centered data table on every node
    loginFDdata <- dsSwissKnife:::.decode.arg(loginFD)
    logindata <- dsSwissKnife:::.decode.arg(logins)
    opals <- DSI::datashield.login(logins=logindata)
    nNode <- length(opals)
    
    if (length(querytable)==1) {
        ## TODO: make sure different blocks have the same samples (rownames)
        datashield.assign(opals, "rawAllData", querytable, variables=unlist(queryvariables), async=T)
        datashield.assign(opals, "centeredAllData", as.symbol('center(rawAllData)'), async=T)
    } else if (length(querytable)==length(queryvariables)) {
        stop("Not yet implemented.")
    } else (
        stop("querytab should contain 1 or length(queryvar) names.")
    )

    # compute the total variance of a dataset
    inertie <- function(tab) {
        return (sum(diag(tab)))    #Froebenius norm
    }

    ## compute the RV between WX and WY
    coefficientRV <- function(WX, WY) {
        rv <- sum(diag(WX %*% WY))/((sum(diag(WX %*% WX)) * sum(diag(WY %*% WY)))^0.5)
        return(rv)
    }
    # ---------------------------------------------------------------------------
    # 0. Preliminary tests
    # ---------------------------------------------------------------------------
    if (any(sapply(XX, is.na)))
        stop("No NA values are allowed")
    nsamples <- unique(unlist(apply(sapply(XX, dim), 1, unique))) ## number of samples
    if (length(nsamples) > 1)
        stop("XX elements should be symmetric of the same dimension")
    samples <- sapply(XX, function(x) union(rownames(x), colnames(x)))
    if (is.list(samples) && max(lengths(samples))==0) {
        XX <- lapply(XX, function(x) {
            rownames(x) <- colnames(x) <- paste("X", 1:nsamples, sep='.')
            return (x)
        })
        samples <- sapply(XX, function(x) union(rownames(x), colnames(x)))
    }
    if (is.list(samples) || is.list(apply(samples, 1, unique)))
        stop("XX elements should have the same rownames and colnames")
    
    if (is.null(names(queryvariables)))
        names(queryvariables) <- paste("Tab", 1:length(queryvariables), sep=".")
    
    ## TOREVIEW
    # if (is.character(scale)) {
    #   if (!scale %in% c("none","sd"))
    #     stop("Non convenient scaling parameter")
    # }
    # else {
    #   if (!is.numeric(scale) | length(scale)!=ncol(X))
    #     stop("Non convenient scaling parameter")
    # }
    # if (!option %in% c("none","uniform"))
    #   stop("Non convenient weighting parameter")
    
    
    # ---------------------------------------------------------------------------
    # 1. Output preparation
    # ---------------------------------------------------------------------------
    ntab <- length(XX)
    nvar <- lengths(queryvariables)
    W <- array(0, dim=c(nsamples, nsamples, ntab+1)) # association matrices
    
    LAMBDA <- matrix(0, nrow=ntab, ncol=H)   # will contains the saliences
    Q <- matrix(0, nrow=nsamples, ncol=H)    # will contain common components
    J <- rep(1:ntab, times=nvar)             # indicates which block each variable belongs to
    names.H <- paste("Dim.", 1:H, sep="")
    Q.b <- array(0, dim=c(nsamples,H,ntab))  # components for the block components
    dimnames(Q.b) <- list(rownames(XX[[1]]), names.H, names(queryvariables))
    W.b <- vector("list",length=ntab)        # weights for the block components
    P.b <- vector("list",length=ntab)        # loadings for the block components
    for (k in 1:ntab) {
        W.b[[k]] <- matrix(0,nrow=nvar[k],ncol=H)
        P.b[[k]] <- matrix(0,nrow=nvar[k],ncol=H)
        rownames(W.b[[k]]) <- rownames(P.b[[k]]) <- queryvariables[[k]]
        colnames(W.b[[k]]) <- colnames(P.b[[k]]) <- names.H
    }
    We <- Pe <- matrix(0,nrow=sum(nvar),ncol=H)
    Res <- NULL              # Results to be returned
    
    explained.block <- matrix(0, nrow=ntab+1,ncol=H)      # percentage of inertia recovered
    
    # ---------------------------------------------------------------------------
    # 2. Required parameters and data preparation
    # ---------------------------------------------------------------------------
    
    
    #Xscale$mean <- apply(X, 2, mean)
    #X<-scale(X, center=Xscale$mean, scale=FALSE)   #default centering
    
    
    # if (scale=="none") {
    #   Xscale$scale <-rep(1,times=ncol(X))
    # }
    # else {
    #   if (scale=="sd") {
    #     sd.tab <- apply(X, 2, function (x) {return(sqrt(sum(x^2)/length(x)))})   #sd based on biased variance
    #     temp <- sd.tab < 1e-14
    #     if (any(temp)) {
    #       warning("Variables with null variance not standardized.")
    #       sd.tab[temp] <- 1
    #     }
    #     X <- sweep(X, 2, sd.tab, "/")
    #     Xscale$scale <-sd.tab
    #   }
    #   else {     #specific scaling depending on blocks defined as a vector with a scaling parameter for each variable
    #       X <- sweep(X, 2, scale, "/")
    #       Xscale$scale <-scale
    #   }
    # }
    
    # Pre-processing: block weighting
    inertia <- sapply(1:ntab, function(k) inertie(XX[[k]]))
    # if (option=="uniform") {
    #    #set each block inertia equal 1
    #   w.tab <- rep(sqrt(inertia), times=nvar)     # weighting parameter applied to each variable
    #   X <- sweep(X, 2, w.tab, "/")
    #   Xscale$scale<- Xscale$scale*w.tab
    #   inertia <- rep(1, times=ntab)
    # }
    if (option=="uniform") {
        XX <- lapply(1:ntab, function(k) {
            XX[[k]]/inertia[k]
        })
        inertia0.sqrt <- sqrt(inertia)
        inertia <- rep(1, times=ntab)
    }
    
    # Computation of association matrices
    W[,,1:ntab] <- array(as.numeric(unlist(XX)), dim=c(nsamples, nsamples, ntab))
    tvar <- sapply(1:ntab, function(k) sum(as.matrix(W[,,k])^2))
    Itot <- sum(tvar) # Total inertia of all dataset sum(trace(Wj*Wj))
    
    #X0 <- X            #keep initial values with standardisation and weighting scheme
    # ---------------------------------------------------------------------------
    # 3. computation of Q and LAMBDA for the various dimensions
    # ---------------------------------------------------------------------------
    explained <- matrix(0, nrow=H, ncol=1)
    
    pb <- txtProgressBar(min=0, max=H, style=3)
    
    for (dimension in 1:H)  {
        Sys.sleep(0.1)
        
        previousfit <- 100000;
        lambda <- rep(1, ntab)
        deltafit <- 1000000;
        while (deltafit > threshold) {
            W[,,ntab+1] <- Reduce("+", lapply(1:ntab, function(k) lambda[k]*W[,,k]))
            Svdw <- svd(as.matrix(W[,,ntab+1]))
            q <- Svdw$u[,1,drop=F]
            
            fit <- 0
            for (k in 1:ntab) {
                # estimating residuals
                lambda[k]  <- (t(q) %*% as.matrix(W[,,k]) %*% q)
                pred       <- lambda[k]*q %*% t(q)
                aux        <- as.matrix(W[,,k]) - pred
                fit        <- fit + sum(aux^2)
            }
            deltafit <- previousfit - fit
            previousfit <- fit
        } #deltafit>threshold
        
        explained[dimension,1] <- 100*sum(lambda^2)/Itot  ## vca modif
        LAMBDA[,dimension] <- lambda
        Q[,dimension] <- q
        
        # updating association matrices
        proj <- diag(1, nsamples) - tcrossprod(q)
        for (k in 1:ntab)   {
            #W.b[[k]][,dimension] <- t(X[,J==k]) %*% q
            ##TODO
            
            #Q.b[,dimension,k]    <- X[,J==k]%*%matrix(W.b[[k]][,dimension],ncol=1)
            Q.b[,dimension,k] <- W[,,k] %*% q
            
            #P.b[[k]][,dimension] <- t(W.b[[k]][,dimension])#t(q)%*%X[,J==k]
            ##TODO
            
            #Pe[J==k,dimension]   <- P.b[[k]][,dimension]
            ##TODO
            
            #X <- as.matrix(X)
            #X.hat <- q%*%matrix(P.b[[k]][,dimension],nrow=1)
            ##TODO
            
            #explained.block[k,dimension] <- inertie(X.hat)
            explained.block[k,dimension] <- inertie(tcrossprod(q) %*% W[,,k] %*% tcrossprod(q))
            
            #X[,J==k] <- X[,J==k]-X.hat
            ##TODO
            
            #W[,,k] <- X[,J==k]%*%t(X[,J==k]);
            W[,,k] <- proj %*% W[,,k] %*% t(proj)
        }
        explained.block[ntab+1,dimension]<- sum(explained.block[1:ntab,dimension])
        #We[,dimension]   <- unlist(sapply(1:ntab,function(j){lambda[j]*W.b[[j]][,dimension]}))
        #We[,dimension]   <- We[,dimension] / sum(lambda^2)
        setTxtProgressBar(pb, dimension)
    }
    
    ## loadings
    
    # number of samples on each node
    size <- sapply(datashield.aggregate(opals, as.symbol('dimDSS(centeredAllData)'), async=T), function(x) x[1])
    size <- c(0, size)
    func <- function(x, y) {x %*% y}
    Qlist <- setNames(lapply(2:length(size), function(i) {
        Qi <- Q[(cumsum(size)[i-1]+1):cumsum(size)[i],,drop=F]
        ## As Q is orthonormal, Qi == Qi.iter
        # Qi.iter <- sapply(1:H, function(dimension) {
        #   projs <- lapply(setdiff(1:dimension, dimension), function(dimprev) {
        #     return (diag(1, size[i]) - tcrossprod(Qi[,dimprev]))
        #   })
        #   projs <- c(Id=list(diag(1, size[i])), projs)
        #   return (crossprod(Reduce(func, projs), Qi[,dimension,drop=F]))
        # })
        # return (Qi.iter)
    }), names(opals))

    Wbk <- Reduce('+', unlist(mclapply(names(opals), mc.cores=1, function(opn) {
        expr <- list(as.symbol("loadings"),
                     as.symbol("centeredAllData"),
                     .encode.arg(Qlist[[opn]]))
        loadings <- datashield.aggregate(opals[opn], as.call(expr), async=T)
        return (loadings)
    }), recursive = F))
    datashield.logout(opals)
    colnames(Wbk) <- names.H
    csnvar <- cumsum(nvar)
    W.b <- mclapply(1:length(nvar), mc.cores=length(nvar), function(k) {
        if (option=="uniform") return (Wbk[ifelse(k==1, 1, csnvar[k-1]+1):csnvar[k], , drop=F]/inertia0.sqrt[k])
        return (Wbk[ifelse(k==1, 1, csnvar[k-1]+1):csnvar[k], , drop=F])
    })
    
    # W.b <- lapply(1:ntab, function(k) {
    #     #Wbk <- crossprod(as.matrix(X[,J==k]), Q)
    #     Wbk <- Reduce('+', unlist(mclapply(names(opals), mc.cores=1, function(opn) {
    #         expr <- list(as.symbol("loadings"),
    #                      as.symbol("centeredAllData"),
    #                      .encode.arg(Qlist[[opn]]))
    #         loadings <- datashield.aggregate(opals[opn], as.call(expr), async=F)
    #         return (loadings)
    #     }), recursive = F))
    #     
    #     colnames(Wbk) <- names.H
    #     return (Wbk/inertia0.sqrt)
    # })
    # return (W.b)

    We <- do.call(rbind, lapply(1:ntab, function(k) tcrossprod(W.b[[k]], diag(LAMBDA[k,]))))
    #We <- do.call(rbind, lapply(1:ntab, function(k) W.b[[k]] %*% diag(LAMBDA[k,]))) #crossprod(as.matrix(X[,J==k]), Q)
    
    P.b <- W.b #lapply(W.b, function(x) t(x))
    Pe  <- do.call(rbind, P.b)
    We  <- sapply(1:H, function(dimension) We[,dimension]/sum(LAMBDA[,dimension]^2))
    colnames(We) <- names.H
    
    # ---------------------------------------------------------------------------
    # 4.1 Preparation of the results Global
    # ---------------------------------------------------------------------------
    close(pb)
    
    # Overall agreement
    if (H==1) {
        LambdaMoyen <- apply(LAMBDA, 2, mean)
        C <- Q*LambdaMoyen
    } else {
        LambdaMoyen <- apply(LAMBDA,2,mean)
        C <- Q %*% sqrt(diag(LambdaMoyen))
    }
    
    rownames(C) <- rownames(XX[[1]])
    colnames(C) <- names.H
    
    RV <- sapply(1:ntab, function(k) {
        coefficientRV(XX[[k]], tcrossprod(C))
    })
    names(RV) <- names(queryvariables)
    
    # global components, saliences and explained variances
    Res$saliences <- LAMBDA
    colnames(Res$saliences) <- names.H
    rownames(Res$saliences) <- names(queryvariables)
    Res$Q <- Q
    rownames(Res$Q) <- rownames(XX[[1]])
    colnames(Res$Q) <- names.H
    Res$C  <- C
    Res$RV <- RV
    Res$W  <- We
    Res$Wm <- We %*% solve(t(Pe)%*%We)
    rownames(Res$Wm) <- rownames(Res$W)
    colnames(Res$Wm) <- colnames(Res$W) <- names.H
    
    fit <- matrix(0,nrow=H,ncol=2)
    fit[,1] <- explained
    fit[,2] <- cumsum(fit[,1])
    Res$fit <- fit
    rownames(Res$fit) <- names.H
    colnames(Res$fit) <- c("%Fit", "%Cumul Fit")
    
    inertia                 <- c(inertia, sum(inertia))
    Res$explained           <- sweep(explained.block, 1, inertia, "/")
    rownames(Res$explained) <- c(rownames(Res$saliences), 'global')
    colnames(Res$explained) <- colnames(Res$saliences)
    
    
    # ---------------------------------------------------------------------------
    # 4.2 Preparation of the results Blocks
    # ---------------------------------------------------------------------------
    Block     <- NULL
    Block$Q.b <- Q.b
    Block$W.b <- W.b
    Block$P.b <- P.b
    Res$Block <- Block
    
    # ---------------------------------------------------------------------------
    # Return Res
    # ---------------------------------------------------------------------------
    Res$call   <- match.call()
    class(Res) <- c("federateComDim")
    
    return(Res)
}

