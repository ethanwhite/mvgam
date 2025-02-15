#'@title Extract or compute hindcasts and forecasts for a fitted \code{mvgam} object
#'@name forecast.mvgam
#'@importFrom parallel clusterExport stopCluster setDefaultCluster
#'@importFrom stats predict
#'@importFrom rlang missing_arg
#'@inheritParams predict.mvgam
#'@param newdata Optional \code{dataframe} or \code{list} of test data containing at least 'series' and 'time'
#'in addition to any other variables included in the linear predictor of the original \code{formula}. If included, the
#'covariate information in \code{newdata} will be used to generate forecasts from the fitted model equations. If
#'this same \code{newdata} was originally included in the call to \code{mvgam}, then forecasts have already been
#'produced by the generative model and these will simply be extracted and plotted. However if no \code{newdata} was
#'supplied to the original model call, an assumption is made that the \code{newdata} supplied here comes sequentially
#'after the data supplied as \code{data} in the original model (i.e. we assume there is no time gap between the last
#'observation of series 1 in \code{data} and the first observation for series 1 in \code{newdata})
#'@param data_test Deprecated. Still works in place of \code{newdata} but users are recommended to use
#'\code{newdata} instead for more seamless integration into `R` workflows
#'@param series Either a \code{integer} specifying which series in the set is to be forecast,
#'or the character string \code{'all'}, specifying that all series should be forecast. This is preferable
#'if the fitted model contained multivariate trends (either as a dynamic factor or \code{VAR} process),
#'as it saves recomputing the full set of trends for each series individually
#'@param n_cores \code{integer} specifying number of cores for generating forecasts in parallel
#'@param ... Ignored
#'@details Posterior predictions are drawn from the fitted \code{mvgam} and used to simulate a forecast distribution
#'@return An object of class \code{mvgam_forecast} containing hindcast and forecast distributions.
#'See \code{\link{mvgam_forecast-class}} for details.
#'@seealso \code{\link{hindcast}}, \code{\link{score}}
#'@export
forecast <- function(object, ...){
  UseMethod("forecast", object)
}

