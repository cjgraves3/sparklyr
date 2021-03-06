# nocov start

spark_worker_context <- function(sc) {
  hostContextId <- worker_invoke_method(sc, FALSE, "Handler", "getHostContext")
  worker_log("retrieved worker context id ", hostContextId)

  context <- structure(
    class = c("spark_jobj", "shell_jobj"),
    list(
      id = hostContextId,
      connection = sc
    )
  )

  worker_log("retrieved worker context")

  context
}

spark_worker_init_packages <- function(sc, context) {
  bundlePath <- worker_invoke(context, "getBundlePath")

  if (nchar(bundlePath) > 0) {
    bundleName <- basename(bundlePath)
    worker_log("using bundle name ", bundleName)

    workerRootDir <- worker_invoke_static(sc, "org.apache.spark.SparkFiles", "getRootDirectory")
    sparkBundlePath <- file.path(workerRootDir, bundleName)

    worker_log("using bundle path ", normalizePath(sparkBundlePath))

    if (!file.exists(sparkBundlePath)) {
      stop("failed to find bundle under SparkFiles root directory")
    }

    unbundlePath <- worker_spark_apply_unbundle(
      sparkBundlePath,
      workerRootDir,
      tools::file_path_sans_ext(bundleName)
    )

    .libPaths(unbundlePath)
    worker_log("updated .libPaths with bundle packages")
  }
  else {
    spark_env <- worker_invoke_static(sc, "org.apache.spark.SparkEnv", "get")
    spark_libpaths <- worker_invoke(worker_invoke(spark_env, "conf"), "get", "spark.r.libpaths", NULL)
    if (!is.null(spark_libpaths)) .libPaths(spark_libpaths)
  }
}

spark_worker_execute_closure <- function(closure, df, funcContext, grouped_by) {
  if (nrow(df) == 0) {
    worker_log("found that source has no rows to be proceesed")
    return(NULL)
  }

  closure_params <- length(formals(closure))
  closure_args <- c(
    list(df),
    if (!is.null(funcContext$user_context)) list(funcContext$user_context) else NULL,
    lapply(grouped_by, function(group_by_name) df[[group_by_name]][[1]])
  )[0:closure_params]

  worker_log("computing closure")
  result <- do.call(closure, closure_args)
  worker_log("computed closure")

  as_factors <- getOption("stringsAsFactors")
  on.exit(options(stringsAsFactors = as_factors))
  options(stringsAsFactors = F)

  if (!"data.frame" %in% class(result)) {
    worker_log("data.frame expected but ", class(result), " found")

    result <- as.data.frame(result)
  }

  if (!is.data.frame(result)) stop("Result from closure is not a data.frame")

  result
}

spark_worker_clean_factors <- function(result) {
  if (any(sapply(result, is.factor))) {
    result <- as.data.frame(lapply(result, function(x) if(is.factor(x)) as.character(x) else x), stringsAsFactors = F)
  }

  result
}

spark_worker_apply_maybe_schema <- function(result, config) {
  firstClass <- function(e) class(e)[[1]]

  if (identical(config$schema, TRUE)) {
    worker_log("updating schema")
    result <- data.frame(
      names = paste(names(result), collapse = "|"),
      types = paste(lapply(result, firstClass), collapse = "|"),
      stringsAsFactors = F
    )
  }

  result
}

spark_worker_build_types <- function(context, columns) {
  names <- names(columns)
  sqlutils <- worker_invoke(context, "getSqlUtils")
  fields <- lapply(names, function(name) {
    worker_invoke(sqlutils, "createStructField", name, columns[[name]][[1]], TRUE)
  })

  worker_invoke(sqlutils, "createStructType", fields)
}

spark_worker_get_group_batch <- function(batch) {
  worker_invoke(
    batch, "get", 0L
  )
}

spark_worker_add_group_by_column <- function(df, result, grouped, grouped_by) {
  if (grouped) {
    if (nrow(result) > 0) {
      new_column_values <- lapply(grouped_by, function(grouped_by_name) df[[grouped_by_name]][[1]])
      names(new_column_values) <- grouped_by

      if("AsIs" %in% class(result)) class(result) <- class(result)[-match("AsIs", class(result))]
      result <- do.call("cbind", list(new_column_values, result))

      names(result) <- gsub("\\.", "_", make.unique(names(result)))
    }
    else {
      result <- NULL
    }
  }

  result
}

