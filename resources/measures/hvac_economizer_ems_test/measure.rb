# ComStock™, Copyright (c) 2023 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

# *******************************************************************************
# OpenStudio(R), Copyright (c) 2008-2018, Alliance for Sustainable Energy, LLC.
# All rights reserved.
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# (1) Redistributions of source code must retain the above copyright notice,
# this list of conditions and the following disclaimer.
#
# (2) Redistributions in binary form must reproduce the above copyright notice,
# this list of conditions and the following disclaimer in the documentation
# and/or other materials provided with the distribution.
#
# (3) Neither the name of the copyright holder nor the names of any contributors
# may be used to endorse or promote products derived from this software without
# specific prior written permission from the respective party.
#
# (4) Other than as required in clauses (1) and (2), distributions in any form
# of modifications or other derivative works may not use the "OpenStudio"
# trademark, "OS", "os", or any other confusingly similar designation without
# specific prior written permission from Alliance for Sustainable Energy, LLC.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDER(S) AND ANY CONTRIBUTORS
# "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
# THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER(S), ANY CONTRIBUTORS, THE
# UNITED STATES GOVERNMENT, OR THE UNITED STATES DEPARTMENT OF ENERGY, NOR ANY OF
# THEIR EMPLOYEES, BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
# EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT
# OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
# STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
# *******************************************************************************

# dependencies
require 'openstudio-standards'

