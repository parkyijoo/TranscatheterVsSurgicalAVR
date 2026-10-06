# =============================================================================
# UdiDiResolution.R - what the UDI-DI layer resolves for TAVR, and what it buys
# =============================================================================
#
# Requires: DatabaseConnector, SqlRender, dplyr. `survival` is optional and is
# used only for the one-year Kaplan-Meier estimate.
# =============================================================================


# ---------------------------------------------------------------------------
# Configuration - edit this block, then source the file
# ---------------------------------------------------------------------------
# .libPaths("")

connectionDetails <- DatabaseConnector::createConnectionDetails(dbms = "pdw",
                                                                server = Sys.getenv("PDW_SERVER"),
                                                                user = NULL,
                                                                password = NULL,
                                                                port = Sys.getenv("PDW_PORT"))

cdmDatabaseSchema <- "CDM_IBM_MDCD_V1153.dbo"
cohortDatabaseSchema <- "scratch.dbo"
cohortTable <- "mschuemi_skeleton"
databaseId <- "Synpuf"

# Where to write the CSVs.
outputFolder <- "s:/TavrSavr"
udiFolder    <- file.path(outputFolder, "udiDi")

# Cohorts. 874 is TAVR without a prior-observation requirement, the cohort the
# thesis reports; 783 is the same protocol with 365 days of prior observation.
tavrCohortId <- 874
ppiCohortId  <- 862          # Secondary_New_PPI

# The standard device concept every TAVR valve maps to.
valveConceptId <- 3661561

# Risk window, matching analysis 102/112 of the main study: day 1 to day 3,285.
riskWindowStart <- 1
riskWindowEnd   <- 3285

# Counts below this are suppressed in everything written to disk.
MIN_CELL_COUNT <- 0


# ---------------------------------------------------------------------------
# UDI-DI reference table
# ---------------------------------------------------------------------------

udiReference <- data.frame(
  reimbursementCode = c(rep("G2201003", 11), rep("G2201002", 8)),
  manufacturer = c(rep("Medtronic", 11), rep("Edwards", 8)),
  generation = c(rep("Evolut R", 4), rep("Evolut Pro", 3), rep("Evolut Pro+", 4),
                 rep("SAPIEN 3", 4), rep("SAPIEN 3 Ultra", 4)),
  sizeMm = c(23, 26, 29, 34,
             23, 26, 29,
             23, 26, 29, 34,
             20, 23, 26, 29,
             20, 23, 26, 29),
  udiDi = c("763000017699", "763000017705", "763000017712", "643169792364",
            "763000017842", "763000017859", "763000017866",
            "763000211042", "763000211059", "763000211066", "763000211134",
            "690103211634", "690103211641", "690103211658", "690103211665",
            "690103208085", "690103208092", "690103208108", "7612989037521"),
  modelName = c("EVOLUTR-23", "EVOLUTR-26", "EVOLUTR-29", "EVOLUTR-34",
                "EVOLUTPRO-23", "EVOLUTPRO-26", "EVOLUTPRO-29",
                "EVPROPLUS-23", "EVPROPLUS-26", "EVPROPLUS-29", "EVPROPLUS-34",
                "S3TF320", "S3TF323", "S3TF326", "S3TF329",
                "S3UCM220", "S3UCM223", "S3UCM226", "S3UCM229"),
  stringsAsFactors = FALSE
)
stopifnot(nrow(udiReference) == 19, !any(duplicated(udiReference$udiDi)))


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
suppressPackageStartupMessages({
  library(DatabaseConnector)
  library(SqlRender)
  library(dplyr)
})

if (!dir.exists(udiFolder)) dir.create(udiFolder, recursive = TRUE)

#' Suppress small counts, the way exportResults() does.
censor <- function(x) ifelse(!is.na(x) & x > 0 & x < MIN_CELL_COUNT, -MIN_CELL_COUNT, x)