spark_worker_apply_arrow <- function(sc, config) {
  worker_log("using arrow serializer")

  context <- spark_worker_context(sc)
  spark_worker_init_packages(sc, context)

  closure <- unserialize(worker_invoke(context, "getClosure"))
  funcContext <- unserialize(worker_invoke(context, "getContext"))
  grouped_by <- worker_invoke(context, "getGroupBy")
  grouped <- !is.null(grouped_by) && length(grouped_by) > 0
  columnNames <- worker_invoke(context, "getColumns")
  schema_input <- worker_invoke(context, "getSchema")
  time_zone <- worker_invoke(context, "getTimeZoneId")
  options_map <- worker_invoke(context, "getOptions")

  if (grouped) {
    record_batch_raw_groups <- worker_invoke(context, "getSourceArray")
    record_batch_raw_groups_idx <- 1
    record_batch_raw <- spark_worker_get_group_batch(record_batch_raw_groups[[record_batch_raw_groups_idx]])
  } else {
    row_iterator <- worker_invoke(context, "getIterator")
    arrow_converter_impl <- worker_invoke(context, "getArrowConvertersImpl")
    record_batch_raw <- worker_invoke(
      arrow_converter_impl,
      "toBatchArray",
      row_iterator,
      schema_input,
      time_zone,
      as.integer(options_map[["maxRecordsPerBatch"]])
    )
  }

  reader <- arrow_record_stream_reader(record_batch_raw)
  record_entry <- arrow_read_record_batch(reader)

  all_batches <- list()
  total_rows <- 0

  schema_output <- NULL

  batch_idx <- 0
  while (!is.null(record_entry)) {
    batch_idx <- batch_idx + 1
    worker_log("is processing batch ", batch_idx)

    df <- arrow_as_tibble(record_entry)
    result <- NULL

    if (!is.null(df)) {
      colnames(df) <- columnNames[1: length(colnames(df))]

      result <- spark_worker_execute_closure(closure, df, funcContext, grouped_by)

      result <- spark_worker_add_group_by_column(df, result, grouped, grouped_by)

      result <- spark_worker_clean_factors(result)

      result <- spark_worker_apply_maybe_schema(result, config)
    }

    if (!is.null(result)) {
      if (is.null(schema_output)) {
        schema_output <- spark_worker_build_types(context, lapply(result, class))
      }

      raw_batch <- arrow_write_record_batch(result)

      all_batches[[length(all_batches) + 1]] <- raw_batch
      total_rows <- total_rows + nrow(result)
    }

    record_entry <- arrow_read_record_batch(reader)

    if (grouped && is.null(record_entry) && record_batch_raw_groups_idx < length(record_batch_raw_groups)) {
      record_batch_raw_groups_idx <- record_batch_raw_groups_idx + 1
      record_batch_raw <- spark_worker_get_group_batch(record_batch_raw_groups[[record_batch_raw_groups_idx]])

      reader <- arrow_record_stream_reader(record_batch_raw)
      record_entry <- arrow_read_record_batch(reader)
    }
  }

  if (length(all_batches) > 0) {
    worker_log("updating ", total_rows, " rows using ", length(all_batches), " row batches")

    arrow_converter <- worker_invoke(context, "getArrowConverters")
    row_iter <- worker_invoke(arrow_converter, "fromPayloadArray", all_batches, schema_output)

    worker_invoke(context, "setResultIter", row_iter)
    worker_log("updated ", total_rows, " rows using ", length(all_batches), " row batches")
  } else {
    worker_log("found no rows in closure result")
  }

  worker_log("finished apply")
}

