# insert your copyright here

# see the URL below for information on how to write OpenStudio measures
# http://nrel.github.io/OpenStudio-user-documentation/reference/measure_writing_guide/
require 'openstudio-standards'

# start the measure
class AddConsoleGSHP < OpenStudio::Measure::ModelMeasure
  # human readable name
  def name
    # Measure name should be the title case of the class name.
    return 'add_console_gshp'
  end

  # human readable description
  def description
    return 'Measure replaces existing packaged terminal air conditioner system types with water-to-air heat pumps served by a ground heat exchanger.'
  end

  # human readable description of modeling approach
  def modeler_description
    return 'This measure will work on packaged terminal systems as well as other non-ducted systems such as baseboards or unit heaters.'
  end

  # Define the arguments that the user will input
  def arguments(model)
    args = OpenStudio::Measure::OSArgumentVector.new

    return args
  end

  # Define the main method that will be called by the OpenStudio application
  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)

    # build standard to use OS standards methods
    template = 'ComStock 90.1-2019'
    std = Standard.build(template)
    # get climate zone value
    climate_zone = std.model_standards_climate_zone(model)

    # determine if the air loop is residential (checks to see if there is outdoor air system object)
    # measure will be applicable to residential AC/residential furnace systems
    def air_loop_res?(air_loop_hvac)
      is_res_system = true
      air_loop_hvac.supplyComponents.each do |component|
        obj_type = component.iddObjectType.valueName.to_s
        case obj_type
        when 'OS_AirLoopHVAC_OutdoorAirSystem'
          is_res_system = false
        end
      end
      return is_res_system
    end

    # Determine if is evaporative cooler
    # measure will be applicable to buildings with direct evap coolers
    def air_loop_evaporative_cooler?(air_loop_hvac)
      is_evap = false
      air_loop_hvac.supplyComponents.each do |component|
        obj_type = component.iddObjectType.valueName.to_s
        case obj_type
        when 'OS_EvaporativeCooler_Direct_ResearchSpecial', 'OS_EvaporativeCooler_Indirect_ResearchSpecial', 'OS_EvaporativeFluidCooler_SingleSpeed', 'OS_EvaporativeFluidCooler_TwoSpeed'
          is_evap = true
        end
      end
      return is_evap
    end

    # Determine if the air loop is a unitary system
    # @return [Bool] Returns true if a unitary system is present, false if not.
    def air_loop_hvac_unitary_system?(air_loop_hvac)
      is_unitary_system = false
      air_loop_hvac.supplyComponents.each do |component|
        obj_type = component.iddObjectType.valueName.to_s
        case obj_type
        when 'OS_AirLoopHVAC_UnitarySystem', 'OS_AirLoopHVAC_UnitaryHeatPump_AirToAir', 'OS_AirLoopHVAC_UnitaryHeatPump_AirToAir_MultiSpeed', 'OS_AirLoopHVAC_UnitaryHeatCool_VAVChangeoverBypass'
          is_unitary_system = true
        end
      end
      return is_unitary_system
    end

    # measure will be applicable to some system types that have air loops; need to narrow down to these system types
    selected_air_loops = []
    equip_to_delete = []
    ptacs = []
    pthps = []
    baseboards = []
    unit_heaters = []
    all_air_loops = model.getAirLoopHVACs
    puts "air loops = #{all_air_loops}"
    if all_air_loops.empty?
      runner.registerInfo("Model does not have any air loops. Get list of PTAC, PTHP, Unit Heater, or Baseboard Electric equipment to delete.")

      # check for PTAC units and add to array of zone equipment to delete
      model.getThermalZones.each do |thermal_zone|
        thermal_zone.equipment.each do |equip|
          next unless equip.to_ZoneHVACPackagedTerminalAirConditioner.is_initialized
          ptacs << equip.to_ZoneHVACPackagedTerminalAirConditioner.get
          equip_to_delete << equip.to_ZoneHVACPackagedTerminalAirConditioner.get
        end
      end

      #check for PTHP units and add to array of zone equipment to delete
      model.getThermalZones.each do |thermal_zone|
        thermal_zone.equipment.each do |equip|
          next unless equip.to_ZoneHVACPackagedTerminalHeatPump.is_initialized
          pthps << equip.to_ZoneHVACPackagedTerminalHeatPump.get
          equip_to_delete << equip.to_ZoneHVACPackagedTerminalHeatPump.get
        end
      end

      #check for baseboard electric and add to array of zone equipment to delete
      model.getThermalZones.each do |thermal_zone|
        thermal_zone.equipment.each do |equip|
          next unless equip.to_ZoneHVACBaseboardConvectiveElectric.is_initialized
          baseboards << equip.to_ZoneHVACBaseboardConvectiveElectric.get
          equip_to_delete << equip.to_ZoneHVACBaseboardConvectiveElectric.get
        end
      end

      #check for gas unit heaters and add to array of zone equipment to delete
      model.getThermalZones.each do |thermal_zone|
        thermal_zone.equipment.each do |equip|
          next unless equip.to_ZoneHVACUnitHeater.is_initialized
          unit_heaters << equip.to_ZoneHVACUnitHeater.get
          equip_to_delete << equip.to_ZoneHVACUnitHeater.get
        end
      end
    end

    # loop through all air loops and look for residential systems and direct evap coolers
    # then remove any zone equipment associated with existing system
    all_air_loops.each do |air_loop_hvac|
      # check if residential system
      if air_loop_res?(air_loop_hvac)
        selected_air_loops << air_loop_hvac
        thermal_zone = air_loop_hvac.thermalZones[0]
        thermal_zone.equipment.each do |equip|
          equip_to_delete << equip
        end
        runner.registerInfo("Model has residential HVAC system, measure will be applied.")
      # check if evaporative cooling systems
      elsif air_loop_evaporative_cooler?(air_loop_hvac)
        selected_air_loops << air_loop_hvac
        thermal_zone = air_loop_hvac.thermalZones[0]
        thermal_zone.equipment.each do |equip|
          equip_to_delete << equip
        end
        runner.registerInfo("Model has direct evap coolers, measure will be applied.")
      end
    end

    # get plant loops and remove
    # only relevant for direct evap coolers with baseboard gas boiler
    plant_loops = model.getPlantLoops
    if plant_loops.size >> 0
      plant_loops.each do |plant_loop|
        runner.registerInfo("Removed existing plant loop #{plant_loop.name}.")
        plant_loop.remove
      end
    end

    # check for PTAC with gas boiler and remove baseboard water from zones
    if ptacs.size >> 0
      model.getThermalZones.each do |thermal_zone|
        thermal_zone.equipment.each do |equip|
          next unless equip.to_ZoneHVACBaseboardConvectiveWater.is_initialized
          baseboards << equip.to_ZoneHVACBaseboardConvectiveWater.get
          equip_to_delete << equip.to_ZoneHVACBaseboardConvectiveWater.get
        end
      end
    end

    # register as not applicable if not
    if pthps.empty? && ptacs.empty? && baseboards.empty? && unit_heaters.empty? && selected_air_loops.empty?
      runner.registerAsNotApplicable('HVAC system in model is not compatible with console GSHP upgrade.')
      return true
    end

    cond_loop_setpoint_c = 18.3 #65F
    preheat_coil_min_temp = 10.0 #50F

    #add condenser loop to connect heat pumps loops with ground loop
    condenser_loop = OpenStudio::Model::PlantLoop.new(model)
    runner.registerInfo("Condenser Loop added.")
    condenser_loop.setName('Condenser Loop')
    condenser_loop.setMaximumLoopTemperature(100.0)
    condenser_loop.setMinimumLoopTemperature(10.0)
    condenser_loop.setLoadDistributionScheme('SequentialLoad')
    condenser_loop_sizing = condenser_loop.sizingPlant
    condenser_loop_sizing.setLoopType('Condenser')
    condenser_loop_sizing.setDesignLoopExitTemperature(cond_loop_setpoint_c)

    # Create a scheduled setpoint manager
    # TODO determine if a schedule that follows the monthly ground temperature
    # would result in significantly different loads
    condenser_high_temp_sch = OpenStudio::Model::ScheduleConstant.new(model)
    condenser_high_temp_sch.setName('Condenser Loop High Temp Schedule')
    condenser_high_temp_sch.setValue(29.44) #C
    condenser_low_temp_sch = OpenStudio::Model::ScheduleConstant.new(model)
    condenser_low_temp_sch.setName('Condenser Loop Low Temp Schedule')
    condenser_low_temp_sch.setValue(4.44) #C
    condenser_setpoint_manager = OpenStudio::Model::SetpointManagerScheduledDualSetpoint.new(model)
    condenser_setpoint_manager.setName('Condenser Loop Setpoint Manager')
    condenser_setpoint_manager.setHighSetpointSchedule(condenser_high_temp_sch)
    condenser_setpoint_manager.setLowSetpointSchedule(condenser_low_temp_sch)
    condenser_setpoint_manager.addToNode(condenser_loop.supplyOutletNode)

    # Create and add a pump to the loop
    condenser_pump = OpenStudio::Model::PumpVariableSpeed.new(model)
    condenser_pump.setName('Condenser loop circulation pump')
    condenser_pump.setPumpControlType('Intermittent')
    condenser_pump.setRatedPumpHead(44834.7) # 15 ft for primary pump for a primary-secondary system based on Appendix G; does this need to change?
    condenser_pump.addToNode(condenser_loop.supplyInletNode)

    # Create new loop connecting heat pump and ground heat exchanger.
    # Initially, a PlantLoop:TemperatureSource object will be used.
    # After a GHEDesigner simulation is run the PlantLoop:TemperatureSource
    # object will be replaced with a vertical ground heat exchanger
    # with borehole properties and G-functions per the GHEDesigner output.
    ground_loop = OpenStudio::Model::PlantLoop.new(model)
    runner.registerInfo("Ground Loop added.")
    ground_loop.setName('Ground Loop')
    ground_loop.setMaximumLoopTemperature(100.0)
    ground_loop.setMinimumLoopTemperature(10.0)
    ground_loop.setLoadDistributionScheme('SequentialLoad')
    ground_loop_sizing = ground_loop.sizingPlant
    ground_loop_sizing.setLoopType('Condenser') #is this right?
    ground_loop_sizing.setDesignLoopExitTemperature(18.33) #does this need to change to ~140F?

    #set fluid as 20% propyleneglycol
    ground_loop.setGlycolConcentration(20)
    ground_loop.setFluidType('PropyleneGlycol')

    # add water to water heat exchanger
    fluid_fluid_heat_exchanger = OpenStudio::Model::HeatExchangerFluidToFluid.new(model)
    fluid_fluid_heat_exchanger.setName('HX for heat pump')
    fluid_fluid_heat_exchanger.setHeatExchangeModelType('Ideal')
    fluid_fluid_heat_exchanger.setControlType('UncontrolledOn')
    fluid_fluid_heat_exchanger.setHeatTransferMeteringEndUseType('LoopToLoop')
    ground_loop.addDemandBranchForComponent(fluid_fluid_heat_exchanger)
    condenser_loop.addSupplyBranchForComponent(fluid_fluid_heat_exchanger)

    # Create and add a pump to the loop
    ground_pump = OpenStudio::Model::PumpConstantSpeed.new(model)
    ground_pump.setName('Ground loop circulation pump')
    ground_pump.setRatedPumpHead(44834.7) # 15 ft for primary pump for a primary-secondary system based on Appendix G; does this need to change?
    ground_pump.addToNode(ground_loop.supplyInletNode)

    # Create a scheduled setpoint manager
    # TODO determine if a schedule that follows the monthly ground temperature
    # would result in significantly different loads
    ground_high_temp_sch = OpenStudio::Model::ScheduleConstant.new(model)
    ground_high_temp_sch.setName('Ground Loop High Temp Schedule')
    ground_high_temp_sch.setValue(24.0) #C
    ground_low_temp_sch = OpenStudio::Model::ScheduleConstant.new(model)
    ground_low_temp_sch.setName('Ground Loop Low Temp Schedule')
    ground_low_temp_sch.setValue(12.78) #C
    ground_setpoint_manager = OpenStudio::Model::SetpointManagerScheduledDualSetpoint.new(model)
    ground_setpoint_manager.setName('Ground Loop Setpoint Manager')
    ground_setpoint_manager.setHighSetpointSchedule(ground_high_temp_sch)
    ground_setpoint_manager.setLowSetpointSchedule(ground_low_temp_sch)
    ground_setpoint_manager.addToNode(ground_loop.supplyOutletNode)

    # Create and add a PlantComponent:TemperatureSource object to supply side of ground loop
    ground_temp_source = OpenStudio::Model::PlantComponentTemperatureSource.new(model)
    ground_temp_source.setName('Ground Loop Temperature Source (Ground Heat Exchanger Placeholder)')
    ground_temp_source.autosizeDesignVolumeFlowRate
    ground_temp_source.setTemperatureSpecificationType('Constant')
    ground_temp_source.setSourceTemperature(12.78)

    # Add temp source to the supply side of the ground loop
    ground_loop.addSupplyBranchForComponent(ground_temp_source)

    # delete equipment from original loop
    equip_to_delete.each(&:remove)

    # Loop through air loops, plant loops, and thermal zones and remove old equipment
    selected_air_loops.each do |air_loop_hvac|
      # remove old air loop, new ones will be added
      air_loop_hvac.remove
    end

    # Loop through each thermal zone and remove old PTAC/PTHP and replace it with a water-to-air ground source heat pump
    model.getThermalZones.each do |thermal_zone|
      OpenStudio.logFree(OpenStudio::Info, 'openstudio.Model.Model', "Adding water-to-air heat pump for #{thermal_zone.name}.")

      #create new air loop for unitary system
      air_loop_hvac = OpenStudio::Model::AirLoopHVAC.new(model)
      air_loop_hvac.setName("#{thermal_zone.name} Air Loop")
      air_loop_sizing = air_loop_hvac.sizingSystem

      # zone sizing
      # adjusted zone design temperatures for ptac
      dsgn_temps = std.standard_design_sizing_temperatures
      dsgn_temps['zn_htg_dsgn_sup_air_temp_f'] = 122.0
      dsgn_temps['zn_htg_dsgn_sup_air_temp_c'] = OpenStudio.convert(dsgn_temps['zn_htg_dsgn_sup_air_temp_f'], 'F', 'C').get
      dsgn_temps['zn_clg_dsgn_sup_air_temp_f'] = 57.0
      dsgn_temps['zn_clg_dsgn_sup_air_temp_c'] = OpenStudio.convert(dsgn_temps['zn_clg_dsgn_sup_air_temp_f'], 'F', 'C').get
      sizing_zone = thermal_zone.sizingZone
      sizing_zone.setZoneCoolingDesignSupplyAirTemperature(dsgn_temps['zn_clg_dsgn_sup_air_temp_c'])
      sizing_zone.setZoneHeatingDesignSupplyAirTemperature(dsgn_temps['zn_htg_dsgn_sup_air_temp_c'])
      sizing_zone.setZoneCoolingDesignSupplyAirHumidityRatio(0.008)
      sizing_zone.setZoneHeatingDesignSupplyAirHumidityRatio(0.008)

      # set always on schedule; this will be used in other object definitions
      always_on = model.alwaysOnDiscreteSchedule

      #using 10 ton units for packaged unit performance data
      #using 1 ton units for console
      # add new single speed cooling coil
      new_cooling_coil = OpenStudio::Model::CoilCoolingWaterToAirHeatPumpEquationFit.new(model)
      new_cooling_coil.setName("#{thermal_zone.name} Heat Pump Cooling Coil")
      new_cooling_coil.setRatedCoolingCoefficientofPerformance(3.4)
      new_cooling_coil.setTotalCoolingCapacityCoefficient1(-4.30266987344639)
      new_cooling_coil.setTotalCoolingCapacityCoefficient2(7.18536990534372)
      new_cooling_coil.setTotalCoolingCapacityCoefficient3(-2.23946714486189)
      new_cooling_coil.setTotalCoolingCapacityCoefficient4(0.139995928440879)
      new_cooling_coil.setTotalCoolingCapacityCoefficient5(0.102660179888915)
      new_cooling_coil.setSensibleCoolingCapacityCoefficient1(6.0019444814887)
      new_cooling_coil.setSensibleCoolingCapacityCoefficient2(22.6300677244073)
      new_cooling_coil.setSensibleCoolingCapacityCoefficient3(-26.7960783730934)
      new_cooling_coil.setSensibleCoolingCapacityCoefficient4(-1.72374720346819)
      new_cooling_coil.setSensibleCoolingCapacityCoefficient5(0.490644802367817)
      new_cooling_coil.setSensibleCoolingCapacityCoefficient6(0.0693119353468141)
      new_cooling_coil.setCoolingPowerConsumptionCoefficient1(-5.67775976415698)
      new_cooling_coil.setCoolingPowerConsumptionCoefficient2(0.438988156976704)
      new_cooling_coil.setCoolingPowerConsumptionCoefficient3(5.845277342193)
      new_cooling_coil.setCoolingPowerConsumptionCoefficient4(0.141605667000125)
      new_cooling_coil.setCoolingPowerConsumptionCoefficient5(-0.168727936032429)
      condenser_loop.addDemandBranchForComponent(new_cooling_coil)

      # add new single speed heating coil
      new_heating_coil = OpenStudio::Model::CoilHeatingWaterToAirHeatPumpEquationFit.new(model)
      new_heating_coil.setName("#{thermal_zone.name} Heat Pump Heating Coil")
      new_heating_coil.setRatedHeatingCoefficientofPerformance(4.2)
      new_heating_coil.setHeatingCapacityCoefficient1(0.237847462869254)
      new_heating_coil.setHeatingCapacityCoefficient2(-3.35823796081626)
      new_heating_coil.setHeatingCapacityCoefficient3(3.80640467406376)
      new_heating_coil.setHeatingCapacityCoefficient4(0.179200417311554)
      new_heating_coil.setHeatingCapacityCoefficient5(0.12860719846082)
      new_heating_coil.setHeatingPowerConsumptionCoefficient1(-3.79175529243238)
      new_heating_coil.setHeatingPowerConsumptionCoefficient2(3.38799239505527)
      new_heating_coil.setHeatingPowerConsumptionCoefficient3(1.5022612076303)
      new_heating_coil.setHeatingPowerConsumptionCoefficient4(-0.177653510577989)
      new_heating_coil.setHeatingPowerConsumptionCoefficient5(-0.103079864171839)
      condenser_loop.addDemandBranchForComponent(new_heating_coil)

      #add supply fan
      fan = OpenStudio::Model::FanConstantVolume.new(model)
      fan.setName("#{thermal_zone.name} Fan")
      fan.setFanEfficiency(0.63) # from PNNL
      fan.setPressureRise(50.0) #Pascal
      fan.setMotorEfficiency(0.29)

      # Create a new water-to-air ground source heat pump system
      unitary_system = OpenStudio::Model::AirLoopHVACUnitarySystem.new(model)
      unitary_system.setControlType('Setpoint')
      unitary_system.setCoolingCoil(new_cooling_coil)
      unitary_system.setHeatingCoil(new_heating_coil)
      unitary_system.setControllingZoneorThermostatLocation(thermal_zone)
      unitary_system.setSupplyFan(fan)
      unitary_system.setFanPlacement('DrawThrough')
      if model.version < OpenStudio::VersionString.new('3.7.0')
        unitary_system.setSupplyAirFlowRateMethodDuringCoolingOperation('SupplyAirFlowRate')
        unitary_system.setSupplyAirFlowRateMethodDuringHeatingOperation('SupplyAirFlowRate')
        unitary_system.setSupplyAirFlowRateMethodWhenNoCoolingorHeatingisRequired('SupplyAirFlowRate')
      else
        unitary_system.autosizeSupplyAirFlowRateDuringCoolingOperation
        unitary_system.autosizeSupplyAirFlowRateDuringHeatingOperation
        unitary_system.autosizeSupplyAirFlowRateWhenNoCoolingorHeatingisRequired
      end
      unitary_system.setSupplyAirFanOperatingModeSchedule(model.alwaysOnDiscreteSchedule)
      unitary_system.setMaximumOutdoorDryBulbTemperatureforSupplementalHeaterOperation(OpenStudio.convert(40.0, 'F', 'C').get)
      unitary_system.setName("#{thermal_zone.name} Unitary HP")
      unitary_system.setMaximumSupplyAirTemperature(40.0)
      unitary_system.addToNode(air_loop_hvac.supplyOutletNode)

      # create a diffuser and attach the zone/diffuser pair to the air loop
      diffuser = OpenStudio::Model::AirTerminalSingleDuctUncontrolled.new(model, model.alwaysOnDiscreteSchedule)
      diffuser.setName("#{air_loop_hvac.name} Diffuser")
      air_loop_hvac.multiAddBranchForZone(thermal_zone, diffuser.to_HVACComponent.get)

      # make outdoor air fraction for constant 15%
      pct_oa = OpenStudio::Model::ScheduleConstant.new(model)
      pct_oa.setName('Outdoor Air Fraction 15%')
      pct_oa.setValue(0.15)

      # add the OA system
      oa_controller = OpenStudio::Model::ControllerOutdoorAir.new(model)
      oa_controller.setName("#{air_loop_hvac.name} OA System Controller")
      oa_controller.setMinimumOutdoorAirSchedule(always_on)
      oa_controller.autosizeMinimumOutdoorAirFlowRate
      oa_controller.resetEconomizerMinimumLimitDryBulbTemperature
      oa_controller.setMinimumFractionofOutdoorAirSchedule(pct_oa)
      oa_system = OpenStudio::Model::AirLoopHVACOutdoorAirSystem.new(model, oa_controller)
      oa_system.setName("#{air_loop_hvac.name} OA System")
      oa_system.addToNode(air_loop_hvac.supplyInletNode)

      # create a scheduled setpoint manager
      hp_setpoint_manager = OpenStudio::Model::SetpointManagerSingleZoneReheat.new(model)
      hp_setpoint_manager.setName('HP Supply Temp Setpoint Manager')
      hp_setpoint_manager.setMinimumSupplyAirTemperature(12.78)
      hp_setpoint_manager.setMaximumSupplyAirTemperature(50.0)
      hp_setpoint_manager.addToNode(air_loop_hvac.supplyOutletNode)

      #add electric preheat coil to OA system to temper ventilation air
      preheat_coil = OpenStudio::Model::CoilHeatingElectric.new(model)
      preheat_coil.setName('Electric Preheat Coil')
      preheat_coil.setEfficiency(0.95)

      #get inlet node of unitary system to place preheat coil
      preheat_coil_location = unitary_system.airInletModelObject.get.to_Node.get
      preheat_coil.addToNode(preheat_coil_location)

      # Create a scheduled setpoint manager
      # would result in significantly different loads
      preheat_coil_temp_sch = OpenStudio::Model::ScheduleConstant.new(model)
      preheat_coil_temp_sch.setName('Preheat Coil Temp Schedule')
      preheat_coil_temp_sch.setValue(preheat_coil_min_temp)
      preheat_coil_setpoint_manager = OpenStudio::Model::SetpointManagerScheduled.new(model, preheat_coil_temp_sch)
      preheat_coil_setpoint_manager.setControlVariable('Temperature')
      preheat_coil_setpoint_manager.setName('OA Preheat Coil Setpoint Manager')

      #get outlet node of preheat coil to place setpoint manager
      preheat_sm_location = preheat_coil.outletModelObject.get.to_Node.get
      preheat_coil_setpoint_manager.addToNode(preheat_sm_location)

      # Create a scheduled setpoint manager
      # would result in significantly different loads
      preheat_coil_temp_sch = OpenStudio::Model::ScheduleConstant.new(model)
      preheat_coil_temp_sch.setName('Preheat Coil Temp Schedule')
      preheat_coil_temp_sch.setValue(preheat_coil_min_temp)
      preheat_coil_setpoint_manager = OpenStudio::Model::SetpointManagerScheduled.new(model, preheat_coil_temp_sch)
      preheat_coil_setpoint_manager.setControlVariable('Temperature')
      preheat_coil_setpoint_manager.setName('OA Preheat Coil Setpoint Manager')

      #get outlet node of preheat coil to place setpoint manager
      preheat_sm_location = preheat_coil.outletModelObject.get.to_Node.get
      preheat_coil_setpoint_manager.addToNode(preheat_sm_location)
    end

    # add output variable for GHEDesigner
    reporting_frequency = 'Hourly'
    outputVariable = OpenStudio::Model::OutputVariable.new('Plant Temperature Source Component Heat Transfer Rate', model)
    outputVariable.setReportingFrequency(reporting_frequency)
    runner.registerInfo("Adding output variable for 'Plant Temperature Source Component Heat Transfer Rate' reporting at the hourly timestep.")

    # retrieve or perform annual run to get hourly thermal loads
    ann_loads_run_dir = "#{Dir.pwd}/AnnualGHELoadsRun"
    ann_loads_sql_path = "#{ann_loads_run_dir}/run/eplusout.sql"
    if File.exist?(ann_loads_sql_path)
      sql_path = OpenStudio::Path.new(ann_loads_sql_path)
      sql = OpenStudio::SqlFile.new(sql_path)
      model.setSqlFile(sql)
    else
      runner.registerInfo('Running an annual simulation to determine thermal loads for ground heat exchanger.')
      if std.model_run_simulation_and_log_errors(model, ann_loads_run_dir) == false
        runner.registerError('Sizing run failed. See errors in sizing run directory or this measure')
        return false
      end
    end

    # get timeseries output variable values
    # check for sql file
    if model.sqlFile.empty?
      runner.registerError("Model did not have an sql file; cannot get loads for ground heat exchanger.")
      return false
    end
    sql = model.sqlFile.get

    # get weather file run period (as opposed to design day run period)
    ann_env_pd = nil
    sql.availableEnvPeriods.each do |env_pd|
      env_type = sql.environmentType(env_pd)
      if env_type.is_initialized
        if env_type.get == OpenStudio::EnvironmentType.new('WeatherRunPeriod')
          ann_env_pd = env_pd
        end
      end
    end

    # add timeseries ground loads to array
    ground_loads_ts = sql.timeSeries(ann_env_pd, 'Hourly', 'Plant Temperature Source Component Heat Transfer Rate', 'GROUND LOOP TEMPERATURE SOURCE (GROUND HEAT EXCHANGER PLACEHOLDER)')
    runner.registerInfo("Ground loads = #{ground_loads_ts}")
    if ground_loads_ts.is_initialized
      ground_loads = []
      vals = ground_loads_ts.get.values
      for i in 0..(vals.size - 1)
        ground_loads << vals[i]
      end
    end

    # Make directory for GHEDesigner simulation
    ghedesigner_run_dir = "#{Dir.pwd}/GHEDesigner"
    # ghedesigner_run_dir = "C:/Users/mprapros/Desktop/ghedesigner"
    runner.registerInfo("ghedesigner_run_dir = #{ghedesigner_run_dir}")
    if !File.exist?(ghedesigner_run_dir)
      FileUtils.mkdir_p(ghedesigner_run_dir)
    end

    # Make json input file for GHEDesigner
    borefield_defaults_json_path = "#{File.dirname(__FILE__)}/resources/borefield_defaults.json"
    borefield_defaults = JSON.parse(File.read(borefield_defaults_json_path))
    borefield_defaults['loads'] = {}
    borefield_defaults['loads']['ground_loads'] = ground_loads
    ghe_in_path = "#{ghedesigner_run_dir}/ghedesigner_input.json"
    File.write(ghe_in_path, JSON.pretty_generate(borefield_defaults))
    runner.registerInfo('GHEDesigner input JSON file created.')

    # Make system call to run GHEDesigner
    start_time = Time.new
    # TODO remove conda activate andrew
    require 'open3'
    require 'etc'

    envname = 'base'
    # command = "C:/Users/#{Etc.getlogin}/Anaconda3/Scripts/activate.bat && conda activate #{envname} && ghedesigner #{ghe_in_path} #{ghedesigner_run_dir}"
    # command = "conda activate base && ghedesigner '#{ghe_in_path}' '#{ghedesigner_run_dir}'"
    command = "ghedesigner #{ghe_in_path} #{ghedesigner_run_dir}"
    stdout_str, stderr_str, status = Open3.capture3(command, chdir: ghedesigner_run_dir)
    if status.success?
      runner.registerInfo("Successfully ran ghedesigner: #{command}")
    else
      runner.registerError("Error running ghedesigner: #{command}")
      runner.registerError("stdout: #{stdout_str}")
      runner.registerError("stderr: #{stderr_str}")
      return false
    end
    end_time = Time.new
    runner.registerInfo("Running GHEDesigner took #{end_time - start_time} seconds")

    # Get some information from borefield inputs
    pipe_thermal_conductivity_w_per_m_k = borefield_defaults['pipe']['conductivity']

    # Read GHEDesigner simulation summary file
    # Check unit strings for all numeric values in case GHEDesigner changes units
    sim_summary = JSON.parse(File.read("#{ghedesigner_run_dir}/SimulationSummary.json"))
    ghe_sys = sim_summary['ghe_system']

    number_of_boreholes = ghe_sys['number_of_boreholes']
    runner.registerInfo("number of boreholes = #{number_of_boreholes}")

    throw 'Unexpected units' unless ghe_sys['fluid_mass_flow_rate_per_borehole']['units'] == 'kg/s'
    fluid_mass_flow_rate_per_borehole_kg_per_s = ghe_sys['fluid_mass_flow_rate_per_borehole']['value']

    throw 'Unexpected units' unless ghe_sys['fluid_density']['units'] == 'kg/m3'
    fluid_density_kg_per_m3 = ghe_sys['fluid_density']['value']
    fluid_vol_flow_rate_per_borehole_m3_per_s = fluid_mass_flow_rate_per_borehole_kg_per_s / fluid_density_kg_per_m3
    fluid_vol_flow_rate_sum_all_boreholes_m3_per_s = fluid_vol_flow_rate_per_borehole_m3_per_s * number_of_boreholes

    throw 'Unexpected units' unless ghe_sys['active_borehole_length']['units'] == 'm'
    active_borehole_length_m = ghe_sys['active_borehole_length']['value']

    throw 'Unexpected units' unless ghe_sys['soil_thermal_conductivity']['units'] == 'W/m-K'
    soil_thermal_conductivity_w_per_m_k = ghe_sys['soil_thermal_conductivity']['value']

    throw 'Unexpected units' unless ghe_sys['soil_volumetric_heat_capacity']['units'] == 'kJ/m3-K'
    soil_volumetric_heat_capacity_kj_per_m3_k = ghe_sys['soil_volumetric_heat_capacity']['value']
    soil_volumetric_heat_capacity_j_per_m3_k = OpenStudio.convert(soil_volumetric_heat_capacity_kj_per_m3_k, 'kJ/m^3*K', 'J/m^3*K').get

    throw 'Unexpected units' unless ghe_sys['soil_undisturbed_ground_temp']['units'] == 'C'
    soil_undisturbed_ground_temp_c = ghe_sys['soil_undisturbed_ground_temp']['value']

    # TODO remove W/mK once https://github.com/BETSRG/GHEDesigner/issues/76 is fixed
    throw 'Unexpected units' unless ['W/mK', 'W/m-K'].include?(ghe_sys['grout_thermal_conductivity']['units'])
    grout_thermal_conductivity_w_per_m_k = ghe_sys['grout_thermal_conductivity']['value']

    throw 'Unexpected units' unless ghe_sys['pipe_geometry']['pipe_outer_diameter']['units'] == 'm'
    pipe_outer_diameter_m = ghe_sys['pipe_geometry']['pipe_outer_diameter']['value']
    throw 'Unexpected units' unless ghe_sys['pipe_geometry']['pipe_inner_diameter']['units'] == 'm'
    pipe_inner_diameter_m = ghe_sys['pipe_geometry']['pipe_inner_diameter']['value']
    pipe_thickness_m = (pipe_outer_diameter_m - pipe_inner_diameter_m) / 2.0

    throw 'Unexpected units' unless ghe_sys['shank_spacing']['units'] == 'm'
    u_tube_shank_spacing_m = ghe_sys['shank_spacing']['value']

    # Create ground heat exchanger and set properties based on GHEDesigner simulation
    ghx = OpenStudio::Model::GroundHeatExchangerVertical.new(model)
    ghx.setDesignFlowRate(fluid_vol_flow_rate_sum_all_boreholes_m3_per_s) # total for borefield m^3/s
    ghx.setNumberofBoreHoles(number_of_boreholes)
    ghx.setBoreHoleLength(active_borehole_length_m) # Depth of 1 borehole
    ghx.setGroundThermalConductivity(soil_thermal_conductivity_w_per_m_k) # W/m-K
    ghx.setGroundThermalHeatCapacity(soil_volumetric_heat_capacity_j_per_m3_k) # J/m3-K
    ghx.setGroundTemperature(soil_undisturbed_ground_temp_c) # C
    ghx.setGroutThermalConductivity(grout_thermal_conductivity_w_per_m_k) # W/m-K
    ghx.setPipeThermalConductivity(pipe_thermal_conductivity_w_per_m_k) # W/m-K
    ghx.setPipeOutDiameter(pipe_outer_diameter_m) # m
    ghx.setUTubeDistance(u_tube_shank_spacing_m) # m
    ghx.setPipeThickness(pipe_thickness_m) # m
    # ghx.setMaximumLengthofSimulation() # TODO
    # ghx.setGFunctionReferenceRatio() # TODO check with Matt Mitchel if this is necessary

    # G function
    ghx.removeAllGFunctions # Rempve the default gfunction inputs
    gfunc_data = CSV.read("#{ghedesigner_run_dir}/Gfunction.csv", headers: true)
    gfunc_data.each do |r|
      ghx.addGFunction(r['ln(t/ts)'].to_f, r['H:79.59'].to_f) # addGFunction(double gFunctionLN, double gFunctionGValue)
    end

    # Replace temperature source with ground heat exchanger
    ground_loop.addSupplyBranchForComponent(ghx)
    ground_loop.removeSupplyBranchWithComponent(ground_temp_source)
    runner.registerInfo("replaced temporary ground temperature source with vertical ground heat exchanger #{ghx}")

    runner.registerFinalCondition("Replaced existing HVAC system with console water-to-air ground source heat pumps.")
    return true
  end
end

# register the measure to be used by the application
AddConsoleGSHP.new.registerWithApplication
