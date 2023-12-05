# insert your copyright here

# see the URL below for information on how to write OpenStudio measures
# http://nrel.github.io/OpenStudio-user-documentation/reference/measure_writing_guide/
require 'openstudio-standards'
require 'csv'

# require all .rb files in resources folder
Dir[File.dirname(__FILE__) + '/resources/*.rb'].each { |file| require file }  

# resource file modules
include Make_Performance_Curves

# start the measure
class AddPackagedGSHP < OpenStudio::Measure::ModelMeasure
  # human readable name
  def name
    # Measure name should be the title case of the class name.
    'add_packaged_gshp'
  end

  # human readable description
  def description
    'Measure replaces existing packaged single-zone RTU system types with ground source heat pump RTUs.'
  end

  # human readable description of modeling approach
  def modeler_description
    'Modeler has option to set backup heat source, prevelence of heat pump oversizing, heat pump oversizing limit, and addition of energy recovery. This measure will work on unitary PSZ systems as well as single-zone, constant air volume air loop PSZ systems.'
  end

  # Define the name and description that will appear in the OpenStudio application
  def name
    'add_packaged_gshp'
  end

  def description
    'This measure replaces packaged single zone systems with a packaged water-to-air ground source heat pump system.'
  end

  def modeler_description
    'This measure identifies all packaged single zone systems in the model and replaces them with a packaged water-to-air ground source heat pump system.'
  end

  # Define the arguments that the user will input
  def arguments(_model)
    args = OpenStudio::Measure::OSArgumentVector.new

    # add heat recovery option
    hr = OpenStudio::Measure::OSArgument.makeBoolArgument('hr', true)
    hr.setDisplayName('Add Energy Recovery?')
    hr.setDefaultValue(false)
    args << hr

    # add dcv option
    dcv = OpenStudio::Measure::OSArgument.makeBoolArgument('dcv', true)
    dcv.setDisplayName('Add Demand Control Ventilation?')
    dcv.setDefaultValue(true)
    args << dcv

    # add economizer option
    econ = OpenStudio::Measure::OSArgument.makeBoolArgument('econ', true)
    econ.setDisplayName('Add Economizer?')
    econ.setDefaultValue(true)
    args << econ

    args
  end

  #### Predefined functions

  # determine if the air loop is residential (checks to see if there is outdoor air system object)
  def air_loop_res?(air_loop_hvac)
    is_res_system = true
    air_loop_hvac.supplyComponents.each do |component|
      obj_type = component.iddObjectType.valueName.to_s
      case obj_type
      when 'OS_AirLoopHVAC_OutdoorAirSystem'
        is_res_system = false
      end
    end
    is_res_system
  end

  # Determine if is evaporative cooler
  def air_loop_evaporative_cooler?(air_loop_hvac)
    is_evap = false
    air_loop_hvac.supplyComponents.each do |component|
      obj_type = component.iddObjectType.valueName.to_s
      case obj_type
      when 'OS_EvaporativeCooler_Direct_ResearchSpecial', 'OS_EvaporativeCooler_Indirect_ResearchSpecial', 'OS_EvaporativeFluidCooler_SingleSpeed', 'OS_EvaporativeFluidCooler_TwoSpeed'
        is_evap = true
      end
    end
    is_evap
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
    is_unitary_system
  end

  # check if air loop uses district energy
  def air_loop_hvac_served_by_district_energy?(air_loop_hvac)
    served_by_district_energy = false
    thermalzones = air_loop_hvac.thermalZones
    district_energy_types = []
    thermalzones.each do |thermalzone|
      zone_fuels = ''
      htg_fuels = thermalzone.heatingFuelTypes.map(&:valueName)
      if htg_fuels.include?('DistrictHeating')
        zone_fuels = 'DistrictHeating'
        district_energy_types << zone_fuels
      end
      clg_fuels = thermalzone.coolingFuelTypes.map(&:valueName)
      if clg_fuels.include?('DistrictCooling')
        zone_fuels += 'DistrictCooling'
        district_energy_types << zone_fuels
      end
    end
    served_by_district_energy = true unless district_energy_types.empty?
    served_by_district_energy
  end
    
  # Define the main method that will be called by the OpenStudio application
  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)

    # build standard to use OS standards methods
    template = 'ComStock 90.1-2019'
    std = Standard.build(template)
    # get climate zone value
    climate_zone = std.model_standards_climate_zone(model)

    # assign user inputs to variables
    dcv = runner.getBoolArgumentValue('dcv', user_arguments)
    econ = runner.getBoolArgumentValue('econ', user_arguments)
    hr = runner.getBoolArgumentValue('hr', user_arguments)

    # check if model has airloops, if not register not applicable
    all_air_loops = model.getAirLoopHVACs
    if all_air_loops.empty?
      runner.registerAsNotApplicable('Model has no air loops, meaning existing HVAC system is not PSZ, PVAV, or VAV and measure is not applicable.')
      return true
    end
    # check if any air loops are served by district energy, if so register not applicable
    all_air_loops.each do |air_loop_hvac|
      if air_loop_hvac_served_by_district_energy?(air_loop_hvac)
        runner.registerAsNotApplicable('Existing building served by district energy, measure is not applicable.')
        return true
      end
    end

    # make list of zone equipment to delete
    equip_to_delete = []
    # if zone has baseboard electric (typically small, storage style space types), skip this zone and do not add GHP here
    zones_to_skip = []
    # check for baseboard electric and add to array of zone equipment to delete
    model.getThermalZones.each do |thermal_zone|
      zones_to_skip << thermal_zone.name.get if thermal_zone.equipment.empty?
      thermal_zone.equipment.each do |equip|
        # dont delete diffusers from PSZs, these will be reused
        next if equip.to_AirTerminalSingleDuctConstantVolumeNoReheat.is_initialized

        if equip.to_ZoneHVACBaseboardConvectiveElectric.is_initialized
          zones_to_skip << thermal_zone.name.get
        else
          equip_to_delete << equip
        end
      end
    end

    # get applicable psz hvac air loops
    psz_air_loops = []
    vav_air_loops = []
    applicable_area_m2 = 0
    all_air_loops.each do |air_loop_hvac|
      # skip units that are not single zone
      if air_loop_hvac.thermalZones.length == 1
        # skip DOAS units; check sizing for all OA and for DOAS in name
        sizing_system = air_loop_hvac.sizingSystem
        if sizing_system.allOutdoorAirinCooling && sizing_system.allOutdoorAirinHeating && (air_loop_res?(air_loop_hvac) == false) && (air_loop_hvac.name.to_s.include?('DOAS') || air_loop_hvac.name.to_s.include?('doas'))
          next
        end

        # skip VAV and PVAV systems and remove the air loop
        if %w[VAV PVAV].any? { |word| air_loop_hvac.name.get.include?(word) }
          vav_air_loops << air_loop_hvac
          # air_loop_hvac.remove
          next
        end
        # skip if residential system
        next if air_loop_res?(air_loop_hvac)
        # skip if system has no outdoor air, also indication of residential system
        next unless air_loop_hvac.airLoopHVACOutdoorAirSystem.is_initialized
        # skip if evaporative cooling systems
        next if air_loop_evaporative_cooler?(air_loop_hvac)

        # skip DOAS units; check sizing for all OA and for DOAS in name
        sizing_system = air_loop_hvac.sizingSystem
        if sizing_system.allOutdoorAirinCooling && sizing_system.allOutdoorAirinHeating && (air_loop_res?(air_loop_hvac) == false) && (air_loop_hvac.name.to_s.include?('DOAS') || air_loop_hvac.name.to_s.include?('doas'))
          next
        end
        # skip if space is not heated and cooled
        unless std.thermal_zone_heated?(air_loop_hvac.thermalZones[0]) && std.thermal_zone_cooled?(air_loop_hvac.thermalZones[0])
          next
        end

        # add applicable air loop to list
        psz_air_loops << air_loop_hvac
        # add area served by air loop
      elsif air_loop_hvac.thermalZones.length > 1
        # look for PVAV and VAV systems
        next unless %w[VAV PVAV].any? { |word| air_loop_hvac.name.get.include?(word) }

        vav_air_loops << air_loop_hvac
        # remove pvav and vav air loops, they will not be reused in the model
        # air_loop_hvac.remove
      end
    end

    # Check if there are any packaged single zone systems in the model
    if (psz_air_loops.size == 0) && (vav_air_loops.size == 0)
      runner.registerAsNotApplicable('Model has no applicable air loops, measure is not applicable.')
      return true
    end

    # remove existing plant loops from model
    plant_loops = model.getPlantLoops
    if plant_loops.size >> 0
      plant_loops.each do |plant_loop|
        # do not delete service water heating loops
        next if ['Service'].any? { |word| plant_loop.name.get.include?(word) }

        runner.registerInfo("Removed existing plant loop #{plant_loop.name}.")
        plant_loop.remove
      end
    end

    cond_loop_setpoint_c = 18.3 # 65F
    preheat_coil_min_temp = 10.0 # 50F

    # add condenser loop to connect heat pumps loops with ground loop
    condenser_loop = OpenStudio::Model::PlantLoop.new(model)
    runner.registerInfo('Condenser Loop added.')
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
    condenser_high_temp_sch.setValue(29.44) # C
    condenser_low_temp_sch = OpenStudio::Model::ScheduleConstant.new(model)
    condenser_low_temp_sch.setName('Condenser Loop Low Temp Schedule')
    condenser_low_temp_sch.setValue(4.44) # C
    condenser_setpoint_manager = OpenStudio::Model::SetpointManagerScheduledDualSetpoint.new(model)
    condenser_setpoint_manager.setName('Condenser Loop Setpoint Manager')
    condenser_setpoint_manager.setHighSetpointSchedule(condenser_high_temp_sch)
    condenser_setpoint_manager.setLowSetpointSchedule(condenser_low_temp_sch)
    condenser_setpoint_manager.addToNode(condenser_loop.supplyOutletNode)

    # Create and add a pump to the loop
    condenser_pump = OpenStudio::Model::PumpVariableSpeed.new(model)
    condenser_pump.setName('Condenser loop circulation pump')
    condenser_pump.setPumpControlType('Intermittent')
    condenser_pump.setRatedPumpHead(44_834.7) # 15 ft for primary pump for a primary-secondary system based on Appendix G; does this need to change?
    condenser_pump.addToNode(condenser_loop.supplyInletNode)

    # Create new loop connecting heat pump and ground heat exchanger.
    # Initially, a PlantLoop:TemperatureSource object will be used.
    # After a GHEDesigner simulation is run the PlantLoop:TemperatureSource
    # object will be replaced with a vertical ground heat exchanger
    # with borehole properties and G-functions per the GHEDesigner output.
    ground_loop = OpenStudio::Model::PlantLoop.new(model)
    runner.registerInfo('Ground Loop added.')
    ground_loop.setName('Ground Loop')
    ground_loop.setMaximumLoopTemperature(100.0)
    ground_loop.setMinimumLoopTemperature(10.0)
    ground_loop.setLoadDistributionScheme('SequentialLoad')
    ground_loop_sizing = ground_loop.sizingPlant
    ground_loop_sizing.setLoopType('Condenser') # is this right?
    ground_loop_sizing.setDesignLoopExitTemperature(18.33) # does this need to change to ~140F?

    # set fluid as 20% propyleneglycol
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
    ground_pump.setRatedPumpHead(44_834.7) # 15 ft for primary pump for a primary-secondary system based on Appendix G; does this need to change?
    ground_pump.addToNode(ground_loop.supplyInletNode)

    # Create a scheduled setpoint manager
    # TODO determine if a schedule that follows the monthly ground temperature
    # would result in significantly different loads
    ground_high_temp_sch = OpenStudio::Model::ScheduleConstant.new(model)
    ground_high_temp_sch.setName('Ground Loop High Temp Schedule')
    ground_high_temp_sch.setValue(24.0) # C
    ground_low_temp_sch = OpenStudio::Model::ScheduleConstant.new(model)
    ground_low_temp_sch.setName('Ground Loop Low Temp Schedule')
    ground_low_temp_sch.setValue(12.78) # C
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

    # get necessary schedules, etc. from unitary system object
    # initialize variables before loop

    unitary_availability_sched = 'tmp'
    control_zone = 'tmp'
    dehumid_type = 'tmp'
    supply_fan_op_sched = 'tmp'
    supply_fan_avail_sched = 'tmp'
    fan_tot_eff = 0.63
    fan_mot_eff = 0.29
    fan_static_pressure = 50.0
    supply_air_flow_m3_per_s = 'tmp'
    orig_clg_coil_gross_cap = nil
    orig_htg_coil_gross_cap = nil

    # Loop through each packaged single zone system and replace it with a water-to-air ground source heat pump system
    psz_air_loops.each do |air_loop_hvac|
      thermal_zone = air_loop_hvac.thermalZones[0]

      hvac_operation_sched = air_loop_hvac.availabilitySchedule

      # for unitary systems
      if air_loop_hvac_unitary_system?(air_loop_hvac)

        # loop through each relevant component.
        # store information needed as variable
        # remove the existing equipment
        air_loop_hvac.supplyComponents.each do |component|
          # convert component to string name
          obj_type = component.iddObjectType.valueName.to_s
          # skip unless component is of relevant type
          next unless %w[Fan Unitary Coil].any? { |word| obj_type.include?(word) }

          # make list of equipment to delete
          equip_to_delete << component

          # get information specifically from unitary system object
          next unless ['Unitary'].any? do |word|
                        obj_type.include?(word)
                      end # TODO: There are more unitary systems types we are not including here

          # get unitary system
          unitary_sys = component.to_AirLoopHVACUnitarySystem.get
          # get availability schedule
          unitary_availability_sched = unitary_sys.availabilitySchedule.get
          # get control zone
          control_zone = unitary_sys.controllingZoneorThermostatLocation.get
          # get dehumidification control type
          dehumid_type = unitary_sys.dehumidificationControlType
          # get supply fan operation schedule
          supply_fan_op_sched = unitary_sys.supplyAirFanOperatingModeSchedule.get
          # get supply fan availability schedule
          supply_fan = unitary_sys.supplyFan.get
          # convert supply fan to appropriate object to access methods
          if supply_fan.to_FanConstantVolume.is_initialized
            supply_fan = supply_fan.to_FanConstantVolume.get
          elsif supply_fan.to_FanOnOff.is_initialized
            supply_fan = supply_fan.to_FanOnOff.get
          elsif supply_fan.to_FanVariableVolume.is_initialized
            supply_fan = supply_fan.to_FanVariableVolume.get
          else
            runner.registerError("Supply fan type for #{air_loop_hvac.name} not supported.")
            return false
          end
          # get the availability schedule
          supply_fan_avail_sched = supply_fan.availabilitySchedule
          if supply_fan_avail_sched.to_ScheduleConstant.is_initialized
            supply_fan_avail_sched = supply_fan_avail_sched.to_ScheduleConstant.get
          elsif supply_fan_avail_sched.to_ScheduleRuleset.is_initialized
            supply_fan_avail_sched = supply_fan_avail_sched.to_ScheduleConstant.get
          else
            runner.registerError("Supply fan availability schedule type for #{supply_fan.name} not supported.")
            return false
          end
          # TODO: figure out if fan and coils should be hardsized or autosized; if autosized, can probably delete this section of code
          # get supply fan motor efficiency
          fan_tot_eff = supply_fan.fanTotalEfficiency
          # get supply motor efficiency
          fan_mot_eff = supply_fan.motorEfficiency
          # get supply fan static pressure
          fan_static_pressure = supply_fan.pressureRise
          # get previous cooling coil capacity
          # orig_clg_coil = unitary_sys.coolingCoil.get
          # if orig_clg_coil.to_CoilCoolingDXSingleSpeed.is_initialized
          #   orig_clg_coil = orig_clg_coil.to_CoilCoolingDXSingleSpeed.get
          #   puts "coil object class = #{orig_clg_coil.class}"
          #   # get either autosized or specified cooling capacity
          #   if orig_clg_coil.isRatedTotalCoolingCapacityAutosized == true
          #     puts "coil capacity = #{orig_clg_coil.ratedTotalCoolingCapacity}"
          #     orig_clg_coil_gross_cap = orig_clg_coil.autosizedRatedTotalCoolingCapacity.get
          #   elsif orig_clg_coil.ratedTotalCoolingCapacity.is_initialized
          #     orig_clg_coil_gross_cap = orig_clg_coil.ratedTotalCoolingCapacity.to_f
          #   else
          #     runner.registerError("Original cooling coil capacity for #{air_loop_hvac.name} not found. Either it was not directly specified, or sizing run data is not available.")
          #   end
          # end
          # get original heating coil capacity
          # orig_htg_coil = unitary_sys.heatingCoil.get
          # # get coil object if electric resistance
          # if orig_htg_coil.to_CoilHeatingElectric.is_initialized
          #   orig_htg_coil = orig_htg_coil.to_CoilHeatingElectric.get
          # # get coil object if gas
          # elsif orig_htg_coil.to_CoilHeatingGas.is_initialized
          #   orig_htg_coil = orig_htg_coil.to_CoilHeatingGas.get
          # # get coil object if water
          # elsif orig_htg_coil.to_CoilHeatingWater.is_initialized
          #   orig_htg_coil = orig_htg_coil.to_CoilHeatingWater.get
          # # get coil object if water
          # elsif orig_htg_coil.to_CoilHeatingDXSingleSpeed.is_initialized
          #   orig_htg_coil = orig_htg_coil.to_CoilHeatingDXSingleSpeed.get
          # else
          #   runner.registerError("Heating coil for #{air_loop_hvac.name} is of an unsupported type. This measure currently supports CoilHeatingElectric and CoilHeatingGas object types.")
          # end
          # # get either autosized or specified capacity
          # if orig_htg_coil.isNominalCapacityAutosized == true
          #   orig_htg_coil_gross_cap = orig_htg_coil.autosizedNominalCapacity.get
          # elsif orig_htg_coil.nominalCapacity.is_initialized
          #   orig_htg_coil_gross_cap = orig_htg_coil.nominalCapacity.to_f
          # else
          #   runner.registerError("Original heating coil capacity for #{air_loop_hvac.name} not found. Either it was not directly specified, or sizing run data is not available.")
          # end
        end

      # get non-unitary system objects.
      else
        # loop through components
        air_loop_hvac.supplyComponents.each do |component|
          # convert component to string name
          obj_type = component.iddObjectType.valueName.to_s
          # skip unless component is of relevant type
          next unless %w[Fan Unitary Coil].any? { |word| obj_type.include?(word) }

          # make list of equipment to delete
          equip_to_delete << component

          # check for fan
          next unless ['Fan'].any? { |word| obj_type.include?(word) }

          supply_fan = component
          if supply_fan.to_FanConstantVolume.is_initialized
            supply_fan = supply_fan.to_FanConstantVolume.get
          elsif supply_fan.to_FanOnOff.is_initialized
            supply_fan = supply_fan.to_FanOnOff.get
          elsif supply_fan.to_FanVariableVolume.is_initialized
            supply_fan = supply_fan.to_FanVariableVolume.get
          else
            runner.registerError("Supply fan type for #{air_loop_hvac.name} not supported.")
            return false
          end
          # get the availability schedule
          supply_fan_avail_sched = supply_fan.availabilitySchedule
          if supply_fan_avail_sched.to_ScheduleConstant.is_initialized
            supply_fan_avail_sched = supply_fan_avail_sched.to_ScheduleConstant.get
          elsif supply_fan_avail_sched.to_ScheduleRuleset.is_initialized
            supply_fan_avail_sched = supply_fan_avail_sched.to_ScheduleConstant.get
          else
            runner.registerError("Supply fan availability schedule type for #{supply_fan.name} not supported.")
            return false
          end
          # get supply fan motor efficiency
          fan_tot_eff = supply_fan.fanTotalEfficiency
          # get supply motor efficiency
          fan_mot_eff = supply_fan.motorEfficiency
          # get supply fan static pressure
          fan_static_pressure = supply_fan.pressureRise
          # set unitary supply fan operating schedule equal to system schedule for non-unitary systems
          supply_fan_op_sched = hvac_operation_sched
          # set dehumidification type
          dehumid_type = 'None'
          # set control zone to the thermal zone. This will be used in new unitary system object
          control_zone = air_loop_hvac.thermalZones[0]
          # set unitary availability schedule to be always on. This will be used in new unitary system object.
          unitary_availability_sched = model.alwaysOnDiscreteSchedule
        end
      end

      # # Get the min OA flow rate from the OA; this is used below
      # oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem.get
      # controller_oa = oa_system.getControllerOutdoorAir
      # oa_flow_m3_per_s = nil
      # if controller_oa.minimumOutdoorAirFlowRate.is_initialized
      # 	oa_flow_m3_per_s = controller_oa.minimumOutdoorAirFlowRate.get
      # elsif controller_oa.autosizedMinimumOutdoorAirFlowRate.is_initialized
      # 	oa_flow_m3_per_s = controller_oa.autosizedMinimumOutdoorAirFlowRate.get
      # else
      # 	runner.registerError("No outdoor air sizing information was found for #{controller_oa.name}, which is required for setting ERV wheel power consumption.")
      # 	return false
      # end
    end

    equip_to_delete.each(&:remove)

    # remove old VAV air loops; this must be done after removing zone equipment or it will cause segmentation fault
    vav_air_loops.each do |vav_air_loop|
      vav_air_loop.remove
    end

    # loop through thermal zones and add
    model.getThermalZones.each do |thermal_zone|
      # skip if zone has baseboards and should not get a GHP
      next if zones_to_skip.include? thermal_zone.name.get

      # set always on schedule; this will be used in other object definitions
      always_on = model.alwaysOnDiscreteSchedule
      supply_fan_avail_sched = model.alwaysOnDiscreteSchedule
      fan_location = 'DrawThrough'

      if thermal_zone.airLoopHVAC.is_initialized
        air_loop_hvac = thermal_zone.airLoopHVAC.get


      else
        # create new air loop for unitary system
        air_loop_hvac = OpenStudio::Model::AirLoopHVAC.new(model)
        air_loop_hvac.setName("#{thermal_zone.name} Air Loop")
        air_loop_sizing = air_loop_hvac.sizingSystem

        # zone sizing
        # adjusted zone design temperatures for ptac
        dsgn_temps = std.standard_design_sizing_temperatures
        dsgn_temps['zn_htg_dsgn_sup_air_temp_f'] = 122.0
        dsgn_temps['zn_htg_dsgn_sup_air_temp_c'] =
          OpenStudio.convert(dsgn_temps['zn_htg_dsgn_sup_air_temp_f'], 'F', 'C').get
        dsgn_temps['zn_clg_dsgn_sup_air_temp_f'] = 57.0
        dsgn_temps['zn_clg_dsgn_sup_air_temp_c'] =
          OpenStudio.convert(dsgn_temps['zn_clg_dsgn_sup_air_temp_f'], 'F', 'C').get
        sizing_zone = thermal_zone.sizingZone
        sizing_zone.setZoneCoolingDesignSupplyAirTemperature(dsgn_temps['zn_clg_dsgn_sup_air_temp_c'])
        sizing_zone.setZoneHeatingDesignSupplyAirTemperature(dsgn_temps['zn_htg_dsgn_sup_air_temp_c'])
        sizing_zone.setZoneCoolingDesignSupplyAirHumidityRatio(0.008)
        sizing_zone.setZoneHeatingDesignSupplyAirHumidityRatio(0.008)

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
      end

      # add new single speed cooling coil
      new_cooling_coil = OpenStudio::Model::CoilCoolingWaterToAirHeatPumpEquationFit.new(model)
      new_cooling_coil.setName("#{air_loop_hvac.name} Heat Pump Cooling Coil")

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
      new_heating_coil.setName("#{air_loop_hvac.name} Heat Pump Heating Coil")

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

      # add supply fan
      fan = OpenStudio::Model::FanConstantVolume.new(model)
      fan.setName("#{air_loop_hvac.name} Fan")
      fan.setFanEfficiency(fan_tot_eff) # from PNNL
      fan.setPressureRise(fan_static_pressure)
      fan.setMotorEfficiency(fan_mot_eff) unless fan_mot_eff.nil?

      # Create a new water-to-air ground source heat pump system
      unitary_system = OpenStudio::Model::AirLoopHVACUnitarySystem.new(model)
      unitary_system.setControlType('Setpoint')
      unitary_system.setCoolingCoil(new_cooling_coil)
      unitary_system.setHeatingCoil(new_heating_coil)
      unitary_system.setControllingZoneorThermostatLocation(thermal_zone)
      unitary_system.setSupplyFan(fan)
      unitary_system.setFanPlacement(fan_location)
      unitary_system.setSupplyAirFanOperatingModeSchedule(model.alwaysOnDiscreteSchedule)
      unitary_system.setMaximumOutdoorDryBulbTemperatureforSupplementalHeaterOperation(OpenStudio.convert(40.0, 'F',
                                                                                                          'C').get)
      unitary_system.setName("#{air_loop_hvac.name} Unitary HP")
      unitary_system.setMaximumSupplyAirTemperature(40.0)
      if model.version < OpenStudio::VersionString.new('3.7.0')
        unitary_system.setSupplyAirFlowRateMethodDuringCoolingOperation('SupplyAirFlowRate')
        unitary_system.setSupplyAirFlowRateMethodDuringHeatingOperation('SupplyAirFlowRate')
        unitary_system.setSupplyAirFlowRateMethodWhenNoCoolingorHeatingisRequired('SupplyAirFlowRate')
      else
        unitary_system.autosizeSupplyAirFlowRateDuringCoolingOperation
        unitary_system.autosizeSupplyAirFlowRateDuringHeatingOperation
        unitary_system.autosizeSupplyAirFlowRateWhenNoCoolingorHeatingisRequired
      end
      unitary_system.setSupplyAirFlowRateMethodWhenNoCoolingorHeatingisRequired('SupplyAirFlowRate')
      unitary_system.addToNode(air_loop_hvac.supplyOutletNode)

      # create a scheduled setpoint manager
      hp_setpoint_manager = OpenStudio::Model::SetpointManagerSingleZoneReheat.new(model)
      hp_setpoint_manager.setName('HP Supply Temp Setpoint Manager')
      hp_setpoint_manager.setMinimumSupplyAirTemperature(12.78)
      hp_setpoint_manager.setMaximumSupplyAirTemperature(50.0)
      hp_setpoint_manager.addToNode(air_loop_hvac.supplyOutletNode)

      # add electric preheat coil to OA system to temper ventilation air
      preheat_coil = OpenStudio::Model::CoilHeatingElectric.new(model)
      preheat_coil.setName('Electric Preheat Coil')
      preheat_coil.setEfficiency(0.95)

      # get inlet node of unitary system to place preheat coil
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

      # get outlet node of preheat coil to place setpoint manager
      preheat_sm_location = preheat_coil.outletModelObject.get.to_Node.get
      preheat_coil_setpoint_manager.addToNode(preheat_sm_location)

      # # Set the efficiency of the heat pump system
      # heat_pump.setRatedCoolingCOP(4.0)
      # heat_pump.setRatedHeatingCoefficientofPerformance(4.0)

      # Add the thermal zone to the new heat pump system
      # heat_pump.addToThermalZone(thermal_zone)

      # Remove the packaged single zone system
      # air_loop_hvac.remove

      # add dcv to air loop if dcv flag is true

      if dcv == true
        oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem.get
        controller_oa = oa_system.getControllerOutdoorAir
        controller_mv = controller_oa.controllerMechanicalVentilation
        controller_mv.setDemandControlledVentilation(true)
      end

      # add economizer
      if econ == true
        # set parameters
        oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem.get
        controller_oa = oa_system.getControllerOutdoorAir
        # econ_type = std.model_economizer_type(model, climate_zone)
        # set economizer type
        controller_oa.setEconomizerControlType('DifferentialEnthalpy')
        # set drybulb temperature limit; per 90.1-2013, this is constant 75F for all climates
        drybulb_limit_f = 75
        drybulb_limit_c = OpenStudio.convert(drybulb_limit_f, 'F', 'C').get
        controller_oa.setEconomizerMaximumLimitDryBulbTemperature(drybulb_limit_c)
        # set lockout for integrated heating
        controller_oa.setLockoutType('LockoutWithHeating')
      end

      # make sure existing economizer is integrated or it wont work with multispeed coil
      oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem.get
      controller_oa = oa_system.getControllerOutdoorAir
      controller_oa.setLockoutType('LockoutWithHeating') unless controller_oa.getEconomizerControlType == 'NoEconomizer'

      # Energy recovery
      # check for ERV, and get components
      # ERV components will be removed and replaced if ERV flag was selected
      # If ERV flag was not selected, ERV equipment will remain in place as-is
      erv_components = []
      air_loop_hvac.oaComponents.each do |component|
        component_name = component.name.to_s
        next if component_name.include? 'Node'

        if component_name.include? 'ERV'
          erv_components << component
          erv_components = erv_components.uniq
        end
      end

      # add energy recovery if specified
      next unless hr == true

      # if there was not previosuly an ERV, add 0.5" (124.42 pascals) static to supply fan
      fan.setPressureRise(fan_static_pressure + 124.42) if erv_components.empty?
      # remove existing ERV; these will be replaced with new ERV equipment
      erv_components.each(&:remove)
      # get oa system
      oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem.get

      # Get the min OA flow rate from the OA; this is used below
      oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem.get
      controller_oa = oa_system.getControllerOutdoorAir
      oa_flow_m3_per_s = nil
      if controller_oa.minimumOutdoorAirFlowRate.is_initialized
        oa_flow_m3_per_s = controller_oa.minimumOutdoorAirFlowRate.get
      elsif controller_oa.autosizedMinimumOutdoorAirFlowRate.is_initialized
        oa_flow_m3_per_s = controller_oa.autosizedMinimumOutdoorAirFlowRate.get
      else
        runner.registerWarning("No outdoor air sizing information was found for #{controller_oa.name}, which is required for setting ERV wheel power consumption.")
        return false
      end

      # add new HR system
      new_hr = OpenStudio::Model::HeatExchangerAirToAirSensibleAndLatent.new(model)
      # update parameters
      new_hr.addToNode(oa_system.outboardOANode.get)
      new_hr.setAvailabilitySchedule(always_on)
      new_hr.setEconomizerLockout(true)
      new_hr.setFrostControlType('ExhaustOnly')
      new_hr.setThresholdTemperature(0) # 32F, from Daikin
      new_hr.setInitialDefrostTimeFraction(0.083) # 5 minutes every 60 minutes, from Daikin
      new_hr.setRateofDefrostTimeFractionIncrease(0.024) # from E+ recommended values
      new_hr.setHeatExchangerType('Rotary')
      new_hr.setName("#{air_loop_hvac.name} ERV")
      # set wheel power consumption if OA flow rate is available, else autosize; from DOE prototypes which exceed 90.1
      if oa_flow_m3_per_s.empty?
      else
        default_fan_efficiency = 0.5
        power = (oa_flow_m3_per_s * 212.5 / default_fan_efficiency) + (oa_flow_m3_per_s * 0.9 * 162.5 / default_fan_efficiency) + 50
        new_hr.setNominalElectricPower(power)
      end
      # set efficiencies; from DOE prototypes which exceed 90.1
      new_hr.setSupplyAirOutletTemperatureControl(false)
      new_hr.setSensibleEffectivenessat100HeatingAirFlow(0.76)
      new_hr.setSensibleEffectivenessat75HeatingAirFlow(0.81)
      new_hr.setLatentEffectivenessat100HeatingAirFlow(0.68)
      new_hr.setLatentEffectivenessat75HeatingAirFlow(0.73)
      new_hr.setSensibleEffectivenessat100CoolingAirFlow(0.76)
      new_hr.setSensibleEffectivenessat75CoolingAirFlow(0.81)
      new_hr.setLatentEffectivenessat100CoolingAirFlow(0.68)
      new_hr.setLatentEffectivenessat75CoolingAirFlow(0.73)
    end

    # do sizing run to get coil capacities to scale coil performance data
    if std.model_run_sizing_run(model, "#{Dir.pwd}/coil_curving_scaling_SR") == false
    	runner.registerError("Sizing runto scale coil performance data failed, cannot hard-size model.")
    	# puts("Sizing run to scale coil performance data failed, cannot hard-size model.")
    	# puts("directory: #{Dir.pwd}/CoilCurveScalingSR")
    	return false
    end

    #apply sizing values
    model.applySizingValues

    # scale coil performance data and assign lookup tables
    model.getAirLoopHVACUnitarySystems.each do |unitary_sys|
    	# puts "*************************************"
    	# puts "*************************************"
    	# puts "Assigning performance curve data for unitary system (#{unitary_sys.name})"
    	# get cooling coil
    	# get heating coil
    	# get fan
    	heating_capacity = 0
    	heating_air_flow = 0
    	heating_water_flow = 0
    	cooling_capacity = 0
    	cooling_air_flow = 0
    	cooling_water_flow = 0
    	fan_air_flow = 0

    	# heating coil
    	if unitary_sys.heatingCoil.is_initialized
    		if unitary_sys.heatingCoil.get.to_CoilHeatingWaterToAirHeatPumpEquationFit.is_initialized
    			coil = unitary_sys.heatingCoil.get.to_CoilHeatingWaterToAirHeatPumpEquationFit.get
    			# capacity
    			if coil.ratedHeatingCapacity.is_initialized
    				heating_capacity = coil.ratedHeatingCapacity.get
    			else
    				runner.registerError("Unable to retrieve reference capacity for coil (#{coil.name})")
    				return false
    			end
    			# air flow
    			if coil.ratedAirFlowRate.is_initialized
    				heating_air_flow = coil.ratedAirFlowRate.get
    			else
    				runner.registerError("Unable to retrieve reference air flow for coil (#{coil.name})")
    				return false
    			end
    			# water flow
    			if coil.ratedWaterFlowRate.is_initialized
    				heating_water_flow = coil.ratedWaterFlowRate.get
    			else
    				runner.registerError("Unable to retrieve reference water flow for coil (#{coil.name})")
    				return false
    			end
    			# add performance data
    			add_lookup_performance_data(model, coil, "packaged_gshp", "Trane_10_ton_GWSC120E", heating_air_flow, heating_water_flow, runner)
    		else
    			runner.registerError("Expecting heating coil of type CoilHeatingWaterToAirHeatPumpEquationFits for (#{unitary_sys.name})")
    			return false
    		end
    	else
    		runner.registerError("Could not find heating coil for unitary system (#{unitary_sys.name})")
    		return false
    	end

    	# cooling coil
    	if unitary_sys.coolingCoil.is_initialized
    		if unitary_sys.coolingCoil.get.to_CoilCoolingWaterToAirHeatPumpEquationFit.is_initialized
    			coil = unitary_sys.coolingCoil.get.to_CoilCoolingWaterToAirHeatPumpEquationFit.get
    			# capacity
    			if coil.ratedTotalCoolingCapacity.is_initialized
    				cooling_capacity = coil.ratedTotalCoolingCapacity.get
    			else
    				runner.registerError("Unable to retrieve reference capacity for coil (#{coil.name})")
    				return false
    			end
    			# air flow
    			if coil.ratedAirFlowRate.is_initialized
    				cooling_air_flow = coil.ratedAirFlowRate.get
    			else
    				runner.registerError("Unable to retrieve reference air flow for coil (#{coil.name})")
    				return false
    			end
    			# water flow
    			if coil.ratedWaterFlowRate.is_initialized
    				cooling_water_flow = coil.ratedWaterFlowRate.get
    			else
    				runner.registerError("Unable to retrieve reference water flow for coil (#{coil.name})")
    				return false
    			end
    			# add performance data
    			add_lookup_performance_data(model, coil, "packaged_gshp", "Trane_10_ton_GWSC120E", cooling_air_flow, cooling_water_flow, runner)
    		else
    			runner.registerError("Expecting cooling coil of type CoilCoolingWaterToAirHeatPumpEquationFits for (#{unitary_sys.name})")
    			return false
    		end
    	else
    		runner.registerError("Could not find cooling coil for unitary system (#{unitary_sys.name})")
    		return false
    	end

    	# fan
    	if unitary_sys.supplyFan.is_initialized
    		if unitary_sys.supplyFan.get.to_FanConstantVolume.is_initialized
    			fan = unitary_sys.supplyFan.get.to_FanConstantVolume.get
    			# air flow
    			if fan.maximumFlowRate.is_initialized
    				fan_air_flow = fan.maximumFlowRate.get
    			else
    				runner.registerError("Unable to retrieve maximum air flow for fan (#{fan.name})")
    				return false
    			end
    		else
    			runner.registerError("Expecting fan of type FanConstantVolume for (#{unitary_sys.name})")
    			return false
    		end
    	else
    		runner.registerError("Could not find fan for unitary system (#{unitary_sys.name})")
    		return false
    	end
    	# puts "*************************************"
    	# puts "Heating capacity = #{heating_capacity.round(2)} W"
    	# puts "Cooling capacity = #{cooling_capacity.round(2)} W"
    	# puts "Heating air flow = #{heating_air_flow.round(5)} m3/s"
    	# puts "Cooling air flow = #{cooling_air_flow.round(5)} m3/s"
    	# puts "Fan air flow = #{fan_air_flow.round(5)} m3/s"
    	# puts "Heating water flow = #{heating_water_flow.round(5)} m3/s"
    	# puts "Cooling water flow = #{cooling_water_flow.round(5)} m3/s"
    end

    # unless model.getHeatPumpPlantLoopEIRCoolings.empty?
    #   puts "***********************************"
    #   puts "***********************************"
    #   puts "Reporting HeatPumpPlantLoopEIRCooling objects"
    #   puts "***********************************"
    #   model.getHeatPumpPlantLoopEIRCoolings.each do |hp|
    #     puts hp
    #   end
    # end


    # unless model.getHeatPumpPlantLoopEIRHeatings.empty?
    #   puts "***********************************"
    #   puts "***********************************"
    #   puts "Reporting HeatPumpPlantLoopEIRHeating objects"
    #   puts "***********************************"
    #   model.getHeatPumpPlantLoopEIRHeatings.each do |hp|
    #     puts hp
    #   end
    # end

    # unless model.getCoilCoolingWaterToAirHeatPumpEquationFits.empty?
    #   puts "***********************************"
    #   puts "***********************************"
    #   puts "Reporting CoilCoolingWaterToAirHeatPumpEquationFit objects"
    #   puts "***********************************"
    #   model.getCoilCoolingWaterToAirHeatPumpEquationFits.each do |coil|
    #     puts coil
    #   end
    # end

    # unless model.getCoilHeatingWaterToAirHeatPumpEquationFits.empty?
    #   puts "***********************************"
    #   puts "***********************************"
    #   puts "Reporting CoilHeatingWaterToAirHeatPumpEquationFit objects"
    #   puts "***********************************"
    #   model.getCoilHeatingWaterToAirHeatPumpEquationFits.each do |coil|
    #     puts coil
    #   end
    # end

    # unless model.getTableLookups.empty?
    #   puts "***********************************"
    #   puts "***********************************"
    #   puts "Reporting TableLookup objects"
    #   puts "***********************************"
    #   model.getTableLookups.each do |table|
    #     puts table
    #   end
    # end

    # unless model.getTableIndependentVariables.empty?
    #   puts "***********************************"
    #   puts "***********************************"
    #   puts "Reporting TableIndependentVariable objects"
    #   puts "***********************************"
    #   model.getTableIndependentVariables.each do |ind_var|
    #     puts ind_var
    #   end
    # end

    # add output variable for GHEDesigner
    reporting_frequency = 'Hourly'
    outputVariable = OpenStudio::Model::OutputVariable.new('Plant Temperature Source Component Heat Transfer Rate',
                                                           model)
    outputVariable.setReportingFrequency(reporting_frequency)
    runner.registerInfo("Adding output variable for 'Plant Temperature Source Component Heat Transfer Rate' reporting at the hourly timestep.")

    # retrieve or perform annual run to get hourly thermal loads
    ann_loads_run_dir = "#{Dir.pwd}/AnnualGHELoadsRun"
    ann_loads_sql_path = "#{ann_loads_run_dir}/run/eplusout.sql"
    if File.exist?(ann_loads_sql_path)
      runner.registerInfo("Reloading sql file from previous run.")
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
      runner.registerError('Model did not have an sql file; cannot get loads for ground heat exchanger.')
      return false
    end
    sql = model.sqlFile.get

    # get weather file run period (as opposed to design day run period)
    ann_env_pd = nil
    sql.availableEnvPeriods.each do |env_pd|
      env_type = sql.environmentType(env_pd)
      if env_type.is_initialized && (env_type.get == OpenStudio::EnvironmentType.new('WeatherRunPeriod'))
        ann_env_pd = env_pd
      end
    end

    # add timeseries ground loads to array
    ground_loads_ts = sql.timeSeries(ann_env_pd, 'Hourly', 'Plant Temperature Source Component Heat Transfer Rate','GROUND LOOP TEMPERATURE SOURCE (GROUND HEAT EXCHANGER PLACEHOLDER)')              
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
    FileUtils.mkdir_p(ghedesigner_run_dir) unless File.exist?(ghedesigner_run_dir)

    # Make json input file for GHEDesigner
    borefield_defaults_json_path = "#{File.dirname(__FILE__)}/resources/borefield_defaults.json"
    borefield_defaults = JSON.parse(File.read(borefield_defaults_json_path))

    # get soil properties from building additional properties and set them in json file
    building = model.getBuilding
    soil_conductivity = building.additionalProperties.getFeature('Soil Conductivity', soil_conductivity)
    undisturbed_ground_temp = building.additionalProperties.getFeature('Undisturbed Ground Temperature', undisturbed_ground_temp)
    borefield_defaults[:soil][:conductivity] = soil_conductivity
    borefield_defaults[:soil][:undisturbed_temp] = undisturbed_ground_temp

    borefield_defaults['loads'] = {}
    borefield_defaults['loads']['ground_loads'] = ground_loads
    ghe_in_path = "#{ghedesigner_run_dir}/ghedesigner_input.json"
    File.write(ghe_in_path, JSON.pretty_generate(borefield_defaults))
    runner.registerInfo('GHEDesigner input JSON file created.')

    # Make system call to run GHEDesigner
    start_time = Time.new
    # TODO: remove conda activate andrew
    # require 'open3'
    # require 'etc'

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
    runner.registerInfo("Number of boreholes = #{number_of_boreholes}")

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
    soil_volumetric_heat_capacity_j_per_m3_k = OpenStudio.convert(soil_volumetric_heat_capacity_kj_per_m3_k, 'kJ/m^3*K',
                                                                  'J/m^3*K').get

    throw 'Unexpected units' unless ghe_sys['soil_undisturbed_ground_temp']['units'] == 'C'
    soil_undisturbed_ground_temp_c = ghe_sys['soil_undisturbed_ground_temp']['value']

    # TODO: remove W/mK once https://github.com/BETSRG/GHEDesigner/issues/76 is fixed
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
    runner.registerInfo("Replaced temporary ground temperature source with vertical ground heat exchanger #{ghx}.")

    runner.registerFinalCondition("Replaced #{psz_air_loops.size} packaged single zone RTUs  and #{vav_air_loops.size} VAVs with packaged water-to-air ground source heat pumps.")
    true
  end
end

# register the measure to be used by the application
AddPackagedGSHP.new.registerWithApplication