#' Censor every integer count column of a data frame before it is written.
writeCensored <- function(df, fileName, countColumns) {
  for (cc in intersect(countColumns, names(df))) df[[cc]] <- censor(df[[cc]])
  # A rate computed from a suppressed count would leak it back.
  for (rc in intersect(c("ratePer100Py", "risk1y", "km1y"), names(df))) {
    for (cc in intersect(countColumns, names(df))) {
      df[[rc]][!is.na(df[[cc]]) & df[[cc]] < 0] <- NA
    }
  }
  df$databaseId <- databaseId
  path <- file.path(udiFolder, fileName)
  write.csv(df, path, row.names = FALSE, na = "")
  message("  written: ", path)
  invisible(df)
}

#' Reduce a raw unique_device_id to digits only.

normalizeUdi <- function(x) {
  x <- as.character(x)
  x[is.na(x)] <- ""
  gsub("[^0-9]", "", x)
}

gtinCore <- function(x) sub("^0+", "", normalizeUdi(x))

matchUdiDi <- function(raw, reference = udiReference$udiDi,
                       cores = gtinCore(reference)) {
  norm <- gtinCore(raw)
  hits <- lapply(norm, function(n) {
    if (nchar(n) == 0) return(character(0))
    reference[vapply(cores, function(core) grepl(core, n, fixed = TRUE),
                     logical(1), USE.NAMES = FALSE)]
  })
  nHit <- lengths(hits)
  out <- rep(NA_character_, length(raw))
  out[nHit == 1] <- unlist(hits[nHit == 1])
  attr(out, "ambiguous") <- nHit > 1
  out
}

# The cores have to stay distinct and long enough that a substring match cannot
# be coincidental; a truncated entry in the table above would break both.
stopifnot(!any(duplicated(gtinCore(udiReference$udiDi))),
          all(nchar(gtinCore(udiReference$udiDi)) >= 12))


# ---------------------------------------------------------------------------
# Query: one row per TAVR patient, with the device implanted at index
# ---------------------------------------------------------------------------
# The TAVR cohort enters on a DEVICE_EXPOSURE of the valve concept, so the index
# device is the exposure of that concept on the cohort start date. A patient with
# more than one such record on that date is kept as several rows and resolved
# below.
sql <- "
WITH idx AS (
  SELECT subject_id, cohort_start_date
  FROM @cohort_database_schema.@cohort_table
  WHERE cohort_definition_id = @tavr_cohort_id
),
ppi AS (
  SELECT i.subject_id,
         MIN(o.cohort_start_date) AS ppi_date
  FROM @cohort_database_schema.@cohort_table o
  INNER JOIN idx i ON i.subject_id = o.subject_id
  WHERE o.cohort_definition_id = @ppi_cohort_id
    AND o.cohort_start_date > i.cohort_start_date
  GROUP BY i.subject_id
),
prior_ppi AS (
  SELECT DISTINCT i.subject_id
  FROM @cohort_database_schema.@cohort_table o
  INNER JOIN idx i ON i.subject_id = o.subject_id
  WHERE o.cohort_definition_id = @ppi_cohort_id
    AND o.cohort_start_date <= i.cohort_start_date
)
SELECT i.subject_id,
       i.cohort_start_date,
       de.device_concept_id,
       de.unique_device_id,
       de.device_source_value,
       op.observation_period_end_date,
       p.ppi_date,
       CASE WHEN pp.subject_id IS NULL THEN 0 ELSE 1 END AS prior_ppi
FROM idx i
INNER JOIN @cdm_database_schema.device_exposure de
        ON de.person_id = i.subject_id
       AND de.device_exposure_start_date = i.cohort_start_date
       AND de.device_concept_id = @valve_concept_id
INNER JOIN @cdm_database_schema.observation_period op
        ON op.person_id = i.subject_id
       AND i.cohort_start_date >= op.observation_period_start_date
       AND i.cohort_start_date <= op.observation_period_end_date