#'@rdname forecast.mvgam
#'@method forecast mvgam
#' @examples
#' \dontrun{
#' simdat <- sim_mvgam(n_series = 3, trend_model = 'AR1')
#' mod <- mvgam(y ~ s(season, bs = 'cc'),
#'             trend_model = 'AR1',
#'             data = simdat$data_train)
#'
#' # Hindcasts on response scale
#' hc <- hindcast(mod)
#' str(hc)
#' plot(hc, series = 1)
#' plot(hc, series = 2)
#' plot(hc, series = 3)
#'
#' # Forecasts on response scale
#' fc <- forecast(mod, newdata = simdat$data_test)
#' str(fc)
#' plot(fc, series = 1)
#' plot(fc, series = 2)
#' plot(fc, series = 3)
#'
#' # Forecasts as expectations
#' fc <- forecast(mod, newdata = simdat$data_test, type = 'expected')
#' plot(fc, series = 1)
#' plot(fc, series = 2)
#' plot(fc, series = 3)
#'
#' }
#'@export
forecast.mvgam = function(object, newdata, data_test, series = 'all',
                          n_cores = 1,
                          type = 'response',
                          ...){
  # Check arguments
  validate_pos_integer(n_cores)

  if(is.character(series)){
    if(series != 'all'){
      stop('argument "series" must be either a positive integer or "all"',
           call. =  FALSE)
    }
  } else {
    validate_pos_integer(series)
    if(series > NCOL(object$ytimes)){
      stop(paste0('object only contains data / predictions for ', NCOL(object$ytimes), ' series'),
           call. = FALSE)
    }
  }

  if(!missing("newdata")){
    data_test <- newdata
  }

  if(missing("newdata") & missing(data_test) & is.null(object$test_data)){
    stop('newdata must be supplied to compute forecasts',
         call. = FALSE)
  }

  type <- match.arg(arg = type, choices = c("link", "response", "trend", "expected"))
  data_train <- object$obs_data

  if(series != 'all'){
    s_name <- levels(data_train$series)[series]
  }
  n_series <- NCOL(object$ytimes)

  # Check whether a forecast has already been computed
  forecasts_exist <- FALSE
  if(!is.null(object$test_data) && !missing(data_test)){
    if(max(data_test$time) <= max(object$test_data$time)){
      forecasts_exist <- TRUE
    } else {
      data_test %>%
        dplyr::filter(time > max(object$test_data$time)) -> data_test
    }
  }

  if(!is.null(object$test_data) && missing(data_test)){
    forecasts_exist <- TRUE
  }

  if(is.null(object$test_data)){
    data_test %>%
      dplyr::filter(time > max(object$obs_data$time)) -> data_test
  }

  # Only compute forecasts if they don't already exist!
  if(!forecasts_exist){

    # Ensure outcome is labelled 'y' when feeding data to the model for simplicity
    if(terms(formula(object$call))[[2]] != 'y'){
      data_test$y <- data_test[[terms(formula(object$call))[[2]]]]
    }

    if(!missing(data_test)){
      if(!'y' %in% names(data_test)){
        data_test$y <- rep(NA, NROW(data_test))
      }
      data_test <- validate_series_time(data_test, name = 'newdata')
    }

    # Generate draw-specific forecasts
    fc_preds <- forecast_draws(object = object,
                               type = type,
                               series = series,
                               data_test = data_test,
                               n_cores = n_cores)

    # Extract hindcasts and forecasts into the correct format
    if(series == 'all'){
      series_fcs <- lapply(seq_len(n_series), function(series){
        indexed_forecasts <- do.call(rbind, lapply(seq_along(fc_preds), function(x){
          fc_preds[[x]][[series]]
        }))
        indexed_forecasts
      })
      names(series_fcs) <- levels(data_test$series)

      # Extract hindcasts for storing in the returned object
      data_train <- object$obs_data
      ends <- seq(0, dim(mcmc_chains(object$model_output, 'ypred'))[2],
                  length.out = NCOL(object$ytimes) + 1)
      starts <- ends + 1
      starts <- c(1, starts[-c(1, (NCOL(object$ytimes)+1))])
      ends <- ends[-1]

      series_hcs <- lapply(seq_len(n_series), function(series){
        to_extract <- switch(type,
                             'link' = 'mus',
                             'expected' = 'mus',
                             'response' = 'ypred',
                             'trend' = 'trend')
        if(object$fit_engine == 'stan'){

          preds <- mcmc_chains(object$model_output, to_extract)[,seq(series,
                                                                     dim(mcmc_chains(object$model_output, 'ypred'))[2],
                                                                     by = NCOL(object$ytimes))]
        } else {
          preds <- mcmc_chains(object$model_output, to_extract)[,starts[series]:ends[series]]
        }

        if(type == 'expected'){

          # Compute expectations as one long vector
          Xpmat <- matrix(as.vector(preds))
          attr(Xpmat, 'model.offset') <- 0

          family_pars <- extract_family_pars(object = object)
          par_extracts <- lapply(seq_along(family_pars), function(j){
            if(is.matrix(family_pars[[j]])){
              family_pars[[j]][, series]
            } else {
              family_pars[[j]]
            }
          })
          names(par_extracts) <- names(family_pars)

          preds <- matrix(as.vector(mvgam_predict(family = object$family,
                                                  Xp = Xpmat,
                                                  type = 'expected',
                                                  betas = 1,
                                                  family_pars = par_extracts)),
                          nrow = NROW(preds))
        }
        preds
      })
      names(series_hcs) <- levels(data_test$series)

      series_obs <- lapply(seq_len(n_series), function(series){
        s_name <- levels(object$obs_data$series)[series]
        data.frame(series = object$obs_data$series,
                   time = object$obs_data$time,
                   y = object$obs_data$y) %>%
          dplyr::filter(series == s_name) %>%
          dplyr::arrange(time) %>%
          dplyr::pull(y)
      })
      names(series_obs) <- levels(data_test$series)

      series_test <- lapply(seq_len(n_series), function(series){
        s_name <- levels(object$obs_data$series)[series]
        data.frame(series = data_test$series,
                   time = data_test$time,
                   y = data_test$y) %>%
          dplyr::filter(series == s_name) %>%
          dplyr::arrange(time) %>%
          dplyr::pull(y)
      })
      names(series_test) <- levels(data_test$series)

    } else {
      series_fcs <- list(do.call(rbind, fc_preds))
      names(series_fcs) <- s_name

      # Extract hindcasts for storing in the returned object
      data_train <- object$obs_data
      ends <- seq(0, dim(mcmc_chains(object$model_output, 'ypred'))[2],
                  length.out = NCOL(object$ytimes) + 1)
      starts <- ends + 1
      starts <- c(1, starts[-c(1, (NCOL(object$ytimes)+1))])
      ends <- ends[-1]
      to_extract <- switch(type,
                           'link' = 'mus',
                           'expected' = 'mus',
                           'response' = 'ypred',
                           'trend' = 'trend')
      if(object$fit_engine == 'stan'){
        preds <- mcmc_chains(object$model_output, to_extract)[,seq(series,
                                                                   dim(mcmc_chains(object$model_output, 'ypred'))[2],
                                                                   by = NCOL(object$ytimes))]
      } else {
        preds <- mcmc_chains(object$model_output, to_extract)[,starts[series]:ends[series]]
      }

      if(type == 'expected'){

        # Compute expectations as one long vector
        Xpmat <- matrix(as.vector(preds))
        attr(Xpmat, 'model.offset') <- 0
        preds <- matrix(as.vector(mvgam_predict(family = object$family,
                                                Xp = Xpmat,
                                                type = 'expected',
                                                betas = 1,
                                                family_pars = extract_family_pars(object = object))),
                        nrow = NROW(preds))
      }

      series_hcs <- list(preds)
      names(series_hcs) <- s_name

      series_obs <- list(data.frame(series = object$obs_data$series,
                                    time = object$obs_data$time,
                                    y = object$obs_data$y) %>%
                           dplyr::filter(series == s_name) %>%
                           dplyr::arrange(time) %>%
                           dplyr::pull(y))
      names(series_obs) <- s_name

      series_test <- list(data.frame(series = data_test$series,
                                     time = data_test$time,
                                     y = data_test$y) %>%
                            dplyr::filter(series == s_name) %>%
                            dplyr::arrange(time) %>%
                            dplyr::pull(y))
      names(series_test) <- s_name
    }

  } else {
    # If forecasts already exist, simply extract them
   data_test <- object$test_data
    last_train <- max(object$obs_data$time) -
      (min(object$obs_data$time) - 1)

    if(series == 'all'){
      data_train <- object$obs_data
      ends <- seq(0, dim(mcmc_chains(object$model_output, 'ypred'))[2],
                  length.out = NCOL(object$ytimes) + 1)
      starts <- ends + 1
      starts <- c(1, starts[-c(1, (NCOL(object$ytimes)+1))])
      ends <- ends[-1]

      series_fcs <- lapply(seq_len(n_series), function(series){
        to_extract <- switch(type,
                             'link' = 'mus',
                             'expected' = 'mus',
                             'response' = 'ypred',
                             'trend' = 'trend')
        if(object$fit_engine == 'stan'){

          preds <- mcmc_chains(object$model_output, to_extract)[,seq(series,
                                                                     dim(mcmc_chains(object$model_output, 'ypred'))[2],
                                                                     by = NCOL(object$ytimes))]
        } else {
          preds <- mcmc_chains(object$model_output, to_extract)[,starts[series]:ends[series]][,1:last_train]
        }

        if(type == 'expected'){

          # Compute expectations as one long vector
          Xpmat <- matrix(as.vector(preds))
          attr(Xpmat, 'model.offset') <- 0

          family_pars <- extract_family_pars(object = object)
          par_extracts <- lapply(seq_along(family_pars), function(j){
            if(is.matrix(family_pars[[j]])){
              family_pars[[j]][, series]
            } else {
              family_pars[[j]]
            }
          })
          names(par_extracts) <- names(family_pars)

          preds <- matrix(as.vector(mvgam_predict(family = object$family,
                                                  Xp = Xpmat,
                                                  type = 'expected',
                                                  betas = 1,
                                                  family_pars = par_extracts)),
                          nrow = NROW(preds))
        }

        preds[,(last_train+1):NCOL(preds)]
      })
      names(series_fcs) <- levels(data_train$series)

      # Extract hindcasts for storing in the returned object
      series_hcs <- lapply(seq_len(n_series), function(series){
        to_extract <- switch(type,
                             'link' = 'mus',
                             'expected' = 'mus',
                             'response' = 'ypred',
                             'trend' = 'trend')
        if(object$fit_engine == 'stan'){

          preds <- mcmc_chains(object$model_output, to_extract)[,seq(series,
                                                                     dim(mcmc_chains(object$model_output, 'ypred'))[2],
                                                                     by = NCOL(object$ytimes))][,1:last_train]
        } else {
          preds <- mcmc_chains(object$model_output, to_extract)[,starts[series]:ends[series]][,1:last_train]
        }

        if(type == 'expected'){

          # Compute expectations as one long vector
          Xpmat <- matrix(as.vector(preds))
          attr(Xpmat, 'model.offset') <- 0

          family_pars <- extract_family_pars(object = object)
          par_extracts <- lapply(seq_along(family_pars), function(j){
            if(is.matrix(family_pars[[j]])){
              family_pars[[j]][, series]
            } else {
              family_pars[[j]]
            }
          })
          names(par_extracts) <- names(family_pars)

          preds <- matrix(as.vector(mvgam_predict(family = object$family,
                                                  Xp = Xpmat,
                                                  type = 'expected',
                                                  betas = 1,
                                                  family_pars = par_extracts)),
                          nrow = NROW(preds))
        }
        preds
      })
      names(series_hcs) <- levels(data_train$series)

      series_obs <- lapply(seq_len(n_series), function(series){
        s_name <- levels(object$obs_data$series)[series]
        data.frame(series = object$obs_data$series,
                   time = object$obs_data$time,
                   y = object$obs_data$y) %>%
          dplyr::filter(series == s_name) %>%
          dplyr::arrange(time) %>%
          dplyr::pull(y)
      })
      names(series_obs) <- levels(data_train$series)

      series_test <- lapply(seq_len(n_series), function(series){
        s_name <- levels(object$obs_data$series)[series]
        data.frame(series = object$test_data$series,
                   time = object$test_data$time,
                   y = object$test_data$y) %>%
          dplyr::filter(series == s_name) %>%
          dplyr::arrange(time) %>%
          dplyr::pull(y)
      })
      names(series_test) <- levels(data_train$series)

    } else {
      data_train <- object$obs_data
      ends <- seq(0, dim(mcmc_chains(object$model_output, 'ypred'))[2],
                  length.out = NCOL(object$ytimes) + 1)
      starts <- ends + 1
      starts <- c(1, starts[-c(1, (NCOL(object$ytimes)+1))])
      ends <- ends[-1]
      to_extract <- switch(type,
                           'link' = 'mus',
                           'expected' = 'mus',
                           'response' = 'ypred',
                           'trend' = 'trend')

      # Extract forecasts
      if(object$fit_engine == 'stan'){
        preds <- mcmc_chains(object$model_output, to_extract)[,seq(series,
                                                                   dim(mcmc_chains(object$model_output, 'ypred'))[2],
                                                                   by = NCOL(object$ytimes))]
      } else {
        preds <- mcmc_chains(object$model_output, to_extract)[,starts[series]:ends[series]]
      }

      if(type == 'expected'){

        # Compute expectations as one long vector
        Xpmat <- matrix(as.vector(preds))
        attr(Xpmat, 'model.offset') <- 0

        family_pars <- extract_family_pars(object = object)
        par_extracts <- lapply(seq_along(family_pars), function(j){
          if(is.matrix(family_pars[[j]])){
            family_pars[[j]][, series]
          } else {
            family_pars[[j]]
          }
        })
        names(par_extracts) <- names(family_pars)

        preds <- matrix(as.vector(mvgam_predict(family = object$family,
                                                Xp = Xpmat,
                                                type = 'expected',
                                                betas = 1,
                                                family_pars = par_extracts)),
                        nrow = NROW(preds))
      }
      series_fcs <- list(preds[,(last_train+1):NCOL(preds)])
      names(series_fcs) <- s_name

      # Extract hindcasts
      series_hcs <- list(preds[,1:last_train])
      names(series_hcs) <- s_name

      # Training observations
      series_obs <- list(data.frame(series = object$obs_data$series,
                                    time = object$obs_data$time,
                                    y = object$obs_data$y) %>%
                           dplyr::filter(series == s_name) %>%
                           dplyr::arrange(time) %>%
                           dplyr::pull(y))
      names(series_obs) <- s_name

      # Testing observations
      series_test <- list(data.frame(series = object$test_data$series,
                                     time = object$test_data$time,
                                     y = object$test_data$y) %>%
                            dplyr::filter(series == s_name) %>%
                            dplyr::arrange(time) %>%
                            dplyr::pull(y))
      names(series_test) <- s_name
    }
  }

  series_fcs <- structure(list(call = object$call,
                               trend_call = object$trend_call,
                               family = object$family,
                               family_pars = if(type == 'link'){
                                 extract_family_pars(object = object)
                               } else {
                                 NULL
                               },
                               trend_model = object$trend_model,
                               drift = object$drift,
                               use_lv = object$use_lv,
                               fit_engine = object$fit_engine,
                               type = type,
                               series_names = factor(unique(data_train$series),
                                                     levels = levels(data_train$series)),
                               train_observations = series_obs,
                               train_times = unique(data_train$time),
                               test_observations = series_test,
                               test_times = unique(data_test$time),
                               hindcasts = series_hcs,
                               forecasts = series_fcs),
                          class = 'mvgam_forecast')
  return(series_fcs)
}