# start the measure
class HVACEconomizerEMSTest < OpenStudio::Measure::ModelMeasure
  # human readable name
  def name
    return "HVACEconomizer EMS Test"
  end

  # human readable description
  def description
    return "EMS Test"
  end

  # human readable description of modeling approach
  def modeler_description
    return "EMS Test"
  end

  # define the arguments that the user will input
  def arguments(model)
    args = OpenStudio::Measure::OSArgumentVector.new

    # apply/not-apply measure
    apply_measure = OpenStudio::Measure::OSArgument.makeBoolArgument('apply_measure', true)
    apply_measure.setDisplayName('Apply measure?')
    apply_measure.setDescription('')
    apply_measure.setDefaultValue(true)
    args << apply_measure

    return args
  end

  # define what happens when the measure is run
  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)

    if !runner.validateUserArguments(arguments(model), user_arguments)
      return false
    end
    apply_measure = runner.getBoolArgumentValue('apply_measure', user_arguments)

    # for ems output variables
    li_ems_clg_coil_rate = []
    li_ems_sens_econ_status = []
    li_ems_sens_min_flow = []
    li_ems_act_oa_flow = []

    # loop through air loops
    model.getAirLoopHVACs.each do |air_loop_hvac|

      # get OA system
      oa_system = air_loop_hvac.airLoopHVACOutdoorAirSystem
      if oa_system.is_initialized
        oa_system = oa_system.get
      end

      # get economizer from OA controller
      oa_controller = oa_system.getControllerOutdoorAir
      # oa_controller.setName(oa_controller.name.to_s.gsub("-", ""))
      economizer_type = oa_controller.getEconomizerControlType
      next unless economizer_type != 'NoEconomizer'

      # get zones
      zone = air_loop_hvac.thermalZones[0]
      # zone.setName(zone.name.to_s.gsub("-", ""))

      # get main cooling coil from air loop
      # this is used to determine if there is a cooling load on the air loop
      clg_coil=nil
      air_loop_hvac.supplyComponents.each do |component|
        # Get the object type
        obj_type = component.iddObjectType.valueName.to_s
        case obj_type
        when 'OS_Coil_Cooling_DX_SingleSpeed'
          clg_coil = component.to_CoilCoolingDXSingleSpeed.get
        when 'OS_Coil_Cooling_DX_TwoSpeed'
          clg_coil = component.to_CoilCoolingDXTwoSpeed.get
        when 'OS_Coil_Cooling_DX_MultiSpeed'
          clg_coil = component.to_CoilCoolingDXMultiSpeed.get
        when 'OS_Coil_Cooling_DX_VariableSpeed'
          clg_coil = component.to_CoilCoolingDXVariableSpeed.get
        when 'OS_Coil_Cooling_Water'
          clg_coil = component.to_CoilCoolingWater.get
        when 'OS_Coil_Cooling_WaterToAirHeatPumpEquationFit'
          clg_coil = component.to_CoilCoolingWatertoAirHeatPumpEquationFit.get
        when 'OS_AirLoopHVAC_UnitarySystem'
          unitary_sys = component.to_AirLoopHVACUnitarySystem.get
          if unitary_sys.coolingCoil.is_initialized
            clg_coil = unitary_sys.coolingCoil.get
          end
        when 'OS_AirLoopHVAC_UnitaryHeatPump_AirToAir'
          unitary_sys = component.to_AirLoopHVACUnitaryHeatPumpAirToAir.get
          if unitary_sys.coolingCoil.is_initialized
            clg_coil = unitary_sys.coolingCoil.get
          end
        when 'OS_AirLoopHVAC_UnitaryHeatPump_AirToAir_MultiSpeed'
          unitary_sys = component.to_AirLoopHVACUnitaryHeatPumpAirToAirMultiSpeed.get
          if unitary_sys.coolingCoil.is_initialized
            clg_coil = unitary_sys.coolingCoil.get
          end
        when 'OS_AirLoopHVAC_UnitaryHeatCool_VAVChangeoverBypass'
          unitary_sys = component.to_AirLoopHVACUnitaryHeatPumpAirToAirMultiSpeed.get
          if unitary_sys.coolingCoil.is_initialized
            clg_coil = unitary_sys.coolingCoil.get
          end
        end
      end

      # set sensor for zone cooling load from cooling coil cooling rate
      sens_clg_coil_rate = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'Cooling Coil Total Cooling Rate')
      sens_clg_coil_rate.setName("sens_zn_clg_rate_#{zone.name.get.to_s.gsub("-", "")}") 
      sens_clg_coil_rate.setKeyName("#{clg_coil.name.get}")
      # EMS variables are added to lists for export
      li_ems_clg_coil_rate << sens_clg_coil_rate

      # set sensor - Outdoor Air Controller Minimum Mass Flow Rate
      # TODO need to confirm if this variable is reliable
      sens_min_oa_rate = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'Air System Outdoor Air Mechanical Ventilation Requested Mass Flow Rate')
      sens_min_oa_rate.setName("sens_min_oa_flow_#{oa_controller.name.get.to_s.gsub("-", "")}") 
      sens_min_oa_rate.setKeyName("#{air_loop_hvac.name.get}")

      li_ems_sens_min_flow << sens_min_oa_rate

      # set sensor - Air System Outdoor Air Economizer Status
      sens_econ_status = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'Air System Outdoor Air Economizer Status')
      sens_econ_status.setName("sens_econ_status_#{oa_controller.name.get.to_s.gsub("-", "")}") 
      sens_econ_status.setKeyName("#{air_loop_hvac.name.get}")
      li_ems_sens_econ_status << sens_econ_status

      #### Actuators #####
      # set actuator - oa controller air mass flow rate
      act_oa_flow = OpenStudio::Model::EnergyManagementSystemActuator.new(oa_controller,
                                                                          'Outdoor Air Controller', 
                                                                          'Air Mass Flow Rate'
                                                                          )
      act_oa_flow.setName("act_oa_flow_#{air_loop_hvac.name.get.to_s.gsub("-", "")}")
      
      li_ems_act_oa_flow << act_oa_flow

      #### Program #####
      # reset OA to min OA if there is a call for economizer but no cooling load
      prgrm_econ_override = model.getEnergyManagementSystemTrendVariableByName('econ_override')
      unless prgrm_econ_override.is_initialized
        prgrm_econ_override = OpenStudio::Model::EnergyManagementSystemProgram.new(model)
        prgrm_econ_override.setName("#{air_loop_hvac.name.get.to_s.gsub("-", "")}_program")
        prgrm_econ_override_body = <<-EMS
        SET #{act_oa_flow.name} = #{act_oa_flow.name},
        SET sens_zn_clg_rate = #{sens_clg_coil_rate.name},
        SET sens_min_oa_rate = #{sens_min_oa_rate.name},
        SET sens_econ_status = #{sens_econ_status.name},
        IF ((sens_econ_status > 0) && (sens_zn_clg_rate <= 0)), 
          SET #{act_oa_flow.name} = sens_min_oa_rate,
        ELSE,
          SET #{act_oa_flow.name} = Null,
        ENDIF
        EMS
        prgrm_econ_override.setBody(prgrm_econ_override_body)
      end
        programs_at_beginning_of_timestep = OpenStudio::Model::EnergyManagementSystemProgramCallingManager.new(model)
        programs_at_beginning_of_timestep.setName("#{air_loop_hvac.name.get.to_s.gsub("-", "")}_Programs_At_Beginning_Of_Timestep")
        programs_at_beginning_of_timestep.setCallingPoint('InsideHVACSystemIterationLoop')
        programs_at_beginning_of_timestep.addProgram(prgrm_econ_override)

    end

    # ----------------------------------------------------  
    puts("### adding output variables (for debugging)")
    # ----------------------------------------------------  
    ov_eco_status = OpenStudio::Model::OutputVariable.new("debugging_ecostatus",model)
    ov_eco_status.setKeyValue("*")
    ov_eco_status.setReportingFrequency("timestep") 
    ov_eco_status.setVariableName("Air System Outdoor Air Economizer Status")

    ov_oa_fraction = OpenStudio::Model::OutputVariable.new("debugging_ov_oafraction",model)
    ov_oa_fraction.setKeyValue("*")
    ov_oa_fraction.setReportingFrequency("timestep") 
    ov_oa_fraction.setVariableName("Air System Outdoor Air Flow Fraction")

    ov_oa_mdot = OpenStudio::Model::OutputVariable.new("debugging_oamdot",model)
    ov_oa_mdot.setKeyValue("*")
    ov_oa_mdot.setReportingFrequency("timestep") 
    ov_oa_mdot.setVariableName("Air System Outdoor Air Mass Flow Rate")

    ov_oat = OpenStudio::Model::OutputVariable.new("debugging_oat",model)
    ov_oat.setKeyValue("*")
    ov_oat.setReportingFrequency("timestep") 
    ov_oat.setVariableName("Site Outdoor Air Drybulb Temperature")

    ov_coil_cooling = OpenStudio::Model::OutputVariable.new("debugging_cooling",model)
    ov_coil_cooling.setKeyValue("*")
    ov_coil_cooling.setReportingFrequency("timestep") 
    ov_coil_cooling.setVariableName("Cooling Coil Total Cooling Rate")

    # create OutputEnergyManagementSystem object (a 'unique' object) and configure to allow EMS reporting
    output_EMS = model.getOutputEnergyManagementSystem
    output_EMS.setInternalVariableAvailabilityDictionaryReporting('Verbose')
    output_EMS.setEMSRuntimeLanguageDebugOutputLevel('Verbose')
    output_EMS.setActuatorAvailabilityDictionaryReporting('Verbose')

    # make list of available EMS variables
    ems_output_variable_list = []
  
    # li_ems_sens_zn_clg_rate
    li_ems_clg_coil_rate.each do |sensor|
      name = sensor.name
      ems_sens_clg_coil_rate = OpenStudio::Model::EnergyManagementSystemOutputVariable.new(model, sensor)
      ems_sens_clg_coil_rate.setUpdateFrequency('ZoneTimestep')
      ems_sens_clg_coil_rate.setName("#{name}_ems_outvar")
      ems_sens_clg_coil_rate.setUnits('W')
      ems_output_variable_list << ems_sens_clg_coil_rate.name.to_s
    end

    # li_ems_sens_econ_status
    li_ems_sens_econ_status.each do |sensor|
      name = sensor.name
      ems_sens_econ_status = OpenStudio::Model::EnergyManagementSystemOutputVariable.new(model, sensor)
      ems_sens_econ_status.setUpdateFrequency('Timestep')
      ems_sens_econ_status.setName("#{name}_ems_outvar")
      # ems_sens_zn_clg_rate.setUnits('C')
      ems_output_variable_list << ems_sens_econ_status.name.to_s
    end

    # li_ems_sens_min_flow
    li_ems_sens_min_flow.each do |sensor|
      name = sensor.name
      ems_sens_min_flow = OpenStudio::Model::EnergyManagementSystemOutputVariable.new(model, sensor)
      ems_sens_min_flow.setUpdateFrequency('Timestep')
      ems_sens_min_flow.setName("#{name}_ems_outvar")
      ems_sens_min_flow.setUnits('kg/s')
      ems_output_variable_list << ems_sens_min_flow.name.to_s
    end
  
    # li_ems_act_oa_flow
    li_ems_act_oa_flow.each do |act|
      name = act.name
      ems_act_oa_flow = OpenStudio::Model::EnergyManagementSystemOutputVariable.new(model, act)
      ems_act_oa_flow.setUpdateFrequency('Timestep')
      ems_act_oa_flow.setName("#{name}_ems_outvar")
      ems_act_oa_flow.setUnits('kg/s')
      ems_output_variable_list << ems_act_oa_flow.name.to_s
    end
  
    # iterate list to call output variables
    ems_output_variable_list.each do |variable|
      output = OpenStudio::Model::OutputVariable.new(variable,model)
      output.setKeyValue("*")
      output.setReportingFrequency('Timestep')
      #puts "output: #{output}"
    end
    return true
  end
end

# register the measure to be used by the application
HVACEconomizerEMSTest.new.registerWithApplication