LEFT JOIN ppi p ON p.subject_id = i.subject_id
LEFT JOIN prior_ppi pp ON pp.subject_id = i.subject_id
;"

message("Connecting to ", connectionDetails$server)
conn <- DatabaseConnector::connect(connectionDetails)
on.exit(DatabaseConnector::disconnect(conn), add = TRUE)

renderedSql <- SqlRender::render(
  sql,
  cohort_database_schema = cohortDatabaseSchema,
  cohort_table = cohortTable,
  cdm_database_schema = cdmDatabaseSchema,
  tavr_cohort_id = tavrCohortId,
  ppi_cohort_id = ppiCohortId,
  valve_concept_id = valveConceptId
)
renderedSql <- SqlRender::translate(renderedSql, targetDialect = connectionDetails$dbms)

message("Querying index device exposures ...")
raw <- DatabaseConnector::querySql(conn, renderedSql)
names(raw) <- tolower(names(raw))
message("  rows returned: ", nrow(raw),
        "  (distinct patients: ", length(unique(raw$subject_id)), ")")


# ---------------------------------------------------------------------------
# Resolve each row to a product
# ---------------------------------------------------------------------------
matchResult <- matchUdiDi(raw$unique_device_id)
ambiguous <- attr(matchResult, "ambiguous")
raw$matchedDi <- as.character(matchResult)

person <- raw %>%
  group_by(.data$subject_id) %>%
  summarise(
    cohortStartDate = min(.data$cohort_start_date),
    opEndDate = max(.data$observation_period_end_date),
    ppiDate = if (all(is.na(ppi_date))) as.Date(NA) else min(ppi_date, na.rm = TRUE),
    priorPpi = max(prior_ppi),
    nDeviceRows = dplyr::n(),
    nDistinctDi = dplyr::n_distinct(matchedDi[!is.na(matchedDi)]),
    hasUdiField = any(nchar(normalizeUdi(unique_device_id)) > 0),
    matchedDi = if (any(!is.na(matchedDi))) matchedDi[!is.na(matchedDi)][1]
                else NA_character_,
    .groups = "drop"
  )

# A patient with two different valves recorded on the index date cannot be
# assigned to one product; counted and then dropped from B and C.
nMultiProduct <- sum(person$nDistinctDi > 1, na.rm = TRUE)

person <- person %>%
  left_join(udiReference, by = c("matchedDi" = "udiDi"))


# ---------------------------------------------------------------------------
# A1. Coverage of the UDI-DI layer
# ---------------------------------------------------------------------------
coverage <- data.frame(
  step = c("Patients in the TAVR cohort",
           "With an index device exposure of the valve concept",
           "With unique_device_id populated",
           "unique_device_id maps to a reference UDI-DI",
           "Ambiguous (matched more than one reference UDI-DI)",
           "More than one distinct product on the index date"),
  n = c(length(unique(raw$subject_id)),
        nrow(person),
        sum(person$hasUdiField),
        sum(!is.na(person$matchedDi)),
        sum(ambiguous, na.rm = TRUE),
        nMultiProduct),
  stringsAsFactors = FALSE
)
coverage$pct <- round(100 * coverage$n / coverage$n[1], 1)
writeCensored(coverage, "tab_udi_coverage.csv", "n")
print(coverage)

# The raw values that did not map, so the reference table can be completed.
unmapped <- raw %>%
  filter(is.na(.data$matchedDi)) %>%
  count(.data$unique_device_id, .data$device_source_value, name = "nRows") %>%
  arrange(dplyr::desc(.data$nRows))
if (nrow(unmapped) > 0) {
  message("  ", nrow(unmapped), " distinct unique_device_id values did not map. ",
          "See tab_udi_unmapped.csv - the reference table above probably needs ",
          "the older-generation products, which it does not yet carry.")
  writeCensored(unmapped, "tab_udi_unmapped.csv", "nRows")
}


