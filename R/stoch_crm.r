#' Stochastic collision risk model for a single species and one turbine scenario
#'
#' Run stochastic collision risk model for a single species and one turbine scenario
#'
#' @details
#' This function is an adaption of code from Masden(2015) used for estimating
#' the collision risk of seabirds in offshore windfarm sites and is a further
#' adaptation from Band(2012).
#'
#' The collision risk model evaluates risk on a month by month basis in order
#' to reflect changing bird abundance within and utilization of the area.
#'
#' Changes in relation to previous top-line function \code{stochasticBand}
#' \itemize{
#'   \item function runs the model for one single scenario (i.e. one species for
#'   one turbine scenario). Advantages include:
#'   \itemize{
#'       \item streamlined infrastructure for easier scenario management
#'       \item easier implementation of parallelisation for multiple scenarios
#'   }
#'   \item results are no longer saved to an external file
#' }
#'
#'
#' @return Estimates of number of collisions per month, for each of the chosen
#'    model options
#'
#' @param model_options numeric vector
#' @param n_turbines integer
#' @param BirdData A data frame. Contains all the parameters for the species
#' @param TurbineData A data frame. Contains all the parameters for the turbines
#' @param CountData A data frame. Contains density data for the wind farm of interest
#' @param FlightData A data frame. Contains flight height data for species
#' @param iter An integer constant > 0. The number of stochastic draws to take
#' @param spp_name A character vector.
#' @param TPower A decimal value. The amount of power generated by the wind farm (MW)
#' @param LargeArrayCorrection A boolean. If TRUE, correct if the wind farm array is very large
#' @param WFWidth A decimal value. The "width" of wind farm used in Large Array Correction (KM)
#' @param Prop_Upwind A decimal value. A value between 0-1 bounded as proportion of flights upwind - default of 0.5.
#' @param Latitude. A decimal value. Latitude in WGS 1984 (decimal degrees)
#' @param TideOff A decimal value. Tidal offset in metres
#' @param windSpeedMean A decimal value. Site specific mean wind speed (m/s)
#' @param windSpeedSD A decimal value. Site specific standard deviation of wind speeds
#' @param windData_rotation A data frame. The table of wind speed versus rotor speed
#' @param windData_pitch A data frame. The table of wind speed versus rotor pitch
#' @param dens_opt A character value. The type of sampling to do for the species density data.
#'
#' @import msm
#' @import dplyr
#' @import tidyr
#' @import pracma
#'
#' @examples
#' stoch_crm(model_options = c(1, 2, 3),
#'   BirdData = Bird_Data[3, ],
#'   TurbineData = Turbine_Data,
#'   CountData = Count_Data[3, ],
#'   iter = 10,
#'   spp_name = c("Black_legged_Kittiwake"),
#'   LargeArrayCorrection = TRUE,
#'   n_turbines = 300,
#'   WFWidth = 4,
#'   Prop_Upwind = 0.5,
#'   Latitude = 56,
#'   TideOff = 2.5,
#'   windSpeedMean = 30,
#'   windSpeedSD = 5.1,
#'   windData_rotation = startUpValues$turbinePars$rotationVsWind_df,
#'   windData_pitch = startUpValues$turbinePars$pitchVsWind_df,
#'   dens_opt = "truncNorm",
#'   fhd_bootstraps = generic_fhd_bootstraps$Black_headed_Gull)
#'
#' @export
stoch_crm <- function(model_options = c(1, 2, 3),
                      BirdData, TurbineData, CountData, #FlightData = Flight_Data,
                      iter = 10,
                      spp_name,
                      LargeArrayCorrection,
                      n_turbines,
                      WFWidth,
                      Prop_Upwind,
                      Latitude,
                      TideOff,
                      windSpeedMean,
                      windSpeedSD,
                      windData_rotation,
                      windData_pitch,
                      fhd_bootstraps = NULL,
                      dens_opt = "truncNorm"
                      #DensityOpt = list(userOption = "truncNorm")
) {


  start.time <- Sys.time()

  # Global variables   ---------------------------------------------------------
  model_months <- month.abb
  n_months <- length(model_months)

  # Chord taper profile based on the blade of a typical 5 MW turbine used for
  # offshore generation. Required for `p_single_collision` function
  chord_profile <- data.frame(
    # radius at bird passage point, as a proportion of rotor radius (R)
    pp_radius = seq(0.05, 1, 0.05),
    # chord width at pp_radius, as a proportion of the maximum chord width
    chord = c(0.73, 0.79, 0.88, 0.96, 1.00, 0.98, 0.92, 0.85, 0.80, 0.75,
              0.70, 0.64, 0.58, 0.52, 0.47,0.41, 0.37, 0.30,0.24,0.00)
  )



  # Initiate objects to harvest results ----------------------------------------
  sampledBirdParams <- list()

  scrm_outputs <- list()
  for(i in model_options){
    scrm_outputs[[paste0("opt", i)]] <-
      data.matrix(
        matrix(data = NA, ncol = n_months, nrow = iter,
               dimnames = list(NULL, model_months))
        )
  }


  # # TODO: section likely to be dropped
  #
  # ## for results summary table
  # resultsSummary = data.frame(matrix(data = 0, ncol = 6,
  #                                    nrow = 3))
  # names(resultsSummary) = c("Option", "Mean", "SD","CV",
  #                           "Median", "IQR")
  #
  # ## for sampled bird parameters
  # sampledBirdParams = data.frame(matrix(data = 0, ncol = 7, nrow = iter))
  # names(sampledBirdParams) = c("AvoidanceBasic", "AvoidanceExtended",
  #                              "WingSpan", "BodyLength", "PCH", "FlightSpeed",
  #                              "NocturnalActivity")
  #
  # for sampled counts
  sampledSpeciesCount = data.frame(matrix(data = 0, ncol = 12, nrow = iter))
  names(sampledSpeciesCount) = month.abb

  # ## for density data
  # densitySummary=data.frame(matrix(data = 0, ncol = 3, nrow = iter))
  #
  #
  # ## results tables - 3 identical
  # tab1 <- data.frame(matrix(data = 0, ncol = 12, nrow = iter))
  # names(tab1) <- monthLabels
  # tab2 <- tab3 <- tab1
  #
  # ## vectors to store PCol and CollInt###
  # sampledPColl <- data.frame(matrix(data = 0, ncol = 1, nrow = iter))
  # names(sampledPColl) <- "PColl"
  #
  # sampledCollInt <- data.frame(matrix(data = 0, ncol = 1, nrow = iter))
  # names(sampledCollInt) <- "CollInt"


  # Prepare inputs  ------------------------------------------------------------
  # TODO: inputs interface needs rework

  ## get daylight hours and night hours per month based on the latitude
  daynight_hrs_month <- DayLength(Latitude)

  ## month labels
  monthLabels <- month.abb

  ## join rotation and pitch data into a single table
  windData <- dplyr::left_join(windData_rotation,windData_pitch,by='windSpeed')
  windThreshold <- windData$windSpeed[min(which(windData$rotationSpeed != 0))]  ##GH change (ROTOR to rotationSpeed)

  ## bird inputs
  species.dat = BirdData

  species.dat$FlightNumeric <- ifelse(species.dat$Flight == 'Flapping', 1, 0) # TODO: check if correct as spreadsheet 3 indicates 1 for gliding...
  Flap_Glide = ifelse (species.dat$Flight == "Flapping", 1, 2/pi)

  if(dens_opt == "truncNorm"){
    species.count = subset(CountData, Species == spp_name)
  }

#   if(dens_opt == "reSamp"){
#     species.count <- fread("data/birdDensityData_samples.csv") %>%
#       dplyr::filter(specLabel == CRSpecies[s])
#   }
#
#   if(dens_opt == "pcntiles"){
#     species.count <- fread("data/birdDensityData_refPoints.csv") %>%
#       dplyr::filter(specLabel == CRSpecies[s])
#   }


  # Generate random draws of parameters  ---------------------------------------
  #
  # TODO: consider reworking densities sampling interface

  ## sample bird attributes

  sampledBirdParams$WingSpan <- sampler_hd(dat = species.dat$WingspanSD,
                                           mode = 'rtnorm',
                                           n = iter,
                                           mean=species.dat$Wingspan,
                                           sd = species.dat$WingspanSD,
                                           lower = 0)

  sampledBirdParams$BodyLength <- sampler_hd(dat = species.dat$Body_LengthSD,
                                             mode = 'rtnorm',
                                             n = iter,
                                             mean=species.dat$Body_Length,
                                             sd = species.dat$Body_LengthSD,
                                             lower = 0)


  sampledBirdParams$FlightSpeed <- sampler_hd(dat = species.dat$Flight_SpeedSD,
                                              mode = 'rtnorm',
                                              n = iter,
                                              mean=species.dat$Flight_Speed,
                                              sd = species.dat$Flight_SpeedSD,
                                              lower = 0)

  sampledBirdParams$PCH <- sampler_hd(dat = species.dat$Prop_CRH_ObsSD,
                                      mode = 'rbeta',
                                      n = iter,
                                      mean=species.dat$Prop_CRH_Obs,
                                      sd = species.dat$Prop_CRH_ObsSD)


  sampledBirdParams$NocturnalActivity <- sampler_hd(dat = species.dat$Nocturnal_ActivitySD,
                                                    mode = 'rbeta',
                                                    n = iter,
                                                    mean=species.dat$Nocturnal_Activity,
                                                    sd = species.dat$Nocturnal_ActivitySD)


  sampledBirdParams$AvoidanceBasic <- sampler_hd(dat = species.dat$AvoidanceBasicSD,
                                                 mode = 'rbeta',
                                                 n = iter,
                                                 mean=species.dat$AvoidanceBasic,
                                                 sd = species.dat$AvoidanceBasicSD)

  sampledBirdParams$AvoidanceExtended <- sampler_hd(dat = species.dat$AvoidanceExtendedSD,
                                                    mode = 'rbeta',
                                                    n = iter,
                                                    mean=species.dat$AvoidanceExtended,
                                                    sd = species.dat$AvoidanceExtendedSD)

  ## sample monthly densities

  if(dens_opt == "truncNorm"){
    for(currentMonth in month.abb){
      # separate out the current month mean and SD. Species.count is already filtered for current species
      workingMean <- species.count %>% dplyr::select(contains(currentMonth),-contains('SD'))
      workingSD <- species.count %>% dplyr::select(contains(paste0(currentMonth,"SD")))
      sampledSpeciesCount[,grep(currentMonth, names(sampledSpeciesCount))] <- sampler_hd(dat = data.frame(workingSD)[1,1],
                                                                                         mode = 'rtnorm',
                                                                                         n = iter,
                                                                                         mean=data.frame(workingMean)[1,1],
                                                                                         sd = data.frame(workingSD)[1,1])
    }
  }

  if(dens_opt == "reSamp"){
    for(currentMonth in monthLabels){
      workingVect <- dplyr::sample_n(tbl = species.count %>% dplyr::select(contains(currentMonth)), size = iter, replace = TRUE)
      sampledSpeciesCount[,grep(currentMonth, names(sampledSpeciesCount))] <- workingVect
    }
  }

  if(dens_opt == "pcntiles"){
    for(currentMonth in monthLabels){
      cPcntls <- species.count %>% dplyr::select(referenceProbs, contains(currentMonth))
      workingVect <- sampleCount_pctiles(iter, probs = cPcntls[, 1], countsPctls = cPcntls[, 2])
      sampledSpeciesCount[,grep(currentMonth, names(sampledSpeciesCount))] <- workingVect
    }
  }

  # convert to data.matrix for improved performance
  sampledSpeciesCount <- data.matrix(sampledSpeciesCount)


  ## sample species flight height distribution
  if(any(model_options %in% c(2, 3))){
    if(!is.null(fhd_bootstraps)){
      sampledSpeciesFHD <- data.matrix(
        fhd_bootstraps[, sample(2:ncol(fhd_bootstraps), iter, replace = TRUE)]
      )
    } else {
      stop("`fhd_bootstraps` argument is NULL while model options 2 and/or 3 are",
           " requested in `model_options`.\n",
           "   Dataset with bootstrap samples of flight height distributions ",
           "must be provided for model options 2 and 3")
    }
  }



  ## turbine parameters

  ## function where the row gets passed in for sampling
  sampledTurbine <- sample_turbine(TurbineData,
                                   windSpeedMean = windSpeedMean,
                                   windSpeedSD = windSpeedSD,windData,
                                   windThreshold,iter)

  ## sample monthly operational proportion
  # convert from % to proportion
  sampled_oper_prop <- sampledTurbine %>%
    select(contains("Op", ignore.case = F)) %>%
    dplyr::mutate(dplyr::across(everything(), ~ .x/100)) %>%
    data.matrix()

  sampled_avg_oper_prop <- apply(sampled_oper_prop, 1, mean)


  # Iterating over sampled parameters  -----------------------------------------

  for (i in 1:iter){

    # Collision risk steps -----------------------------------------------------

    # STEP 1 - Calculate probability of collision for a single rotor transit in
    #          the absence of avoidance [Stage C in Band (2012)]

    p_single_collision <-
      get_prob_collision(
        chord_prof = chord_profile,
        flight_speed = sampledBirdParams$FlightSpeed[i],
        body_lt = sampledBirdParams$BodyLength[i],
        wing_span = sampledBirdParams$WingSpan[i],
        prop_upwind = Prop_Upwind,
        flap_glide = Flap_Glide,
        rotor_speed = sampledTurbine$RotorSpeed[i],
        rotor_radius = sampledTurbine$RotorRadius[i],
        blade_width = sampledTurbine$BladeWidth[i],
        blade_pitch = sampledTurbine$Pitch[i],
        n_blades = Turbine_Data$Blades
      )


    # STEP 2 - Set up Large Array Correction Factor -----
    if (LargeArrayCorrection == TRUE) {
      L_ArrayCF <-
        get_lac_factor(
          n_turbines = n_turbines,
          rotor_radius = sampledTurbine$RotorRadius[i],
          avoidance_rate = sampledBirdParams$AvoidanceBasic[i],
          prob_single_collision = p_single_collision,
          mean_prop_operational = sampled_avg_oper_prop[i],
          wf_width = WFWidth
        )
    } else{
      # set multiplier to 1 to dismiss large array correction
      L_ArrayCF <- 1
    }


    # STEP 3 - Calculate bird flux per month -----------------------------------
    flux_fct <-
      get_flux_factor(
        n_turbines = n_turbines,
        rotor_radius = sampledTurbine$RotorRadius[i],
        flight_speed = sampledBirdParams$FlightSpeed[i],
        bird_dens = sampledSpeciesCount[i, ],
        daynight_hrs = daynight_hrs_month,
        noct_activity = sampledBirdParams$NocturnalActivity[i]
    )


    # STEP 4 - for model options 2 or 3, calculate generic FHD across rotor height -
    if(any(model_options %in% c(2, 3))){

      gen_fhd_at_rotor <- get_fhd_rotor(
        hub_height = sampledTurbine$HubHeight[i],
        fhd = sampledSpeciesFHD[, i],
        rotor_radius = sampledTurbine$RotorRadius[i],
        tide_off = TideOff)
    }


    # STEP 5 - Calculate collisions per month under each model option ----------
    if(any(model_options == 1)){

      scrm_outputs$opt1[i, ] <-
        crm_opt1(
          flux_factor = flux_fct,
          prop_crh_surv = sampledBirdParams$PCH[i],
          prob_single_collision = p_single_collision,
          prop_operational = sampled_oper_prop[i, ],
          avoidance_rate = sampledBirdParams$AvoidanceBasic[i],
          lac_factor = L_ArrayCF)
    }


    if(any(model_options == 2)){
      scrm_outputs$opt2[i, ] <-
        crm_opt2(
          gen_d_y = gen_fhd_at_rotor,
          flux_factor = flux_fct,
          prob_single_collision = p_single_collision,
          prop_operational = sampled_oper_prop[i, ],
          avoidance_rate = sampledBirdParams$AvoidanceBasic[i],
          lac_factor = L_ArrayCF)
    }


    if(any(model_options == 3)){
      scrm_outputs$opt3[i, ] <-
        crm_opt3(
          gen_d_y = gen_fhd_at_rotor,
          rotor_radius = sampledTurbine$RotorRadius[i],
          blade_width = sampledTurbine$BladeWidth[i],
          rotor_speed = sampledTurbine$RotorSpeed[i],
          blade_pitch = sampledTurbine$Pitch[i],
          flight_type_num = species.dat$FlightNumeric,
          wing_span = sampledBirdParams$WingSpan[i],
          flight_speed = sampledBirdParams$FlightSpeed[i],
          body_lt = sampledBirdParams$BodyLength[i],
          n_blades = Turbine_Data$Blades,
          prop_upwind = Prop_Upwind,
          avoidance_rate_ext = sampledBirdParams$AvoidanceExtended[i],
          flux_factor = flux_fct,
          prop_operational = sampled_oper_prop[i, ],
          lac_factor = L_ArrayCF)
    }



  } # end of i to iter

  scrm_outputs

#   # End of the random sampling iterations i --------------------------------
#
#
#   #source("scripts/turbineSpeciesOuputs.r", local=T)
#
#   #### BC ##### -- reset counter of progress bar for iterations =====================
#   #if (is.function(updateProgress_Iter)) {
#   #  text <- NULL # paste0("Working through iteration ", i)
#   #  updateProgress_Iter(value = 0, detail = text)
#   #}
#
#
#   #### BC ##### -- Store simulation replicates under each option, for current species and turbine  ===========
#   cSpec <- CRSpecies[s]
#   cTurbModel <- paste0("turbModel", TurbineData$TurbineModel[j])
#
#   monthCollsnReps_opt1[[cSpec]][[cTurbModel]] <- tab1
#   #monthCollsnReps_opt2[[cSpec]][[cTurbModel]] <- tab2
#   #monthCollsnReps_opt3[[cSpec]][[cTurbModel]] <- tab3
#
#
#   ###output species plots of density by option with curves for turbine model###
#   ###PLOT DENSITY BY OPTION (useful if several turbine models)###
#
#   #if (nrow(TurbineData)>1)  {
#   #source("scripts/species_turbine_plots.r", local = T)
#   #}
#
#   ###relabel sampledBirdParams by species name###
#   assign(paste(CRSpecies[s],"params", sep="_"), sampledBirdParams)
#
#   ###relabel sampledSpeciesCount by species name###
#   assign(paste(CRSpecies[s],"counts", sep="_"), sampledSpeciesCount)
#
#
#   ##output input data##
#   fwrite(BirdData, paste(results_folder,"input", "BirdData.csv", sep="/"))
#   fwrite(CountData, paste(results_folder,"input", "birdDensityData.csv", sep="/"))      # <<<<< BC <<<<<  change of file name, for clarity
#   fwrite(TurbineData, paste(results_folder,"input", "TurbineData.csv", sep="/"))
#
#   ###output results table###
#   fwrite(resultsSummary, paste(results_folder,"tables", "CollisionEstimates.csv", sep="/"))
#
#
#   end.time <- Sys.time()
#   run.time <- end.time - start.time
#   run.time
#
#   sink(paste(results_folder,"run.time.txt", sep="/"))
#   print(run.time)
#   print(paste("The model ran", iter,"iterations", sep=" "))
#   print("The following species were modelled:")
#   print(CRSpecies)
#   print("The following turbines were modelled:")
#   print(TurbineData$TurbineModel)
#   sink()
#
#   #### BC ##### -- return collision replicates as output  ===========
#   return(list(monthCollsnReps_opt1 = monthCollsnReps_opt1))#, monthCollsnReps_opt2 = monthCollsnReps_opt2,#monthCollsnReps_opt3 = monthCollsnReps_opt3))


}