spark_worker_apply <- function(sc, config) {
  context <- spark_worker_context(sc)
  spark_worker_init_packages(sc, context)

  grouped_by <- worker_invoke(context, "getGroupBy")
  grouped <- !is.null(grouped_by) && length(grouped_by) > 0
  if (grouped) worker_log("working over grouped data")

  length <- worker_invoke(context, "getSourceArrayLength")
  worker_log("found ", length, " rows")

  groups <- worker_invoke(context, if (grouped) "getSourceArrayGroupedSeq" else "getSourceArraySeq")
  worker_log("retrieved ", length(groups), " rows")

  closureRaw <- worker_invoke(context, "getClosure")
  closure <- unserialize(closureRaw)

  funcContextRaw <- worker_invoke(context, "getContext")
  funcContext <- unserialize(funcContextRaw)

  closureRLangRaw <- worker_invoke(context, "getClosureRLang")
  if (length(closureRLangRaw) > 0) {
    worker_log("found rlang closure")
    closureRLang <- spark_worker_rlang_unserialize()
    if (!is.null(closureRLang)) {
      closure <- closureRLang(closureRLangRaw)
      worker_log("created rlang closure")
    }
  }

  if (identical(config$schema, TRUE)) {
    worker_log("is running to compute schema")
  }

  columnNames <- worker_invoke(context, "getColumns")

  if (!grouped) groups <- list(list(groups))

  all_results <- NULL

  for (group_entry in groups) {
    # serialized groups are wrapped over single lists
    data <- group_entry[[1]]

    df <- do.call(rbind.data.frame, c(data, list(stringsAsFactors = FALSE)))

    # rbind removes Date classes so we re-assign them here
    if (length(data) > 0 && ncol(df) > 0 && nrow(df) > 0) {

      if (any(sapply(data[[1]], function(e) class(e)[[1]]) %in% c("Date", "POSIXct"))) {
        first_row <- data[[1]]
        for (idx in seq_along(first_row)) {
          first_class <- class(first_row[[idx]])[[1]]
          if (identical(first_class, "Date")) {
            df[[idx]] <- as.Date(df[[idx]], origin = "1970-01-01")
          } else if (identical(first_class, "POSIXct")) {
            df[[idx]] <- as.POSIXct(df[[idx]], origin = "1970-01-01")
          }
        }
      }

      # cast column to correct type, for instance, when dealing with NAs.
      for (i in 1:ncol(df)) {
        target_type <- funcContext$column_types[[i]]
        if (!is.null(target_type) && class(df[[i]]) != target_type) {
        df[[i]] <- do.call(paste("as", target_type, sep = "."), args = list(df[[i]]))
        }
      }
    }

    colnames(df) <- columnNames[1: length(colnames(df))]

    result <- spark_worker_execute_closure(closure, df, funcContext, grouped_by)

    result <- spark_worker_add_group_by_column(df, result, grouped, grouped_by)

    result <- spark_worker_clean_factors(result)

    result <- spark_worker_apply_maybe_schema(result, config)

    all_results <- rbind(all_results, result)
  }

  if (!is.null(all_results) && nrow(all_results) > 0) {
    worker_log("updating ", nrow(all_results), " rows")

    all_data <- lapply(1:nrow(all_results), function(i) as.list(all_results[i,]))

    worker_invoke(context, "setResultArraySeq", all_data)
    worker_log("updated ", nrow(all_results), " rows")
  } else {
    worker_log("found no rows in closure result")
  }

  worker_log("finished apply")
}

spark_worker_rlang_unserialize <- function() {
  rlang_unserialize <- core_get_package_function("rlang", "bytes_unserialise")
  if (is.null(rlang_unserialize))
    core_get_package_function("rlanglabs", "bytes_unserialise")
  else
    rlang_unserialize
}

spark_worker_unbundle_path <- function() {
  file.path("sparklyr-bundle")
}

#' Extracts a bundle of dependencies required by \code{spark_apply()}
#'
#' @param bundle_path Path to the bundle created using \code{spark_apply_bundle()}
#' @param base_path Base path to use while extracting bundles
#'
#' @keywords internal
#' @export
worker_spark_apply_unbundle <- function(bundle_path, base_path, bundle_name) {
  extractPath <- file.path(base_path, spark_worker_unbundle_path(), bundle_name)
  lockFile <- file.path(extractPath, "sparklyr.lock")

  if (!dir.exists(extractPath)) dir.create(extractPath, recursive = TRUE)

  if (length(dir(extractPath)) == 0) {
    worker_log("found that the unbundle path is empty, extracting:", extractPath)

    writeLines("", lockFile)
    system2("tar", c("-xf", bundle_path, "-C", extractPath))
    unlink(lockFile)
  }

  if (file.exists(lockFile)) {
    worker_log("found that lock file exists, waiting")
    while (file.exists(lockFile)) {
      Sys.sleep(1)
    }
    worker_log("completed lock file wait")
  }

  extractPath
}

# nocov end