# ---------------------------------------------------------------------------
# A2. Resolution ladder - the headline table
# ---------------------------------------------------------------------------
mapped <- person %>% filter(!is.na(.data$matchedDi), .data$nDistinctDi == 1)

ladder <- data.frame(
  layer = c("Standard concept", "Reimbursement code", "UDI-DI"),
  identifier = c("Aortic valve bioprosthesis (3661561)",
                 "G2201002 / G2201003",
                 "GTIN per model generation and size"),
  distinguishes = c("Transcatheter valve, any product",
                    "Manufacturer",
                    "Model generation and valve size"),
  nUnitsInReference = c(1L, length(unique(udiReference$reimbursementCode)),
                        nrow(udiReference)),
  # Counted from the data for the concept and UDI-DI layers. The reimbursement
  # layer is counted from the products the patients actually received, since
  # device_source_value does not reliably hold the reimbursement code - see
  # tab_udi_source_values.csv.
  nUnitsObserved = c(length(unique(raw$device_concept_id)),
                     length(unique(mapped$reimbursementCode)),
                     length(unique(mapped$matchedDi))),
  nPatients = c(nrow(person), nrow(mapped), nrow(mapped)),
  stringsAsFactors = FALSE
)
writeCensored(ladder, "tab_udi_resolution_ladder.csv",
              c("nUnitsObserved", "nPatients"))
print(ladder)


# ---------------------------------------------------------------------------
# A2b. What does device_source_value actually hold?
# ---------------------------------------------------------------------------
# The cohort definitions match device_source_value against a mixture of the two
# reimbursement codes and site-local item codes, which not every product has.
# This table is the check that the products are nonetheless being captured, and
# it records which identifier the ETL actually stores - which is what another
# site needs to know in order to rewrite the cohorts portably.
sourceValues <- raw %>%
  mutate(mapsToProduct = !is.na(.data$matchedDi)) %>%
  count(.data$device_source_value, .data$mapsToProduct, name = "nRows") %>%
  arrange(dplyr::desc(.data$nRows))
writeCensored(sourceValues, "tab_udi_source_values.csv", "nRows")
print(utils::head(as.data.frame(sourceValues), 30))

# Which reference products no patient was resolved to? A product the cohort
# definition cannot reach is silently missing rather than genuinely unused, so
# this list is the first thing to check at a new site.
missingProducts <- udiReference %>%
  anti_join(mapped, by = c("udiDi" = "matchedDi")) %>%
  select("manufacturer", "generation", "sizeMm", "udiDi")
if (nrow(missingProducts) > 0) {
  message("  ", nrow(missingProducts), " of the 19 reference products have no ",
          "patient in this cohort:")
  print(as.data.frame(missingProducts))
}


# ---------------------------------------------------------------------------
# A3. Patients per product
# ---------------------------------------------------------------------------
products <- mapped %>%
  count(.data$manufacturer, .data$generation, .data$sizeMm, .data$modelName,
        .data$matchedDi, name = "nPatients") %>%
  arrange(.data$manufacturer, .data$generation, .data$sizeMm)
writeCensored(products, "tab_udi_products.csv", "nPatients")
print(as.data.frame(products))


# ---------------------------------------------------------------------------
# B and C. Pacemaker implantation, descriptively
# ---------------------------------------------------------------------------
# Time at risk and the event flag follow analysis 102/112 of the main study:
# the window opens the day after index, so a pacemaker implanted on the day of
# the valve is NOT counted here either. Patients are followed to the end of
# observation or the end of the window, whichever comes first.
mapped <- mapped %>%
  mutate(
    daysToEnd = pmin(as.numeric(.data$opEndDate - .data$cohortStartDate),
                     riskWindowEnd),
    daysToPpi = as.numeric(.data$ppiDate - .data$cohortStartDate),
    event = !is.na(.data$daysToPpi) &
      .data$daysToPpi >= riskWindowStart & .data$daysToPpi <= .data$daysToEnd,
    timeAtRisk = pmin(ifelse(.data$event, .data$daysToPpi, .data$daysToEnd),
                      riskWindowEnd),
    event1y = .data$event & .data$daysToPpi <= 365,
    timeAtRisk1y = pmin(.data$timeAtRisk, 365)
  ) %>%
  filter(.data$timeAtRisk >= riskWindowStart)

