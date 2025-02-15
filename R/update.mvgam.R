#'Update an existing `mvgam` object
#'
#'This function allows a previously fitted `mvgam` model to be updated
#'@name update.mvgam
#'@importFrom mgcv nb betar
#'@importFrom rlang missing_arg
#'@inheritParams mvgam
#'@param object \code{list} object returned from \code{mvgam}. See [mvgam()]
#'@param formula Optional new `formula` object. Note, `mvgam` currently does not support dynamic formula
#'updates such as removal of specific terms with `- term`. When updating, the entire formula needs
#'to be supplied
#'@param ... Other arguments to be passed to \code{\link{mvgam}}
#' @examples
#' \dontrun{
#' # Simulate some data and fit a Poisson AR1 model
#' simdat <- sim_mvgam(n_series = 1, trend_model = 'AR1')
#' mod <- mvgam(y ~ s(season, bs = 'cc'),
#'             trend_model = 'AR1',
#'             data = simdat$data_train)
#' summary(mod)
#'
#' # Update to an AR2 model
#' updated_mod <- update(mod, trend_model = 'AR2')
#' summary(updated_mod)
#'
#' # Now update to a Negative Binomial AR1
#' updated_mod <- update(mod, family = nb())
#' summary(updated_mod)
#'}
#'@export
update.mvgam = function(object, formula,
                        trend_formula,
                        data, newdata,
                        trend_model,
                        trend_map,
                        use_lv, n_lv,
                        family, priors,
                        lfo = FALSE,
                        ...){

  if(missing(formula)){
    formula <- object$call
  }

  if(missing(trend_formula)){
    if(is.null(object$trend_call)){
      trend_formula <- missing_arg()
    } else {
      trend_formula <- object$trend_call
    }
  }

  if(missing(trend_map)){
    if(is.null(object$trend_map)){
      trend_map <- missing_arg()
    } else {
      trend_map <- object$trend_map
    }
  }

  if(missing(data)){
    data_train <- object$obs_data
  } else {
    data_train <- data
  }

  if(missing(priors)){
    if(!is.null(object$priors)){
      priors <- object$priors
    } else {
      priors <- rlang::missing_arg()
    }
  }

  if(!missing(newdata)){
    # If new  testing data supplied, include as the test data
    data_test <- newdata
    include_fc <- TRUE
  } else if(!is.null(object$test_data)){
    # only include test data when no new training data is supplied
    if(missing(data)){
      include_fc <- TRUE
      data_test <- object$test_data
    } else {
      include_fc <- FALSE
    }
  } else {
    include_fc <- FALSE
  }

  if(missing(trend_model)){
    trend_model <- object$trend_model
  }

  if(missing(use_lv)){
    use_lv <- object$use_lv
  }

  if(missing(n_lv)){
    n_lv <- object$n_lv
  }

  if(missing(n_lv)){
    n_lv <- object$n_lv
  }

  if(missing(family)){
    family_char <- object$family
    family <- family_char
    if(family_char == 'negative binomial'){
      family <- nb()
    }
    if(family_char == 'beta'){
      family <- betar()
    }
    if(family_char == 'student'){
      family <- student_t()
    }
  }

  if(include_fc){
    updated_mod <- mvgam(formula = formula,
                         trend_formula = trend_formula,
                         trend_map = trend_map,
                         data = data_train,
                         newdata = data_test,
                         trend_model = trend_model,
                         use_lv = use_lv,
                         n_lv = n_lv,
                         family = family,
                         refit = TRUE,
                         lfo = lfo,
                         use_stan = ifelse(object$fit_engine == 'stan', TRUE,
                                           FALSE),
                         priors = priors,
                         ...)
  } else {
    updated_mod <- mvgam(formula = formula,
                         trend_formula = trend_formula,
                         trend_map = trend_map,
                         data = data_train,
                         trend_model = trend_model,
                         use_lv = use_lv,
                         n_lv = n_lv,
                         family = family,
                         refit = TRUE,
                         lfo = lfo,
                         use_stan = ifelse(object$fit_engine == 'stan', TRUE,
                                           FALSE),
                         priors = priors,
                         ...)
  }

  return(updated_mod)

}