#'Compute forecasts using a posterior distribution
#'@noRd
forecast_draws = function(object,
                          type = 'response',
                          series = 'all',
                          data_test,
                          n_cores = 1,
                          n_samples,
                          ending_time){

  # Check arguments
  validate_pos_integer(n_cores)
  n_series <- NCOL(object$ytimes)
  use_lv <- object$use_lv

  if(series != 'all'){
    s_name <- levels(data_test$series)[series]
  }
  n_series <- NCOL(object$ytimes)

  # Generate the observation model linear predictor matrix
  if(inherits(data_test, 'list')){
    Xp <- obs_Xp_matrix(newdata = data_test,
                        mgcv_model = object$mgcv_model)

    if(series != 'all'){
      obs_keep <- data.frame(y = data_test$y,
                             series = data_test$series,
                             time = data_test$time,
                             rowid = 1:length(data_test$y)) %>%
        dplyr::filter(series == s_name) %>%
        dplyr::arrange(time) %>%
        dplyr::pull(rowid)
      series_test <- data.frame(y = data_test$y,
                                series = data_test$series,
                                time = data_test$time,
                                rowid = 1:length(data_test$y)) %>%
        dplyr::filter(series == s_name) %>%
        dplyr::arrange(time)
      Xp <- Xp[obs_keep, ]
    } else {
      series_test <- NULL
    }
  } else {
    if(series != 'all'){
      series_test <- data_test %>%
        dplyr::filter(series == s_name) %>%
        dplyr::arrange(time)
      Xp <- obs_Xp_matrix(newdata = series_test,
                          mgcv_model = object$mgcv_model)
    } else {
      Xp <- obs_Xp_matrix(newdata = data_test,
                          mgcv_model = object$mgcv_model)
      series_test <- NULL
    }
  }

  # Generate linear predictor matrix from trend mgcv model
  if(!is.null(object$trend_call)){
    Xp_trend <- trend_Xp_matrix(newdata = data_test,
                                trend_map = object$trend_map,
                                series = series,
                                mgcv_model = object$trend_mgcv_model)

    # For trend_formula models with autoregressive processes,
    # the process model operates as: AR * (process[t - 1] - mu[t-1]])
    # We therefore need the values of mu at the end of the training set
    # to correctly propagate the process model forward
    if(use_lv & attr(object$model_data, 'trend_model') != 'GP'){
      # Get the observed trend predictor matrix
      Xp_trend_last <- trend_Xp_matrix(newdata = object$obs_data,
                                       trend_map = object$trend_map,
                                       series = series,
                                       mgcv_model = object$trend_mgcv_model)

      # Ensure the last three values are used, in case the obs_data
      # was not supplied in order
      data.frame(time = object$obs_data$time,
                 series = object$obs_data$series,
                 row_id = 1:length(object$obs_data$time)) %>%
        dplyr::arrange(time, series) %>%
        dplyr::pull(row_id) -> sorted_inds

      linpred_order <- vector(length = 3 * n_series)
      last_rows <- tail(sort(sorted_inds), 3 * n_series)
      for(i in seq_along(last_rows)){
        linpred_order[i] <- which(sorted_inds == last_rows[i])
      }

      # Deal with any offsets
      if(!all(attr(Xp_trend_last, 'model.offset') == 0)){
        offset_vec <- attr(Xp_trend_last, 'model.offset')
        offset_last <- offset_vec[linpred_order]
        offset_last[is.na(offset_last)] <- 0
        full_offset <- c(offset_last, attr(Xp_trend, 'model.offset'))
      } else {
        full_offset <- 0
      }

      # Bind the last 3 linpred rows with the forecast linpred rows
      Xp_trend <- rbind(Xp_trend_last[linpred_order, ],
                        Xp_trend)
      attr(Xp_trend, 'model.offset') <- full_offset
    }

  } else {
    Xp_trend <- NULL
  }

  # No need to compute in parallel if there was no trend model
  if(attr(object$model_data, 'trend_model') == 'None'){
    if(type == 'trend'){
      stop('No trend_model was used in this model',
           call. = FALSE)
    }

    if(series != 'all'){
      fc_preds <- predict(object, type = type, newdata = series_test)
    } else {
      all_preds <- predict(object, type = type, newdata = data_test)
      fc_preds <- lapply(seq_len(NROW(all_preds)), function(draw){
        lapply(seq_len(n_series), function(series){
          all_preds[draw, which(data_test$series == levels(data_test$series)[series])]
        })
      })
    }

  } else {
  # Else compute forecasts including dynamic trend components

  # Set forecast horizon
  if(series != 'all'){
    fc_horizon <- NROW(series_test)
  } else {
    fc_horizon <- length(unique(data_test$time))
  }

  # Beta coefficients for GAM observation component
  betas <- mcmc_chains(object$model_output, 'b')

  # Generate sample sequence for n_samples
  if(missing(n_samples)){
    sample_seq <- 1:dim(betas)[1]
  } else {
    if(n_samples < dim(betas)[1]){
      sample_seq <- sample(seq_len(dim(betas)[1]),
                           size = n_samples, replace = FALSE)
    } else {
      sample_seq <- sample(seq_len(dim(betas)[1]),
                           size = n_samples, replace = TRUE)
    }
  }

  # Beta coefficients for GAM trend component
  if(!is.null(object$trend_call)){
    betas_trend <- mcmc_chains(object$model_output, 'b_trend')
  } else {
    betas_trend <- NULL
  }

  # Family of model
  family <- object$family

  # Family-specific parameters
  family_pars <- extract_family_pars(object = object)

  # Trend model
  trend_model <- attr(object$model_data, 'trend_model')

  # Trend-specific parameters
  if(missing(ending_time)){
    trend_pars <- extract_trend_pars(object = object,
                                     keep_all_estimates = FALSE)
  } else {
    trend_pars <- extract_trend_pars(object = object,
                                     keep_all_estimates = FALSE,
                                     ending_time = ending_time)
  }

  # Any model in which a an autoregressive process was included should be
  # considered as VAR1 for forecasting purposes as this will make use of the
  # faster c++ functions
  if('Sigma' %in% names(trend_pars) |
     'sigma' %in% names(trend_pars) |
     'tau' %in% names(trend_pars)){
    trend_model <- 'VAR1'
    if(!'last_lvs' %in% names(trend_pars)){
      trend_pars$last_lvs <- trend_pars$last_trends
    }
  }

  # Set up parallel environment for looping across posterior draws
  # to compute h-step ahead forecasts
  cl <- parallel::makePSOCKcluster(n_cores)
  parallel::setDefaultCluster(cl)
  parallel::clusterExport(NULL, c('family',
                                  'family_pars',
                                  'trend_model',
                                  'trend_pars',
                                  'type',
                                  'use_lv',
                                  'betas',
                                  'betas_trend',
                                  'n_series',
                                  'data_test',
                                  'series',
                                  'series_test',
                                  'Xp',
                                  'Xp_trend',
                                  'fc_horizon'),
                          envir = environment())
  parallel::clusterExport(cl = cl,
                          unclass(lsf.str(envir = asNamespace("mvgam"),
                                          all = T)),
                          envir = as.environment(asNamespace("mvgam")))

  pbapply::pboptions(type = "none")

  fc_preds <- pbapply::pblapply(seq_len(dim(betas)[1]), function(i){
    # Sample index
    samp_index <- i

    # Sample beta coefs
    betas <- betas[samp_index, ]

    if(!is.null(betas_trend)){
      betas_trend <- betas_trend[samp_index, ]
    }

    # Return predictions
    if(series == 'all'){

      # Sample general trend-specific parameters
      general_trend_pars <- extract_general_trend_pars(trend_pars = trend_pars,
                                                       samp_index = samp_index)

      if(use_lv || trend_model == 'VAR1'){
        # Propagate all trends / lvs forward jointly using sampled trend parameters
        trends <- forecast_trend(trend_model = trend_model,
                                 use_lv = use_lv,
                                 trend_pars = general_trend_pars,
                                 h = fc_horizon,
                                 betas_trend = betas_trend,
                                 Xp_trend = Xp_trend,
                                 time = sort(unique(data_test$time)))
      }

      # Loop across series and produce the next trend estimate
      trend_states <- lapply(seq_len(n_series), function(series){

        # Sample series- and trend-specific parameters
        trend_extracts <- extract_series_trend_pars(series = series,
                                                    samp_index = samp_index,
                                                    trend_pars = trend_pars,
                                                    use_lv = use_lv)

        if(use_lv || trend_model == 'VAR1'){
          if(use_lv){
            # Multiply lv states with loadings to generate the series' forecast trend state
            out <- as.numeric(trends %*% trend_extracts$lv_coefs)
          } else if(trend_model == 'VAR1'){
            out <- trends[,series]
          }

        } else {
          # Propagate the series-specific trends forward
          out <- forecast_trend(trend_model = trend_model,
                                use_lv = FALSE,
                                trend_pars = trend_extracts,
                                h = fc_horizon,
                                betas_trend = betas_trend,
                                Xp_trend = Xp_trend,
                                time = sort(unique(data_test$time)))
        }
        out
      })

      if(type == 'trend'){
        out <- trend_states
      } else {
        trend_states <- do.call(cbind, trend_states)
        out <- lapply(seq_len(n_series), function(series){

          Xpmat <- cbind(Xp[which(as.numeric(data_test$series) == series),],
                         trend_states[, series])
          if(!is.null(attr(Xp, 'model.offset'))){
            attr(Xpmat, 'model.offset') <-
              attr(Xp, 'model.offset')[which(as.numeric(data_test$series) == series)]

            attr(Xpmat, 'model.offset')[is.na(attr(Xpmat, 'model.offset'))] <- 0
          }

          # Family-specific parameters
          family_extracts <- lapply(seq_along(family_pars), function(x){
            if(is.matrix(family_pars[[x]])){
              family_pars[[x]][samp_index, series]
            } else {
              family_pars[[x]][samp_index]
            }
          })
          names(family_extracts) <- names(family_pars)

          mvgam_predict(family = family,
                        Xp = Xpmat,
                        type = type,
                        betas = c(betas, 1),
                        family_pars = family_extracts)
        })
      }

    } else {

      # Sample series- and trend-specific parameters
      trend_extracts <- extract_series_trend_pars(series = series,
                                                  samp_index = samp_index,
                                                  trend_pars = trend_pars,
                                                  use_lv = use_lv)

      # Propagate the series' trend forward using the sampled trend parameters
      trends <- forecast_trend(trend_model = trend_model,
                               use_lv = use_lv,
                               trend_pars = trend_extracts,
                               h = fc_horizon,
                               betas_trend = betas_trend,
                               Xp_trend = Xp_trend,
                               time = sort(unique(series_test$time)))

      if(use_lv){
        # Multiply lv states with loadings to generate the series' forecast trend state
        trends <- as.numeric(trends %*% trend_extracts$lv_coefs)
      } else if(trend_model == 'VAR1'){
        trends <- trends[, series]
      }

      if(type == 'trend'){
        out <- trends
      } else {

        # Sample the series' family-specific parameters
        family_extracts <- lapply(seq_along(family_pars), function(x){
          if(is.matrix(family_pars[[x]])){
            family_pars[[x]][samp_index, series]
          } else {
            family_pars[[x]][samp_index]
          }
        })
        names(family_extracts) <- names(family_pars)

        # Generate predictions
        Xpmat <- cbind(Xp, trends)
        attr(Xpmat, 'model.offset') <- attr(Xp, 'model.offset')
        out <- mvgam_predict(family = family,
                             Xp = Xpmat,
                             type = type,
                             betas = c(betas, 1),
                             family_pars = family_extracts)
      }
    }

    out
  }, cl = cl)
   stopCluster(cl)
 }

  return(fc_preds)
}