#' One descriptive row per group: counts, person-time, crude rate, and the
#' one-year Kaplan-Meier estimate where `survival` is available.
summarisePpi <- function(df, ...) {
  groupNames <- dplyr::group_vars(dplyr::group_by(df, ...))
  grouped <- df %>%
    group_by(...) %>%
    summarise(
      nPatients = dplyr::n(),
      nPriorPpi = sum(priorPpi == 1),
      nEvents = sum(event),
      nEvents1y = sum(event1y),
      personYears = round(sum(timeAtRisk) / 365.25, 1),
      personYears1y = round(sum(timeAtRisk1y) / 365.25, 1),
      medianFollowUpDays = stats::median(timeAtRisk),
      .groups = "drop"
    ) %>%
    mutate(ratePer100Py = round(100 * .data$nEvents / .data$personYears, 1),
           risk1y = round(100 * .data$nEvents1y / .data$nPatients, 1))

  if (requireNamespace("survival", quietly = TRUE)) {
    km <- df %>%
      group_by(...) %>%
      summarise(km1y = {
        tt <- timeAtRisk1y
        ee <- event1y
        if (sum(ee) == 0) {
          0
        } else {
          fit <- survival::survfit(survival::Surv(tt, ee) ~ 1)
          round(100 * (1 - summary(fit, times = 365, extend = TRUE)$surv[1]), 1)
        }
      }, .groups = "drop")
    grouped <- grouped %>% left_join(km, by = groupNames)
  }
  grouped
}

# B. By model generation, within manufacturer.
byGeneration <- summarisePpi(mapped, .data$manufacturer, .data$generation) %>%
  arrange(.data$manufacturer, .data$generation)
writeCensored(byGeneration, "tab_udi_ppi_by_generation.csv",
              c("nPatients", "nPriorPpi", "nEvents", "nEvents1y"))
print(as.data.frame(byGeneration))

# C. By valve size, within manufacturer, and pooled.
bySize <- summarisePpi(mapped, .data$manufacturer, .data$sizeMm) %>%
  arrange(.data$manufacturer, .data$sizeMm)
writeCensored(bySize, "tab_udi_ppi_by_size.csv",
              c("nPatients", "nPriorPpi", "nEvents", "nEvents1y"))
print(as.data.frame(bySize))

bySizePooled <- summarisePpi(mapped, .data$sizeMm) %>% arrange(.data$sizeMm)
writeCensored(bySizePooled, "tab_udi_ppi_by_size_pooled.csv",
              c("nPatients", "nPriorPpi", "nEvents", "nEvents1y"))
print(as.data.frame(bySizePooled))

# Manufacturer level, as the reference point the main analysis already reports
byManufacturer <- summarisePpi(mapped, .data$manufacturer)
writeCensored(byManufacturer, "tab_udi_ppi_by_manufacturer.csv",
              c("nPatients", "nPriorPpi", "nEvents", "nEvents1y"))
print(as.data.frame(byManufacturer))


message("\nDone. CSVs are in: ", udiFolder)
message("These are aggregate and cell-count censored; counts below ",
        MIN_CELL_COUNT, " are written as -", MIN_CELL_COUNT, ".")
message("\nRead the generation and size tables as DESCRIPTIVE only. They are ",
        "unadjusted, the groups are not in equipoise by construction, and with ",
        "roughly 110 pacemaker events in total there is not enough information ",
        "for a comparative estimate.")

