# *******************************************************************************
# OpenStudio(R), Copyright (c) 2008-2021, Alliance for Sustainable Energy, LLC.
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

# Measure distributed under NREL Copyright terms, see LICENSE.md file.

# Author: Amy Allen, Marley Praprost, Andrew Parker
# Date: Nov 2022 - Dec 2022

# References:
# EnergyPlus InputOutput Reference, Sections:
# https://www.nrcan.gc.ca/sites/nrcan/files/canmetenergy/pdf/ASHP%20Sizing%20and%20Selection%20Guide%20(EN).pdf

# start the measure
class HVACHydronicGSHP < OpenStudio::Measure::ModelMeasure
  require 'openstudio-standards'
  require 'json'
  require 'open3'
  require 'csv'
  require 'time'

  # human readable name
  def name
    # Measure name should be the title case of the class name.
    'Replace Boiler and Chiller with Hydronic GSHP'
  end

  # human readable description
  def description
    'This measure replaces an exising natural gas boiler with a water source heat pump. An electric resister element or the existing boiler could be used as a back up heater.'\
    'The heat pump could be sized to handle the entire heating load or a percentage of the heating load with a back up system handling the rest. '
  end

  # human readable description of modeling approach
  def modeler_description
    'This measure replaces an exising natural gas boiler with a water source heat pump. An electric resister element or the existing boiler could be used as a back up heater.'\
            'The heat pump could be sized to handle the entire heating load or a percentage of the heating load with a back up system handling the rest.'
  end

  # define the arguments that the user will input
  def arguments(model)
    args = OpenStudio::Measure::OSArgumentVector.new

    # Create argument for keeping the hot water loop temperature setpoint
    keep_setpoint = OpenStudio::Measure::OSArgument.makeBoolArgument('keep_setpoint', true)
    keep_setpoint.setDisplayName('Keep existing hot water loop setpoint?')
    keep_setpoint.setDescription('')
    keep_setpoint.setDefaultValue(false)
    args << keep_setpoint

    # Create argument to modify the hot water loop temperature setpoint
    hw_setpoint_F = OpenStudio::Measure::OSArgument.makeDoubleArgument('hw_setpoint_F', true)
    hw_setpoint_F.setDisplayName('Hot water setpoint')
    hw_setpoint_F.setUnits('F')
    hw_setpoint_F.setDescription('Applicable only if user chooses to change the existing hot water setpoint')
    hw_setpoint_F.setDefaultValue(140)
    args << hw_setpoint_F


    chw_setpoint_F = OpenStudio::Measure::OSArgument.makeDoubleArgument('chw_setpoint_F', true)
    chw_setpoint_F.setDisplayName('Chilled water setpoint')
    chw_setpoint_F.setUnits('F')
    chw_setpoint_F.setDescription('Chilled water temperature setpoint')
    chw_setpoint_F.setDefaultValue(44)
    args << chw_setpoint_F

    # Create argument for re-sizing heating coils
    autosize_hc = OpenStudio::Measure::OSArgument.makeBoolArgument('autosize_hc', true)
    autosize_hc.setDisplayName('Autosize heating coils?')
    autosize_hc.setDescription('Applicable only if user chooses to change the hot water setpoint')
    autosize_hc.setDefaultValue(true)
    args << autosize_hc


    # Max design heat pump capacity at the design condition.
    # Default is 1500MBH (439kW) based on Trane Ascend air-to-water heat pump series
    hp_des_cap_htg = OpenStudio::Measure::OSArgument.makeDoubleArgument('hp_des_cap_htg', true)
    hp_des_cap_htg.setDisplayName('Rated capacity per heating heat pump--maximum')
    hp_des_cap_htg.setUnits('kW')
    hp_des_cap_htg.setDescription('Rated capacity per heat pump used for heating')
    hp_des_cap_htg.setDefaultValue(40.0) # TODO: change this for GTHP
    args << hp_des_cap_htg


    hp_des_cap_clg = OpenStudio::Measure::OSArgument.makeDoubleArgument('hp_des_cap_clg', true)
    hp_des_cap_clg.setDisplayName('Rated capacity per cooling heat pump--maximum')
    hp_des_cap_clg.setUnits('kW')
    hp_des_cap_clg.setDescription('Rated capacity per heat pump used for cooling')
    hp_des_cap_clg.setDefaultValue(40.0) # TODO: change this for GTHP
    args << hp_des_cap_clg

    # create argument for heat pump rated COP
    cop = OpenStudio::Measure::OSArgument.makeDoubleArgument('cop', true)
    cop.setDisplayName('Set heat pump rated COP (heating)')
    cop.setDescription('Applicable if Custom Performance Data is selected')
    cop.setDefaultValue(2.85)
    args << cop

    args
  end

  # method to convert csv value to float
  def convert_to_float(value)
    # check if value is empty
    if value.to_s.empty?
      # value is empty; return nil
      nil
    elsif value.to_f != value
      # elsif not value.to_f.to_s.include? value.to_s
      # value is not a number; return nil
      nil
    else
      # value is a number; convert to float
      value.to_f
    end
  end

  def read_performance_curve_data(data_path, runner)
    if data_path.empty?
      runner.registerError("Invalid path (#{data_path}) for performance curve data")
      return false
    else
      csv_data = CSV.read(data_path, converters: :numeric)
      column_data = csv_data.transpose
      curve_data = {}
      # CoilCoolingWaterToAirHeatPumpEquationFit and CoilHeatingWaterToAirHeatPumpEquationFit
      curve_data['db_data'] = []
      curve_data['wb_data'] = []
      curve_data['ewt_data'] = []
      curve_data['vdot_air_data'] = []
      curve_data['vdot_water_data'] = []
      curve_data['tot_clg_cap_data'] = []
      curve_data['sen_clg_cap_data'] = []
      curve_data['clg_pow_data'] = []
      curve_data['htg_cap_data'] = []
      curve_data['htg_pow_data'] = []
      # CoilCoolingWaterToAirHeatPumpEquationFit and CoilHeatingWaterToAirHeatPumpEquationFit
      curve_data['load_lwt_data'] = []
      curve_data['source_ewt_data'] = []
      curve_data['plant_clg_cap_data'] = []
      curve_data['plant_clg_eir_data'] = []
      curve_data['plant_htg_cap_data'] = []
      curve_data['plant_htg_eir_data'] = []

      # loop through data columns to fill arrays
      for i in 0..(column_data.length - 1)
        # collect db_data
        if column_data[i][0].to_s == 'Tdb [K]'
          for j in 1..(column_data[i].length - 1)
            curve_data['db_data'] << convert_to_float(column_data[i][j])
          end
        end
        # collect wb_data
        if column_data[i][0].to_s == 'Twb [K]'
          for j in 1..(column_data[i].length - 1)
            curve_data['wb_data'] << convert_to_float(column_data[i][j])
          end
        end
        # collect ewt_data
        if column_data[i][0].to_s == 'Twat [K]'
          for j in 1..(column_data[i].length - 1)
            curve_data['ewt_data'] << convert_to_float(column_data[i][j])
          end
        end
        # collect vdot_air_data
        if column_data[i][0].to_s == 'Vdot air [m3/s]'
          for j in 1..(column_data[i].length - 1)
            curve_data['vdot_air_data'] << convert_to_float(column_data[i][j])
          end
        end
        # collect vdot_water_data
        if column_data[i][0].to_s == 'Vdot water [m3/s]'
          for j in 1..(column_data[i].length - 1)
            curve_data['vdot_water_data'] << convert_to_float(column_data[i][j])
          end
        end
        # collect tot_clg_cap_data
        if column_data[i][0].to_s == 'Tot Clg Cap [W]'
          for j in 1..(column_data[i].length - 1)
            curve_data['tot_clg_cap_data'] << convert_to_float(column_data[i][j])
          end
        end
        # collect sen_clg_cap_data
        if column_data[i][0].to_s == 'Sen Clg Cap [W]'
          for j in 1..(column_data[i].length - 1)
            curve_data['sen_clg_cap_data'] << convert_to_float(column_data[i][j])
          end
        end
        # collect clg_pow_data
        if column_data[i][0].to_s == 'Clg Pow [W]'
          for j in 1..(column_data[i].length - 1)
            curve_data['clg_pow_data'] << convert_to_float(column_data[i][j])
          end
        end
        # collect htg_cap_data
        if column_data[i][0].to_s == 'Htg Cap [W]'
          for j in 1..(column_data[i].length - 1)
            curve_data['htg_cap_data'] << convert_to_float(column_data[i][j])
          end
        end
        # collect htg_pow_data
        if column_data[i][0].to_s == 'Htg Pow [W]'
          for j in 1..(column_data[i].length - 1)
            curve_data['htg_pow_data'] << convert_to_float(column_data[i][j])
          end
        end

        # collect load_lwt_data
        if column_data[i][0].to_s == 'Load LWT [C]'
          for j in 1..(column_data[i].length - 1)
            curve_data['load_lwt_data'] << convert_to_float(column_data[i][j])
          end
        end
        # collect source_ewt_data
        if column_data[i][0].to_s == 'Source EWT [C]'
          for j in 1..(column_data[i].length - 1)
            curve_data['source_ewt_data'] << convert_to_float(column_data[i][j])
          end
        end
        # collect plant_clg_cap_data
        if column_data[i][0].to_s == 'Clg Cap [W]'
          for j in 1..(column_data[i].length - 1)
            curve_data['plant_clg_cap_data'] << convert_to_float(column_data[i][j])
          end
        end
        # collect plant_clg_eir_data
        if column_data[i][0].to_s == 'Clg EIR'
          for j in 1..(column_data[i].length - 1)
            curve_data['plant_clg_eir_data'] << convert_to_float(column_data[i][j])
          end
        end
        # collect plant_htg_cap_data
        if column_data[i][0].to_s == 'Htg Cap [W]'
          for j in 1..(column_data[i].length - 1)
            curve_data['plant_htg_cap_data'] << convert_to_float(column_data[i][j])
          end
        end
        # collect plant_htg_eir_data
        next unless column_data[i][0].to_s == 'Htg EIR'

        for j in 1..(column_data[i].length - 1)
          curve_data['plant_htg_eir_data'] << convert_to_float(column_data[i][j])
        end
      end
    end
    curve_data
  end

  def create_table_independent_variable(model, name, values, interp_method, extrap_method, unit_type, runner)
    valid_interp_methods = %w[Linear Cubic]
    valid_extrap_methods = %w[Linear Constant]
    valid_unit_types = %w[Dimensionless Temperature VolumetricFlow MassFlow Distance Power]
    table_ind_var = OpenStudio::Model::TableIndependentVariable.new(model)
    table_ind_var.setName(name.to_s)
    if valid_interp_methods.include? interp_method
      table_ind_var.setInterpolationMethod(interp_method)
    else
      runner.registerError("Invalid interpolation method (#{interp_method}) for table independent variable")
      return false
    end
    if valid_extrap_methods.include? extrap_method
      table_ind_var.setExtrapolationMethod(extrap_method)
    else
      runner.registerError("Invalid extrapolation method (#{extrap_method}) for table independent variable")
      return false
    end
    # table_ind_var.setMinimumValue(values.min)
    # table_ind_var.setMaximumValue(values.max)
    if valid_unit_types.include? unit_type
      table_ind_var.setUnitType(unit_type)
    else
      runner.registerError("Invalid unit type (#{unit_type}) for table independent variable")
      return false
    end
    table_ind_var.setValues(values)
    table_ind_var
  end

  def create_table_lookup(model, name, hvac_system_type, curve_type, divisor, path, runner)
    # create curve lookup
    data = read_performance_curve_data(path, runner)

    if %w[packaged_gshp console_gshp].include?(hvac_system_type)
      # get wb data values
      if %w[sen_clg_cap tot_clg_cap clg_pow].include?(curve_type) && data['wb_data'].empty?
        runner.registerError("No WB temp performance curve data at path (#{path})")
        return false
      end
      wb_values = data['wb_data'].uniq.sort
      # get db data values if relevant
      if %w[sen_clg_cap htg_cap htg_pow].include?(curve_type)
        if data['db_data'].empty?
          runner.registerError("No DB temp performance curve data at path (#{path})")
          return false
        end
        db_values = data['db_data'].uniq.sort
      end
      # get ewt data values
      if data['ewt_data'].empty?
        runner.registerError("No EWT performance curve data at path (#{path})")
        return false
      end
      ewt_values = data['ewt_data'].uniq.sort
      # get air flow data values
      if data['vdot_air_data'].empty?
        runner.registerError("No air flow rate performance curve data at path (#{path})")
        return false
      end
      vdot_air_values = data['vdot_air_data'].uniq.sort
      # get water flow data values
      if data['vdot_water_data'].empty?
        runner.registerError("No water flow rate performance curve data at path (#{path})")
        return false
      end
      vdot_water_values = data['vdot_water_data'].uniq.sort
      # data length check
      if curve_type == 'sen_clg_cap'
        if data['sen_clg_cap_data'].empty?
          runner.registerError("No sensible cooling capacity performance curve data at path (#{path})")
          return false
        else
          unless data['sen_clg_cap_data'].length == (db_values.length * wb_values.length * ewt_values.length * vdot_air_values.length * vdot_water_values.length)
            runner.registerError("Total output data points do not match full permutation of input variable values at path (#{path})")
            return false
          end
        end
      elsif  curve_type == 'tot_clg_cap'
        if data['tot_clg_cap_data'].empty?
          runner.registerError("No total cooling capacity performance curve data at path (#{path})")
          return false
        else
          unless data['tot_clg_cap_data'].length == (wb_values.length * ewt_values.length * vdot_air_values.length * vdot_water_values.length)
            runner.registerError("Total output data points do not match full permutation of input variable values at path (#{path})")
            return false
          end
        end
      elsif  curve_type == 'clg_pow'
        if data['clg_pow_data'].empty?
          runner.registerError("No cooling power performance curve data at path (#{path})")
          return false
        else
          unless data['clg_pow_data'].length == (wb_values.length * ewt_values.length * vdot_air_values.length * vdot_water_values.length)
            runner.registerError("Total output data points do not match full permutation of input variable values at path (#{path})")
            return false
          end
        end
      elsif  curve_type == 'htg_cap'
        if data['htg_cap_data'].empty?
          runner.registerError("No heating capacity performance curve data at path (#{path})")
          return false
        else
          unless data['htg_cap_data'].length == (db_values.length * ewt_values.length * vdot_air_values.length * vdot_water_values.length)
            runner.registerError("Total output data points do not match full permutation of input variable values at path (#{path})")
            return false
          end
        end
      elsif  curve_type == 'htg_pow'
        if data['htg_pow_data'].empty?
          runner.registerError("No heating power performance curve data at path (#{path})")
          return false
        else
          unless data['htg_pow_data'].length == (db_values.length * ewt_values.length * vdot_air_values.length * vdot_water_values.length)
            runner.registerError("Total output data points do not match full permutation of input variable values at path (#{path})")
            return false
          end
        end
      else
        runner.registerError("Unexpected curve type (#{curve_type}) for lookup table creation")
        return false
      end

      # create independent variable objects
      table_independent_variables = []
      if %w[sen_clg_cap htg_cap htg_pow].include?(curve_type)
        table_independent_variables << create_table_independent_variable(model, "#{curve_type}_db_var", db_values,
                                                                          'Cubic', 'Constant', 'Temperature', runner)
      end
      if %w[sen_clg_cap tot_clg_cap clg_pow].include?(curve_type)
        table_independent_variables << create_table_independent_variable(model, "#{curve_type}_wb_var", wb_values,
                                                                          'Cubic', 'Constant', 'Temperature', runner)
      end
      table_independent_variables << create_table_independent_variable(model, "#{curve_type}_ewt_var", ewt_values,
                                                                        'Cubic', 'Constant', 'Temperature', runner)
      table_independent_variables << create_table_independent_variable(model, "#{curve_type}_vdot_air_var",
                                                                        vdot_air_values, 'Cubic', 'Constant', 'VolumetricFlow', runner)
      table_independent_variables << create_table_independent_variable(model, "#{curve_type}_vdot_water_var",
                                                                        vdot_water_values, 'Cubic', 'Constant', 'VolumetricFlow', runner)
      # create lookup table
      table_lookup = OpenStudio::Model::TableLookup.new(model)
      table_lookup.setName(name.to_s)
      table_lookup.setNormalizationMethod('DivisorOnly')
      table_lookup.setNormalizationDivisor(divisor)
      if curve_type == 'sen_clg_cap'
        table_lookup.setOutputUnitType('Capacity')
        table_lookup.setOutputValues(data['sen_clg_cap_data'])
      elsif  curve_type == 'tot_clg_cap'
        table_lookup.setOutputUnitType('Capacity')
        table_lookup.setOutputValues(data['tot_clg_cap_data'])
      elsif  curve_type == 'clg_pow'
        table_lookup.setOutputUnitType('Power')
        table_lookup.setOutputValues(data['clg_pow_data'])
      elsif  curve_type == 'htg_cap'
        table_lookup.setOutputUnitType('Capacity')
        table_lookup.setOutputValues(data['htg_cap_data'])
      elsif  curve_type == 'htg_pow'
        table_lookup.setOutputUnitType('Power')
        table_lookup.setOutputValues(data['htg_pow_data'])
      else
        runner.registerError("Unexpected curve type (#{curve_type}) for lookup table creation")
        return false
      end
    elsif hvac_system_type == 'hydronic_gshp'
      # get load lwt data values
      if data['load_lwt_data'].empty?
        runner.registerError("No load LWT performance curve data at path (#{path})")
        return false
      end
      load_lwt_values = data['load_lwt_data'].uniq.sort
      # get source ewt data values
      if data['source_ewt_data'].empty?
        runner.registerError("No source EWT performance curve data at path (#{path})")
        return false
      end
      source_ewt_values = data['source_ewt_data'].uniq.sort
      # data length check
      if curve_type == 'clg_cap'
        if data['plant_clg_cap_data'].empty?
          runner.registerError("No cooling capacity performance curve data at path (#{path})")
          return false
        else
          unless data['plant_clg_cap_data'].length == (load_lwt_values.length * source_ewt_values.length)
            runner.registerError("Total output data points do not match full permutation of input variable values at path (#{path})")
            return false
          end
        end
      elsif  curve_type == 'clg_eir'
        if data['plant_clg_eir_data'].empty?
          runner.registerError("No cooling eir performance curve data at path (#{path})")
          return false
        else
          unless data['plant_clg_eir_data'].length == (load_lwt_values.length * source_ewt_values.length)
            runner.registerError("Total output data points do not match full permutation of input variable values at path (#{path})")
            return false
          end
        end
      elsif curve_type == 'htg_cap'
        if data['plant_htg_cap_data'].empty?
          runner.registerError("No heating capacity performance curve data at path (#{path})")
          return false
        else
          unless data['plant_htg_cap_data'].length == (load_lwt_values.length * source_ewt_values.length)
            runner.registerError("Total output data points do not match full permutation of input variable values at path (#{path})")
            return false
          end
        end
      elsif  curve_type == 'htg_eir'
        if data['plant_htg_eir_data'].empty?
          runner.registerError("No heating eir performance curve data at path (#{path})")
          return false
        else
          unless data['plant_htg_eir_data'].length == (load_lwt_values.length * source_ewt_values.length)
            runner.registerError("Total output data points do not match full permutation of input variable values at path (#{path})")
            return false
          end
        end
      else
        runner.registerError("Unexpected curve type (#{curve_type}) for lookup table creation")
        return false
      end

      # create independent variable objects
      table_independent_variables = []
      table_independent_variables << create_table_independent_variable(model, "#{curve_type}_load_lwt", load_lwt_values,
                                                                        'Cubic', 'Constant', 'Temperature', runner)
      table_independent_variables << create_table_independent_variable(model, "#{curve_type}_source_ewt",
                                                                        source_ewt_values, 'Cubic', 'Constant', 'Temperature', runner)
      # create lookup table
      table_lookup = OpenStudio::Model::TableLookup.new(model)
      table_lookup.setName(name.to_s)
      table_lookup.setNormalizationMethod('DivisorOnly')
      table_lookup.setNormalizationDivisor(divisor)
      if curve_type == 'clg_cap'
        table_lookup.setOutputUnitType('Capacity')
        table_lookup.setOutputValues(data['plant_clg_cap_data'])
      elsif  curve_type == 'clg_eir'
        table_lookup.setOutputUnitType('Dimensionless')
        table_lookup.setOutputValues(data['plant_clg_eir_data'])
      elsif  curve_type == 'htg_cap'
        table_lookup.setOutputUnitType('Capacity')
        table_lookup.setOutputValues(data['plant_htg_cap_data'])
      elsif  curve_type == 'htg_eir'
        table_lookup.setOutputUnitType('Dimensionless')
        table_lookup.setOutputValues(data['plant_htg_eir_data'])
      else
        runner.registerError("Unexpected curve type (#{curve_type}) for lookup table creation")
        return false
      end
    end

    table_independent_variables.each do |var|
      table_lookup.addIndependentVariable(var)
    end
    table_lookup
  end

  # add lookup table performance data to relevant HVAC objects
  def add_lookup_performance_data(model, hvac_object, hvac_system_type, data_set_name, runner)
    supported_hvac_system_types = %w[hydronic_gshp packaged_gshp console_gshp]
    available_data_sets = {}
    available_data_sets['hydronic_gshp'] = %w[Carrier_30WG_90kW Carrier_61WG_Glycol_90kW]
    available_data_sets['packaged_gshp'] = ['Trane_10_ton_GWSC120E']
    available_data_sets['console_gshp'] = ['Trane_3_ton_GWSC036H']
    # input checks
    unless supported_hvac_system_types.include? hvac_system_type
      runner.registerError("HVAC system type #{hvac_system_type} not supported by add_lookup_performance_data method")
      return false
    end
    if available_data_sets[hvac_system_type].nil?
      runner.registerError("There are no lookup table performance data sets for HVAC system type #{hvac_system_type}")
      return false
    else
      unless available_data_sets[hvac_system_type].include? data_set_name
        runner.registerError("#{data_set_name} is not a valid lookup table performance data set for HVAC system type #{hvac_system_type}")
        return false
      end
    end

    # collect relevant info based on data set input
    if data_set_name == 'Trane_10_ton_GWSC120E'
      valid_object_types = %w[OS_Coil_Cooling_WaterToAirHeatPump_EquationFit
                              OS_Coil_Heating_WaterToAirHeatPump_EquationFit]
      # check hvac object
      hvac_object_type = hvac_object.iddObjectType.valueName.to_s
      unless valid_object_types.include? hvac_object_type
        runner.registerError("Unexpected object type (#{hvac_object_type}) for lookup table performance data set #{data_set_name}")
        return false
      end
      # basic data set info
      # 80.6 DB, 66.2 WB, 75 EWT cooling
      # 68 DB, 59 WB heating, 32 EWT heating
      # 30 gpm, 4000 cfm
      # EWT 75
      rated_total_cooling_capacity_watts = 124.4 * 0.29307107017222 * 1000
      rated_sensible_cooling_capacity_watts = 100.9 * 0.29307107017222 * 1000
      rated_cooling_power_watts = 6.16 * 1000
      rated_heating_capacity_watts = 92.1 * 0.29307107017222 * 1000
      rated_heating_power_watts = 6.44 * 1000
      rated_air_flow_rate = 4000 / 2118.88
      rated_water_flow_rate = 30 / 15_850.323
      rated_db_clg = (80.6 - 32) / 1.8
      rated_db_htg = (68 - 32) / 1.8
      rated_wb_clg = (66.2 - 32) / 1.8
      rated_wb_htg = (59 - 32) / 1.8
      rated_ewt_clg = (75 - 32) / 1.8
      rated_ewt_htg = (32 - 32) / 1.8

    elsif data_set_name == 'Trane_3_ton_GWSC036H'
      valid_object_types = %w[OS_Coil_Cooling_WaterToAirHeatPump_EquationFit
                              OS_Coil_Heating_WaterToAirHeatPump_EquationFit]
      # check hvac object
      hvac_object_type = hvac_object.iddObjectType.valueName.to_s
      unless valid_object_types.include? hvac_object_type
        runner.registerError("Unexpected object type (#{hvac_object_type}) for lookup table performance data set #{data_set_name}")
        return false
      end
      # basic data set info
      # 80.6 DB, 66.2 WB cooling
      # 68 DB, 59 WB heating
      # 9 gpm, 1200 cfm
      # EWT 75
      rated_total_cooling_capacity_watts = 45.9 * 0.29307107017222 * 1000
      rated_sensible_cooling_capacity_watts = 35.6 * 0.29307107017222 * 1000
      rated_cooling_power_watts = 2.22 * 1000
      rated_heating_capacity_watts = 31.3 * 0.29307107017222 * 1000
      rated_heating_power_watts = 2.43 * 1000
      rated_air_flow_rate = 1200 / 2118.88
      rated_water_flow_rate = 9 / 15_850.323
      rated_db = (68 - 32) / 1.8
      rated_wb = (59 - 32) / 1.8
      rated_ewt_clg = (75 - 32) / 1.8
      rated_ewt_htg = (32 - 32) / 1.8

    elsif  data_set_name == 'Carrier_30WG_90kW'
      valid_object_types = ['OS_HeatPump_PlantLoop_EIR_Cooling']
      # check hvac object
      hvac_object_type = hvac_object.iddObjectType.valueName.to_s
      unless valid_object_types.include? hvac_object_type
        runner.registerError("Unexpected object type (#{hvac_object_type}) for lookup table performance data set #{data_set_name}")
        return false
      end
      # basic data set info
      rated_cooling_capacity_watts = 94.1 * 1000
      rated_cooling_eir = 0.21505
      rated_clg_load_flow_rate = 0.00443 # 5K delta
      rated_clg_source_flow_rate = 0.00443 # 5k delta (same delta t and same working fluid, so same flow rate)

    elsif  data_set_name == 'Carrier_61WG_Glycol_90kW'
      valid_object_types = ['OS_HeatPump_PlantLoop_EIR_Heating']
      # check hvac object
      hvac_object_type = hvac_object.iddObjectType.valueName.to_s
      unless valid_object_types.include? hvac_object_type
        runner.registerError("Unexpected object type (#{hvac_object_type}) for lookup table performance data set #{data_set_name}")
        return false
      end
      # basic data set info
      rated_heating_capacity_watts = 86.7 * 1000
      rated_heating_eir = 0.23419
      cp_water = 4184 # J/kgK
      cp_glycol = 2294 # J/kgK at 0 C
      htg_cond_delta_t = 5 # K
      htg_evap_delta_t = 3 # K
      rated_htg_load_flow_rate = 0.0042 # m3/s
      density_water = 997 # kg/m3
      density_glycol = 1115 # kg/m3
      glycol_fraction = 0.3
      density_evap = (1 - glycol_fraction) * density_water + glycol_fraction * density_glycol
      cp_evap = (1 - glycol_fraction) * cp_water + glycol_fraction * cp_glycol
      rated_htg_source_flow_rate = (rated_htg_load_flow_rate * density_water * cp_water * htg_cond_delta_t) / (density_evap * cp_evap * htg_evap_delta_t)

    else
      runner.registerError("#{data_set_name} is not supported by add_lookup_performance_data method")
      return false
    end

    if hvac_object_type == 'OS_Coil_Cooling_WaterToAirHeatPump_EquationFit'
      # read in csv data
      total_cooling_capacity_data_path = "#{File.dirname(__FILE__)}/resources/#{data_set_name}_tot_clg_cap.csv"
      sensible_cooling_capacity_data_path = "#{File.dirname(__FILE__)}/resources/#{data_set_name}_sen_clg_cap.csv"
      cooling_power_data_path = "#{File.dirname(__FILE__)}/resources/#{data_set_name}_clg_pow.csv"
      # create lookup tables and supporting objects
      table_lookup_tot_clg_cap = create_table_lookup(model, 'table_lookup_tot_clg_cap', 'packaged_gshp', 'tot_clg_cap',
                                                      rated_total_cooling_capacity_watts, total_cooling_capacity_data_path, runner)
      table_lookup_sen_clg_cap = create_table_lookup(model, 'table_lookup_sen_clg_cap', 'packaged_gshp', 'sen_clg_cap',
                                                      rated_sensible_cooling_capacity_watts, sensible_cooling_capacity_data_path, runner)
      table_lookup_clg_pow = create_table_lookup(model, 'table_lookup_clg_pow', 'packaged_gshp', 'clg_pow',
                                                  rated_cooling_power_watts, cooling_power_data_path, runner)
      # assign lookup tables
      hvac_object.setTotalCoolingCapacityCurve(table_lookup_tot_clg_cap)
      hvac_object.setSensibleCoolingCapacityCurve(table_lookup_sen_clg_cap)
      hvac_object.setCoolingPowerConsumptionCurve(table_lookup_clg_pow)
      # set coil inputs
      hvac_object.setRatedCoolingCoefficientofPerformance(rated_total_cooling_capacity_watts / rated_cooling_power_watts)
      hvac_object.setRatedEnteringWaterTemperature(rated_ewt_clg)
      hvac_object.setRatedEnteringAirDryBulbTemperature(rated_db_clg)
      hvac_object.setRatedEnteringAirWetBulbTemperature(rated_wb_clg)

    elsif hvac_object_type == 'OS_Coil_Heating_WaterToAirHeatPump_EquationFit'
      # read in csv data
      heating_capacity_data_path = "#{File.dirname(__FILE__)}/resources/#{data_set_name}_htg_cap.csv"
      heating_power_data_path = "#{File.dirname(__FILE__)}/resources/#{data_set_name}_htg_pow.csv"
      # create lookup tables and supporting objects
      table_lookup_htg_cap = create_table_lookup(model, 'table_lookup_htg_cap', 'packaged_gshp', 'htg_cap',
                                                  rated_heating_capacity_watts, heating_capacity_data_path, runner)
      table_lookup_htg_pow = create_table_lookup(model, 'table_lookup_htg_pow', 'packaged_gshp', 'htg_pow',
                                                  rated_heating_power_watts, heating_power_data_path, runner)
      # assign lookup tables
      hvac_object.setHeatingCapacityCurve(table_lookup_htg_cap)
      hvac_object.setHeatingPowerConsumptionCurve(table_lookup_htg_pow)
      # set coil inputs
      hvac_object.setRatedCoolingCoefficientofPerformance(rated_heating_capacity_watts / rated_heating_power_watts)
      hvac_object.setRatedEnteringWaterTemperature(rated_ewt_htg)
      hvac_object.setRatedEnteringAirDryBulbTemperature(rated_db_htg)
      hvac_object.setRatedEnteringAirWetBulbTemperature(rated_wb_htg)

    elsif hvac_object_type == 'OS_HeatPump_PlantLoop_EIR_Cooling'
      # read in csv data
      cooling_data_path = "#{File.dirname(__FILE__)}/resources/#{data_set_name}_clg.csv"
      # create lookup tables and supporting objects
      table_lookup_clg_cap = create_table_lookup(model, 'table_lookup_clg_cap', 'hydronic_gshp', 'clg_cap',
                                                  rated_cooling_capacity_watts, cooling_data_path, runner)
      table_lookup_clg_eir = create_table_lookup(model, 'table_lookup_clg_eir', 'hydronic_gshp', 'clg_eir',
                                                  rated_cooling_eir, cooling_data_path, runner)
      # assign lookup tables
      hvac_object.setCapacityModifierFunctionofTemperatureCurve(table_lookup_clg_cap)
      hvac_object.setElectricInputtoOutputRatioModifierFunctionofTemperatureCurve(table_lookup_clg_eir)
      # set coil inputs
      hvac_object.setReferenceCoefficientofPerformance(1 / rated_cooling_eir)

    elsif hvac_object_type == 'OS_HeatPump_PlantLoop_EIR_Heating'
      # read in csv data
      heating_data_path = "#{File.dirname(__FILE__)}/resources/#{data_set_name}_htg.csv"
      # create lookup tables and supporting objects
      table_lookup_htg_cap = create_table_lookup(model, 'table_lookup_htg_cap', 'hydronic_gshp', 'htg_cap',
                                                  rated_heating_capacity_watts, heating_data_path, runner)
      table_lookup_htg_eir = create_table_lookup(model, 'table_lookup_htg_eir', 'hydronic_gshp', 'htg_eir',
                                                  rated_heating_eir, heating_data_path, runner)
      # assign lookup tables
      hvac_object.setCapacityModifierFunctionofTemperatureCurve(table_lookup_htg_cap)
      hvac_object.setElectricInputtoOutputRatioModifierFunctionofTemperatureCurve(table_lookup_htg_eir)
      # set coil inputs
      hvac_object.setReferenceCoefficientofPerformance(1 / rated_heating_eir)

    else
      runner.registerError("Unexpected object type (#{hvac_object_type}) for lookup table performance data set #{data_set_name}")
      return false
    end
    true
  end


  # define what happens when the measure is run
  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)

    # Use the built-in error checking
    return false unless runner.validateUserArguments(arguments(model), user_arguments)

    # Report initial condition of model
    hpwh_ic = model.getBoilerHotWaters.size
    runner.registerInitialCondition("The building started with #{hpwh_ic} hot water boilers.")

    # Assign the user inputs to variables
    keep_setpoint = runner.getBoolArgumentValue('keep_setpoint', user_arguments)
    hw_setpoint_F = runner.getDoubleArgumentValue('hw_setpoint_F', user_arguments)
    chw_setpoint_F = runner.getDoubleArgumentValue('chw_setpoint_F', user_arguments)
    autosize_hc = runner.getBoolArgumentValue('autosize_hc', user_arguments)
    hp_des_cap_htg = runner.getDoubleArgumentValue('hp_des_cap_htg', user_arguments)
    hp_des_cap_clg = runner.getDoubleArgumentValue('hp_des_cap_clg', user_arguments)
    cop = runner.getDoubleArgumentValue('cop', user_arguments)

    # Get chw setpoint
    chw_setpoint_c = OpenStudio.convert(chw_setpoint_F, 'F', 'C').get
    hw_setpoint_c = OpenStudio.convert(hw_setpoint_F, 'F', 'C').get

    # unit conversions
    tons_per_watt = 0.000284345
    mcs_per_gpm =  0.00006309019640343866 # m3/s per gpm

    delta_t_coil = 8 # deg C, slightly reduced from OS typical value of 10C for higher HHW supply water temps

    # high level assumptions
    source_side_gpm_per_ton = 2.75 # per Mescher et al


    runner.registerInfo("Start time: #{Time.now} ")

    # check for measure applicability
    # check for different types of chillers in measure as well


    if hw_setpoint_F > 145
      runner.registerWarning("#{hw_setpoint_F}F is above or near the limit of the HP performance curves. If the " \
                            'simulation fails with cooling capacity less than 0, you have exceeded performance ' \
                            'limits. Consider setting max temp to less than 145F.')
    end

    # use openstudio-standards utility methods, choice of standard does not impact results
    std = Standard.build('NREL ZNE Ready 2017')


    hpwh_eir_plr_coefficient1constant = 1.25
    hpwh_eir_plr_coefficient2x = -0.25
    hpwh_eir_plr_coefficient3xPOW2 = 0


    cooling_hp_plr_coeff1constant = 0.5203969
    cooling_hp_plr_coeff2x = -0.77759
    cooling_hp_plr_coeff3xPOW2 = 1.255394



    if keep_setpoint == false
      # sched = OpenStudio::Model::ScheduleRuleset.new(model, hw_setpoint_c)
      # #AA revised to the below for purposes of use in a SetpointManagerScheduled
      sched = OpenStudio::Model::ScheduleConstant.new(model) # , hw_setpoint_c)
      sched.setValue(hw_setpoint_c)
      sched.setName('Heat Pump Heating Temperature Setpoint')
      # sched.defaultDaySchedule.setName('Heat Pump Heating Temperature Setpoint Default')
    end

    # Create offset schedules for intermediate loops

    sched_htg_intermed = OpenStudio::Model::ScheduleConstant.new(model) # , hw_setpoint_c)
    sched_htg_intermed.setValue(hw_setpoint_c + 2)
    sched_htg_intermed.setName('Intermediate Heating Loop Temperature Setpoint')

    sched_clg_intermed = OpenStudio::Model::ScheduleConstant.new(model) # , hw_setpoint_c)
    sched_clg_intermed.setValue(chw_setpoint_c - 2)
    sched_clg_intermed.setName('Intermediate Cooling Loop Temperature Setpoint')


    # Find all hot water loops in the model
    # boilers = []
    hot_water_loops = []
    ch_water_loops = []

    no_ht_pump_htg_coils = model.getCoilHeatingWaterToAirHeatPumpEquationFits.size
    no_ht_pump_clg_coils = model.getCoilCoolingWaterToAirHeatPumpEquationFits.size

    no_boilers = model.getBoilerHotWaters.size
    no_chillers = model.getChillerElectricEIRs.size

    if (no_ht_pump_htg_coils > 0) or (no_ht_pump_clg_coils > 0)
      runner.registerAsNotApplicable('Heat pumps already present in model--measure will not be applied.')
      return true
    end

    # measure not applied if neither a boiler or a chiller
    if (no_boilers == 0) and (no_chillers == 0)
      runner.registerAsNotApplicable('No boilers or chillers in model--measure will not be applied.')
      return true
    end

    no_evap_coolers = model.getEvaporativeCoolerIndirectResearchSpecials.size + model.getEvaporativeCoolerDirectResearchSpecials.size

    if no_evap_coolers > 0
      runner.registerAsNotApplicable('Evaporative coolers in model--measure will not be applied.')
      return true
    end

    no_baseboards = model.getZoneHVACBaseboardConvectiveElectrics.size

    if no_baseboards > 0
      runner.registerAsNotApplicable('Baseboard heaters in model--measure will not be applied.')
      return true
    end


    # change to model.getBoilers....
    runner.registerInfo("Start time of first loop: #{Time.now} ")

    # #AA added this to refactor 7/24

    # runner.registerInfo("end time of first loop: #{Time.now()} ")

    ground_loop_sp_c = 7.5 # deg c #45.5F
    ground_loop_sp_h = 30 # #AA modified for test 8/10 #26.6667 #deg C #80F

    #### unitary systems consideration #####
    # if the model has unitary systems that are autosized without specifying the flow rate method during heating operation, running the 'autosizing' measure will crush with
    # the following error "Blank field not allowed for this coil type when cooling coil air flow rate is not AutoSized". To avoid this, if the flow rate method is blank, a default method
    # called "SupplyAirFlowRate" is assigned

    runner.registerInfo("looping thru unitary systems: #{Time.now} ")
    model.getAirLoopHVACUnitarySystems.each do |unit|
      flowmethod = unit.supplyAirFlowRateMethodDuringHeatingOperation.get
      runner.registerInfo("flow method is #{flowmethod} ")
      if flowmethod == ''
        unit.setSupplyAirFlowRateMethodDuringHeatingOperation('SupplyAirFlowRate')
        runner.registerInfo("SupplyAirFlowRateMethodDuringHeatingOperation reset to use 'SupplyAirFlowRate' method")
      end
    end

    runner.registerInfo("end of looping thru unitary systems: #{Time.now} ")
    #------------------------------------------------

    # Sizing run to calculate boiler capacity if no autosized or hard sized capacities were found
    # #AA commented out to move later on after capacity calculated
    # if tot_blr_cap.zero?
    # # Run a sizing run to determine equipment capacities and flow rates
    standard = Standard.build('ComStock DOE Ref Pre-1980')
    if standard.model_run_sizing_run(model, "#{Dir.pwd}/replace_boiler_with_gthp_SR") == false
      runner.registerError('Sizing run for Hardsize model failed, cannot hard-size model.')
      puts('Sizing run for Hardsize model failed, cannot hard-size model.')
      puts("directory: #{Dir.pwd}")
      return false
    end

    # apply sizing values
    # need this to hard-size chillers and boilers
    model.applySizingValues
    # end

    # # Hard size the equipment based on the sizing run if not already hardsized
    # unless model_already_hardsized
    # model.applySizingValues
    # end

    ## Add new Ground Loop-------------------------------------------------------------------------------
    # Create new loop connecting heat pump and ground heat exchanger.
    # Initially, a PlantLoop:TemperatureSource object will be used.
    # After a GHEDesigner simulation is run the PlantLoop:TemperatureSource
    # object will be replaced with a vertical ground heat exchanger
    # with borehole properties and G-functions per the GHEDesigner output.
    ground_loop = OpenStudio::Model::PlantLoop.new(model)
    # #AA tried moving up
    ground_loop.setFluidType('PropyleneGlycol')
    ground_loop.setGlycolConcentration(20)
    runner.registerInfo('Ground Loop added.')
    ground_loop.setName('Ground Loop')
    ground_loop.setMaximumLoopTemperature(100.0)
    ground_loop.setMinimumLoopTemperature(10.0)
    ground_loop.setLoadDistributionScheme('SequentialLoad')
    ground_loop_sizing = ground_loop.sizingPlant
    ground_loop_sizing.setLoopType('Condenser')
    ground_loop_sizing.setDesignLoopExitTemperature((ground_loop_sp_c + ground_loop_sp_h) / 2) # averaging the range


    # Create and add a pump to the loop
    ground_pump = OpenStudio::Model::PumpConstantSpeed.new(model)
    ground_pump.setName('Ground loop circulation pump')
    ground_pump.setRatedPumpHead(66_955.1) # #Set this based on modified version of example in Table 6.15 in ASHRAE geothermal design guide (subtracted out heat pumps and headers to them)
    ground_pump.addToNode(ground_loop.supplyInletNode)

    # Create a scheduled setpoint manager
    # TODO determine if a schedule that follows the monthly ground temperature
    # would result in significantly different loads
    ground_temp_sch_low = OpenStudio::Model::ScheduleConstant.new(model)
    ground_temp_sch_low.setName('Ground Loop Supply Low Temp Schedule')
    ground_temp_sch_low.setValue(ground_loop_sp_c) # AA updated

    ground_temp_sch_high = OpenStudio::Model::ScheduleConstant.new(model)
    ground_temp_sch_high.setName('Ground Loop Supply High Temp Schedule')
    ground_temp_sch_high.setValue(ground_loop_sp_h) # AA updated

    # ground_setpoint_manager = OpenStudio::Model::SetpointManagerScheduled.new(model, ground_temp_sch)
    ground_setpoint_manager = OpenStudio::Model::SetpointManagerScheduledDualSetpoint.new(model) # , ground_temp_sch)
    ground_setpoint_manager.setHighSetpointSchedule(ground_temp_sch_high)
    ground_setpoint_manager.setLowSetpointSchedule(ground_temp_sch_low)
    ground_setpoint_manager.setName('Ground Loop Supply Temp Setpoint Manager')
    ground_setpoint_manager.addToNode(ground_loop.supplyOutletNode)

    # Create and add a PlantComponent:TemperatureSource object to supply side of ground loop
    ground_temp_source = OpenStudio::Model::PlantComponentTemperatureSource.new(model)
    ground_temp_source.setName('Ground Loop Temperature Source (Ground Heat Exchanger Placeholder)')
    ground_temp_source.autosizeDesignVolumeFlowRate
    ground_temp_source.setTemperatureSpecificationType('Constant')
    ground_temp_source.setSourceTemperature((ground_loop_sp_c + ground_loop_sp_h) / 2) # average of temp range of loop

    # Add temp source to the supply side of the ground loop
    ground_loop.addSupplyBranchForComponent(ground_temp_source)

    # Set sp values
    cond_loop_setpoint_low = 6 # deg C #43F
    cond_loop_setpoint_high = 35 # deg C, 95F

    # AA moved this chunk up from after the boiler inlet outlet node
    ### Creating Heat Pump Loop #######
    # Add HX to connect secondary and primary loop
    heat_exchanger = OpenStudio::Model::HeatExchangerFluidToFluid.new(model)
    heat_exchanger.setName('HX for heat pump')
    heat_exchanger.setHeatExchangeModelType('Ideal')
    heat_exchanger.setControlType('UncontrolledOn')
    heat_exchanger.setHeatTransferMeteringEndUseType('LoopToLoop')
    # heat_exchanger.addToNode(inlet) ##AA commented this out and added line below 7/12
    ground_loop.addDemandBranchForComponent(heat_exchanger) # #AA added this 7/13

    # create a scheduled setpoint manager
    # print out time before and after each loop
    # check if optional is empty--is(object)initialized, use instead of not
    # AA commented out
    cond_loop_temp_sch_low = OpenStudio::Model::ScheduleConstant.new(model)
    cond_loop_temp_sch_low.setName('Cond Loop Supply Temp Schedule Low')
    cond_loop_temp_sch_low.setValue(cond_loop_setpoint_low)

    cond_loop_temp_sch_high = OpenStudio::Model::ScheduleConstant.new(model)
    cond_loop_temp_sch_high.setName('Cond Loop Supply Temp Schedule High')
    cond_loop_temp_sch_high.setValue(cond_loop_setpoint_high)

    # #AA added this
    # create a condenser loop for the heat pumps
    cond_loop = OpenStudio::Model::PlantLoop.new(model)
    runner.registerInfo('Condenser Loop added.')
    cond_loop.setName('Condenser Loop')
    cond_loop.setMaximumLoopTemperature(100.0)
    cond_loop.setMinimumLoopTemperature(10.0)
    # cond_loop.setLoadDistributionScheme('SequentialLoad') ##AA need to revisit this
    cond_loop_sizing = cond_loop.sizingPlant
    cond_loop_sizing.setLoopType('Condenser Loop')
    cond_loop_sizing.setDesignLoopExitTemperature((cond_loop_setpoint_high + cond_loop_setpoint_low) / 2) # #AA updated this, averaging the range
    cond_loop.addSupplyBranchForComponent(heat_exchanger) # #AA will need to refine this
    cond_loop_setpoint_manager = OpenStudio::Model::SetpointManagerScheduledDualSetpoint.new(model) # , cond_loop_temp_sch)

    cond_loop_setpoint_manager.setHighSetpointSchedule(cond_loop_temp_sch_high)
    cond_loop_setpoint_manager.setLowSetpointSchedule(cond_loop_temp_sch_low)
    cond_loop_setpoint_manager.setName('Condenser Loop Supply Temp Setpoint Manager')
    cond_loop_setpoint_manager.addToNode(cond_loop.supplyOutletNode)

    # #Add intermediate heating condenser loop
    intermed_htg_cond_loop = OpenStudio::Model::PlantLoop.new(model)
    runner.registerInfo('Intermediate Condenser Loop added.')
    intermed_htg_cond_loop.setName('Intermediate Htg Condenser Loop')
    intermed_htg_cond_loop.setLoadDistributionScheme('SequentialLoad') # #AA could revisit this, consistent with original approach for hp loop
    intermed_htg_cond_loop.setMaximumLoopTemperature(100.0)
    intermed_htg_cond_loop.setMinimumLoopTemperature(10.0)
    # cond_loop.setLoadDistributionScheme('SequentialLoad') ##AA need to revisit this
    intermed_htg_cond_loop_sizing = intermed_htg_cond_loop.sizingPlant
    intermed_htg_cond_loop_sizing.setLoopType('Heating')
    intermed_htg_cond_loop_sizing.setDesignLoopExitTemperature((hw_setpoint_c + 2)) # #slight offset from heating loop setpoint
    intermed_htg_cond_loop_setpoint_manager = OpenStudio::Model::SetpointManagerScheduled.new(model, sched_htg_intermed) # , sched) #same value as htg loop for now
    # intermed_htg_cond_loop_setpoint_manager.setSchedule(sched)

    intermed_htg_cond_loop_setpoint_manager.setName('Intermediate Htg Cond Loop Supply Temp Setpoint Manager')
    intermed_htg_cond_loop_setpoint_manager.addToNode(intermed_htg_cond_loop.supplyOutletNode)

    # Add HX to connect cond loop and intermediate loop
    inter_htg_heat_exchanger = OpenStudio::Model::HeatExchangerFluidToFluid.new(model)
    inter_htg_heat_exchanger.setName('Intermediate heat ex--htg')
    inter_htg_heat_exchanger.setHeatExchangeModelType('Ideal')
    inter_htg_heat_exchanger.setControlType('UncontrolledOn')
    inter_htg_heat_exchanger.setHeatTransferMeteringEndUseType('LoopToLoop')
    # heat_exchanger.addToNode(inlet) ##AA commented this out and added line below 7/12
    intermed_htg_cond_loop.addDemandBranchForComponent(inter_htg_heat_exchanger) # #AA added this 7/13


    # #Add intermediate cooling condenser loop
    intermed_clg_cond_loop = OpenStudio::Model::PlantLoop.new(model)
    runner.registerInfo('Intermediate Cooling Condenser Loop added.')
    intermed_clg_cond_loop.setName('Intermediate Clg Condenser Loop')
    intermed_clg_cond_loop.setLoadDistributionScheme('SequentialLoad') # #AA could revisit this, consistent with original approach for hp loop
    intermed_clg_cond_loop.setMaximumLoopTemperature(100.0)
    intermed_clg_cond_loop.setMinimumLoopTemperature(3.0) # appropriate for CHW supply temperature
    # cond_loop.setLoadDistributionScheme('SequentialLoad') ##AA need to revisit this
    intermed_clg_cond_loop_sizing = intermed_clg_cond_loop.sizingPlant
    intermed_clg_cond_loop_sizing.setLoopType('Cooling')
    intermed_clg_cond_loop_sizing.setDesignLoopExitTemperature((chw_setpoint_c - 2)) # #slight offset from clg loop setpoint
    intermed_clg_cond_loop_setpoint_manager = OpenStudio::Model::SetpointManagerScheduled.new(model, sched_clg_intermed) # , sched) #same value as htg loop for now
    # intermed_htg_cond_loop_setpoint_manager.setSchedule(sched)

    intermed_clg_cond_loop_setpoint_manager.setName('Intermediate Clg Cond Loop Supply Temp Setpoint Manager')
    intermed_clg_cond_loop_setpoint_manager.addToNode(intermed_clg_cond_loop.supplyOutletNode)


    # Add HX to connect clg loop and intermediate loop
    inter_clg_heat_exchanger = OpenStudio::Model::HeatExchangerFluidToFluid.new(model)
    inter_clg_heat_exchanger.setName('Intermediate heat ex--clg')
    inter_clg_heat_exchanger.setHeatExchangeModelType('Ideal')
    inter_clg_heat_exchanger.setControlType('UncontrolledOn')
    inter_clg_heat_exchanger.setHeatTransferMeteringEndUseType('LoopToLoop')
    # heat_exchanger.addToNode(inlet) ##AA commented this out and added line below 7/12
    intermed_clg_cond_loop.addDemandBranchForComponent(inter_clg_heat_exchanger) # #AA added this 7/13


    # add a pump to the intermediate clg condenser loop
    pump_clg_intermed_loop = OpenStudio::Model::PumpConstantSpeed.new(model)
    # pump = OpenStudio::Model::PumpConstantSpeed.new(model) ##AA trying constant speed pump for now based on HP object
    pump_clg_intermed_loop.setName('Intermediate cooling loop circulation Pump')
    pump_clg_intermed_loop.setRatedPumpHead(100) # setting head to a nominal value since this loop wouldn't actually exist
    # pump.addToNode(hp_loop.supplyInletNode) ##AA commented out
    pump_clg_intermed_loop.addToNode(intermed_clg_cond_loop.supplyInletNode)

    # add a pump to the intermediate htg condenser loop
    pump_htg_intermed_loop = OpenStudio::Model::PumpConstantSpeed.new(model)
    # pump = OpenStudio::Model::PumpConstantSpeed.new(model) ##AA trying constant speed pump for now based on HP object
    pump_htg_intermed_loop.setName('Intermediate heating loop circulation Pump')
    pump_htg_intermed_loop.setRatedPumpHead(100) # setting head to a nominal value since this loop wouldn't actually exist
    # pump.addToNode(hp_loop.supplyInletNode) ##AA commented out
    pump_htg_intermed_loop.addToNode(intermed_htg_cond_loop.supplyInletNode)

    # create and add a pump to the condenser loop
    pump = OpenStudio::Model::PumpVariableSpeed.new(model)
    # pump = OpenStudio::Model::PumpConstantSpeed.new(model) ##AA trying constant speed pump for now based on HP object
    pump.setName('Heat pump circulation Pump')
    pump.setRatedPumpHead(44_834.7) # 15 ftf for primary pump for a primary-secondary system based on Appendix G
    # pump.addToNode(hp_loop.supplyInletNode) ##AA commented out
    pump.addToNode(cond_loop.supplyInletNode)


    # #AA added below for case where no CHW loop present

    chw_loops = []

    model.getPlantLoops.each do |plant_loop|
      next unless plant_loop.name.get.to_s == 'Chilled Water Loop'

      chw_loops.append(plant_loop) # #AA added
    end

    # create schedule for chw loop #AA: make sure this isn't duplicated elsewhere
    chw_loop_setpoint_sched = OpenStudio::Model::ScheduleConstant.new(model) # , hw_setpoint_c)
    chw_loop_setpoint_sched.setValue(chw_setpoint_c)
    chw_loop_setpoint_sched.setName('Chilled Water Loop Setpoint')

    # create CHW loop if one doesn't exist
    if chw_loops.length == 0
      chw_loop = OpenStudio::Model::PlantLoop.new(model) # Create new chw loop
      chw_loop.setName('Chilled Water Loop')

      chw_loop_sizing = chw_loop.sizingPlant
      chw_loop_sizing.setLoopType('Cooling')

      chw_loop_sizing.setDesignLoopExitTemperature(chw_setpoint_c) # #AA updated this, averaging the range
      chw_loop_setpoint_manager = OpenStudio::Model::SetpointManagerScheduled.new(model, chw_loop_setpoint_sched) # , cond_loop_temp_sch)#need to add a schedule here

      chw_loop_setpoint_manager.setName('CHW Loop Supply Temp Setpoint Manager')
      chw_loop_setpoint_manager.addToNode(chw_loop.supplyOutletNode)

      # #add pump to loop

      pump_chw_loop = OpenStudio::Model::PumpConstantSpeed.new(model)
      pump_chw_loop.setName('Chilled Water Loop Pump')
      # pump_clg_intermed_loop.setRatedPumpHead(44834.7) # 15 ftf for primary pump for a primary-secondary system based on Appendix G
      pump_chw_loop.addToNode(chw_loop.supplyInletNode)

    end

    # go thru air loops and replace DX coils with chw coils

    # model.getAirLoopHVACs.each do |air_loop|
    # mixed_air_node = air_loop.mixedAirNode()
    # runner.registerInfo("mixed air node #{mixed_air_node}")
    # end

    cap_coils = 0
    # check for unitary systems
    no_unit_sys = model.getAirLoopHVACUnitarySystems.empty?

    # handling of unitary systems

    # track cooling capacity of unitary systems
    unitary_cap = 0

    if no_unit_sys == false
      # iterate thru unitary sys
      model.getAirLoopHVACUnitarySystems.each do |sys|
        # get sizes of existing equipmetn
        # create CHW and HHW coils and add to loop
        coil = sys.coolingCoil.get
        coil = coil.to_CoilCoolingDXSingleSpeed.get
        runner.registerInfo("unitary coil class: #{coil.class}")
        runner.registerInfo("unitary coil: #{coil}")
        # get supplemental htg coil if there is one
        sup_htg_coil = sys.supplementalHeatingCoil.get
        runner.registerInfo("sup heating coil : #{sup_htg_coil}")
        sup_htg_coil = sup_htg_coil.to_CoilHeatingElectric.get
        sys.resetSupplementalHeatingCoil
        sup_htg_coil.remove
        # deal with clg coil
        if coil.to_CoilCoolingDXSingleSpeed.is_initialized # check for autosized capacity, too--should this be autosized?
          unitary_cap += coil.ratedTotalCoolingCapacity.get.to_f if coil.ratedTotalCoolingCapacity.is_initialized
          if coil.autosizedRatedTotalCoolingCapacity.is_initialized
            unitary_cap += coil.autosizedRatedTotalCoolingCapacity.get.to_f
          end
        end
        runner.registerInfo("unitary coil capacity: #{unitary_cap}")
        # unitary_cap = unitary_cap + coil_cap
        chw_coil = OpenStudio::Model::CoilCoolingWater.new(model)
        chw_coil.autosizeDesignAirFlowRate
        chw_coil.autosizeDesignWaterFlowRate
        chw_coil.setDesignInletWaterTemperature(chw_setpoint_c)
        chw_loop.addDemandBranchForComponent(chw_coil)
        air_loop = sys.airLoopHVAC.get
        mixed_air_node = air_loop.mixedAirNode.get # didnt work to_Node.get()
        runner.registerInfo("unitary mixed air node #{mixed_air_node}")
        # remove existing system
        sys.resetCoolingCoil
        coil.remove
        # coil.to_CoilCoolingDXSingleSpeed.remove()##AA this casued an error
        # add coil
        # chw_coil.addToNode(mixed_air_node) ##AA commetning out 9/25 to try the below instead
        sys.setCoolingCoil(chw_coil)
        # autosize components of the air loop
        air_loop.autosizeDesignSupplyAirFlowRate
        air_loop_sizing = air_loop.sizingSystem
        air_loop_sizing.autosizeCoolingDesignCapacity
        air_loop_sizing.autosizeHeatingDesignCapacity
      end
    end

    if no_chillers == 0 and no_unit_sys
      model.getCoilCoolingDXTwoSpeeds.each do |coil|
        # tally up coil capacity
        if coil.autosizedRatedHighSpeedTotalCoolingCapacity.is_initialized # #AA moved up, 7/12
          runner.registerInfo("coil name:  #{coil.name} and #{coil.autosizedRatedHighSpeedTotalCoolingCapacity.get.to_f}") # boiler capacity #{boiler.nominalCapacity.get.to_f}")
          runner.registerInfo("#{coil.autosizedRatedHighSpeedTotalCoolingCapacity.get.to_f.class}")
          cap_coils += coil.autosizedRatedHighSpeedTotalCoolingCapacity.get.to_f # sum up capacity across boilers on loop
        end
        runner.registerInfo("dx coil: #{coil}")
        # inlet_node_name = coil.airInletNodeName()
        # need to get inlet and outlet air side nodes and add CHW coil there
        chw_coil = OpenStudio::Model::CoilCoolingWater.new(model)
        chw_coil.autosizeDesignAirFlowRate
        chw_coil.autosizeDesignWaterFlowRate
        chw_coil.setDesignInletWaterTemperature(chw_setpoint_c)
        chw_loop.addDemandBranchForComponent(chw_coil)
        air_loop = coil.airLoopHVAC.get
        mixed_air_node = air_loop.mixedAirNode.get # didnt work to_Node.get()
        runner.registerInfo("mixed air node #{mixed_air_node}")
        coil.remove
        chw_coil.addToNode(mixed_air_node)
        # autosize components of the air loop
        air_loop.autosizeDesignSupplyAirFlowRate
        air_loop_sizing = air_loop.sizingSystem
        air_loop_sizing.autosizeCoolingDesignCapacity
        air_loop_sizing.autosizeHeatingDesignCapacity
      end
    end

    cap_coils_comb = cap_coils + unitary_cap


    ### end of additions for no chw loop case
    # get chw coil's air outlet node

    elec_htg_cap = 0 # track elec htg capacity

    if no_boilers == 0
      hhw_loop_setpoint_sched = OpenStudio::Model::ScheduleConstant.new(model) # , hw_setpoint_c)
      hhw_loop_setpoint_sched.setValue(hw_setpoint_c)
      hhw_loop_setpoint_sched.setName('Hot Water Loop Setpoint')
      # Create HHW loop
      hhw_loop = OpenStudio::Model::PlantLoop.new(model)
      hhw_loop.setName('Hot Water Loop')
      hhw_loop_sizing = hhw_loop.sizingPlant
      hhw_loop_sizing.setLoopType('Heating')

      hhw_loop_sizing.setDesignLoopExitTemperature(hw_setpoint_c) # #AA updated this, averaging the range
      hhw_loop_setpoint_manager = OpenStudio::Model::SetpointManagerScheduled.new(model, hhw_loop_setpoint_sched) # , cond_loop_temp_sch)#need to add a schedule here

      hhw_loop_setpoint_manager.setName('HHW Loop Supply Temp Setpoint Manager')
      hhw_loop_setpoint_manager.addToNode(hhw_loop.supplyOutletNode)
      # #add pump to loop
      pump_hhw_loop = OpenStudio::Model::PumpVariableSpeed.new(model)
      pump_hhw_loop.setName('Hot Water Loop Pump')
      # pump_clg_intermed_loop.setRatedPumpHead(44834.7) # 15 ftf for primary pump for a primary-secondary system based on Appendix G
      pump_hhw_loop.addToNode(hhw_loop.supplyInletNode)
      # set design attributes of HHW loop
      htg_loop_sizing = hhw_loop.sizingPlant
      htg_loop_sizing.setDesignLoopExitTemperature(hw_setpoint_c)
      htg_loop_sizing.setLoopDesignTemperatureDifference(11.1) # AA updated this 9/14
      # create HHW coils in main air loops
      model.getCoilCoolingWaters.each do |coil|
        # get sizes of existing equipmetn
        # create CHW and HHW coils and add to loop
        # autosize water and air flow rates
        coil.autosizeDesignWaterFlowRate
        coil.autosizeDesignAirFlowRate
        runner.registerInfo("coil  #{coil}")
        outlet_node = coil.airOutletModelObject.get.to_Node.get
        runner.registerInfo("coil outlet node #{outlet_node}")
        hhw_coil = OpenStudio::Model::CoilHeatingWater.new(model)
        # hhw_coil.autosizeDesignAirFlowRate()
        hhw_coil.autosizeMaximumWaterFlowRate
        hhw_coil.autosizeUFactorTimesAreaValue
        hhw_coil.setRatedInletWaterTemperature(hw_setpoint_c)
        hhw_coil.setRatedOutletWaterTemperature(hw_setpoint_c - 10)
        hhw_loop.addDemandBranchForComponent(hhw_coil)
        hhw_coil.addToNode(outlet_node)
      end

      model.getCoilHeatingElectrics.each do |coil|
        elec_htg_cap += coil.nominalCapacity.get.to_f
        coil.remove
      end

      i = 0
      model.getAirTerminalSingleDuctParallelPIUReheats.each do |term|
        i += 1
        hhw_coil = OpenStudio::Model::CoilHeatingWater.new(model)
        hhw_coil.setName('reheat coil' + i.to_s)
        # hhw_coil.autosizeDesignAirFlowRate()
        hhw_coil.autosizeMaximumWaterFlowRate
        hhw_coil.autosizeUFactorTimesAreaValue
        hhw_coil.setRatedInletWaterTemperature(hw_setpoint_c)
        hhw_coil.setRatedOutletWaterTemperature(hw_setpoint_c - 10)
        hhw_loop.addDemandBranchForComponent(hhw_coil)
        term.setReheatCoil(hhw_coil)
        term.autosizeMaximumPrimaryAirFlowRate
        term.autosizeMaximumSecondaryAirFlowRate
        term.autosizeMinimumPrimaryAirFlowFraction
        term.autosizeFanOnFlowFraction
        term.autosizeMaximumHotWaterorSteamFlowRate
        fan = term.fan
        fan = fan.to_FanConstantVolume.get
        fan.autosizeMaximumFlowRate
        # term.setReheatCoilObjectType('Coil:Heating:Water')
      end

      # model.getAirTerminalSingleDuctParallelPIUReheats.each do |term|
      # runner.registerInfo("term #{term}")

      # end
      heating_heatpumps = []


      # calculate # of hps required
      working_des_cap_htg = [hp_des_cap_htg * 1000, elec_htg_cap].max

      if working_des_cap_htg > hp_des_cap_htg
        no_hps = (working_des_cap_htg / (hp_des_cap_htg * 1000)).to_f.ceil
        # no_hps = (working_des_cap/(hp_des_cap_htg*1000)).round(0)
        working_hp_cap_htg = hp_des_cap_htg * 1000
      else
        no_hps = 1
        working_hp_cap_htg = elec_htg_cap
      end


      (1..no_hps).each do |hp| # adding heat pumps to the loop
        # create water source heat pump object
        heatpump = OpenStudio::Model::HeatPumpPlantLoopEIRHeating.new(model)
        heatpump.setName('Heating HeatPump' + hp.to_s)
        # if cooling_heatpumps.length() > 0
        # heatpump.setCompanionCoolingHeatPump(cooling_heatpumps[0])
        # cooling_heatpumps[0].setCompanionHeatingHeatPump(heatpump) ##AA revise this for multiple heat pumps
        # end
        heatpump.autosizeLoadSideReferenceFlowRate
        heatpump.autosizeSourceSideReferenceFlowRate
        # AA added the below to auotsize
        # heatpump.autosizeReferenceCapacity
        # heatpump.setReferenceCapacity(hp_des_cap_htg*1000)
        # setting hp capacity
        heatpump.setReferenceCapacity(working_hp_cap_htg)
        # heatpump.setReferenceCoefficientofPerformance(cop)

        hpwh_eir_plr = OpenStudio::Model::CurveQuadratic.new(model)
        hpwh_eir_plr.setName('HPWH-EIR-PLR')
        hpwh_eir_plr.setCoefficient1Constant(hpwh_eir_plr_coefficient1constant)
        hpwh_eir_plr.setCoefficient2x(hpwh_eir_plr_coefficient2x)
        hpwh_eir_plr.setCoefficient3xPOW2(hpwh_eir_plr_coefficient3xPOW2)

        # assigning performance curves to the heat pump
        # heatpump.setCapacityModifierFunctionofTemperatureCurve(hpwh_cap)
        # heatpump.setElectricInputtoOutputRatioModifierFunctionofTemperatureCurve(hpwh_eir)
        heatpump.setElectricInputtoOutputRatioModifierFunctionofPartLoadRatioCurve(hpwh_eir_plr)
        add_lookup_performance_data(model, heatpump, 'hydronic_gshp', 'Carrier_61WG_Glycol_90kW', runner)


        # adding the heat pump to the supply side of the heat pump loop
        # hp_loop.addSupplyBranchForComponent(heatpump) ##AA commented out
        cond_loop.addDemandBranchForComponent(heatpump) # #AA added
        heatpump.setCondenserType('WaterSource')

        # adding the heat pump to the demand side of the ground loop
        # ground_loop.addDemandBranchForComponent(heatpump) ##AA commented out
        # #AA added the below, can refine this later on
        # htg_loop.addSupplyBranchForComponent(heatpump)  ##AA added, assuming only one HHW loop
        intermed_htg_cond_loop.addSupplyBranchForComponent(heatpump) # add heat pump to intermediate loop
        hhw_loop.addSupplyBranchForComponent(inter_htg_heat_exchanger) # #adding intermediate heat exchanger to supply side of heating loop
        heating_heatpumps.append(heatpump)
        # #AA commented out hte below for now
        # model.getPlantLoops.each do |plant_loop|
        # next unless plant_loop.name.get.to_s == 'Hot Water Loop'
        # plant_loop.addSupplyBranchForComponent(heatpump) ##AA added

        # end
      end
    end
    cooling_heatpumps = []

    # deal with electric VAV coils
    # model.getCoilHeatingElectric.each do |coil|
    # runner.registerInfo("coil outlet node#{coil.get.outletNode}")

    # end




    # if no_chillers == 0 && no_unit_sys == false
    # runner.registerAsNotApplicable('No chillers in model and unitary systems present--measure will not be applied.')
    # return true
    # end

    # no chiller case, calculating # of heat pumps required
    working_des_cap_clg = [hp_des_cap_clg * 1000, cap_coils_comb].max
    runner.registerInfo("cap coils comb: #{cap_coils_comb}")

    if working_des_cap_clg > hp_des_cap_clg
      no_hps = (working_des_cap_clg / (hp_des_cap_clg * 1000)).to_f.ceil
      runner.registerInfo("no. hps: #{no_hps}")
      # no_hps = (working_des_cap_clg/(hp_des_cap_clg*1000)).round(0)
      working_hp_cap_clg = hp_des_cap_clg * 1000
    else
      no_hps = 1
      working_hp_cap_clg = cap_coils_comb
    end

    runner.registerInfo("working_hp_cap_clg: #{working_hp_cap_clg}")
    runner.registerInfo("no_hps: #{no_hps}")

    if no_chillers == 0 # && no_unit_sys
      # add heat pump to new CHW loop and source side loop
      # AA added the below to auotsize
      # heatpump.autosizeReferenceCapacity
      (1..no_hps).each do |_hp|
        # Set up curves
        heatpump = OpenStudio::Model::HeatPumpPlantLoopEIRCooling.new(model)
        heatpump.setName('Cooling HeatPump') # #AA modify this later on if using more than one +hp.to_s)
        cooling_heatpumps.append(heatpump)
        heatpump_cooling = heatpump
        # heatpump.setCompanionHeatingHeatPump("Heating HeatPump" +hp.to_s)  ##AA comment this back in later
        heatpump.autosizeLoadSideReferenceFlowRate
        heatpump.autosizeSourceSideReferenceFlowRate
        hpwh_eir_plr = OpenStudio::Model::CurveQuadratic.new(model)
        hpwh_eir_plr.setName('HPWH-EIR-PLR')
        hpwh_eir_plr.setCoefficient1Constant(cooling_hp_plr_coeff1constant)
        hpwh_eir_plr.setCoefficient2x(cooling_hp_plr_coeff2x)
        hpwh_eir_plr.setCoefficient3xPOW2(cooling_hp_plr_coeff3xPOW2)
        heatpump.setReferenceCapacity(working_hp_cap_clg) # (working_hp_cap_clg) ##AA revisit this
        heatpump.setElectricInputtoOutputRatioModifierFunctionofPartLoadRatioCurve(hpwh_eir_plr)
        add_lookup_performance_data(model, heatpump, 'hydronic_gshp', 'Carrier_30WG_90kW', runner)
        # adding the heat pump to the supply side of the heat pump loop
        # hp_loop.addSupplyBranchForComponent(heatpump) ##AA commented out
        heatpump.setCondenserType('WaterSource')
        # adding the heat pump to the demand side of the ground loop
        # ground_loop.addDemandBranchForComponent(heatpump) ##AA commented out
        # #AA added the below, can refine this later on
        chw_loop.addSupplyBranchForComponent(inter_clg_heat_exchanger)  # #may need to modify if multiple heat pumps
        intermed_clg_cond_loop.addSupplyBranchForComponent(heatpump)
        # #AA will need to set this later on
        cond_loop.addDemandBranchForComponent(heatpump) # #AA added
      end
    end
    # end

    # iterate thru CHW loops
    # #AA commented out for now to test HHW side

    # #AA modifying this to iterate thru based on chillers
    # ch_water_loops.each do |loop|
    # loop.supplyComponents.each do |c|
    # cooling_heatpumps = [] #commenting out since defining earlier

    # if no_chillers > 0

    model.getChillerElectricEIRs.sort.each do |chiller|
      cap_chiller = 0
      # if not c.to_ChillerElectricEIR.empty?
      # chiller = c.to_ChillerElectricEIR.get
      # if boiler.nominalCapacity.is_initialized ##AA moved up, 7/12
      runner.registerInfo("nominal name:  #{chiller.name}") # boiler capacity #{boiler.nominalCapacity.get.to_f}")
      # cap_blr += boiler.nominalCapacity.get.to_f #sum up capacity across boilers on loop
      inlet = chiller.supplyInletModelObject.get.to_Node.get # #AA need to modify this approach for multiple boilers
      outlet = chiller.supplyInletModelObject.get.to_Node.get # #AA need to modify this approach for multiple boilers \
      chw_loop = chiller.plantLoop.get
      if chiller.autosizedReferenceCapacity.is_initialized # #AA moved up, 7/12
        runner.registerInfo("nominal name:  #{chiller.name} and #{chiller.autosizedReferenceCapacity.get.to_f}") # boiler capacity #{boiler.nominalCapacity.get.to_f}")
        runner.registerInfo("#{chiller.autosizedReferenceCapacity.get.to_f.class}")
        cap_chiller += chiller.autosizedReferenceCapacity.get.to_f # sum up capacity across boilers on loop
        runner.registerInfo("capacity:  #{cap_chiller}")
      end
      # deal with water-cooled chillers
      runner.registerInfo("condenser type #{chiller.condenserType}")
      if chiller.condenserType == 'WaterCooled'
        chiller_cond_loop = chiller.condenserWaterLoop.get
        runner.registerInfo("chiller cond loop#{chiller_cond_loop}")
        chiller_cond_loop.remove
      end
      chiller.remove

      chw_loop.supplyComponents.each do |sup_comp|
        next unless sup_comp.to_PumpConstantSpeed.is_initialized

        pump = sup_comp.to_PumpConstantSpeed.get # may need to adjust this for different pump types
        runner.registerInfo('at chw pump')
        pump.autosizeRatedFlowRate
        pump.autosizeRatedPowerConsumption
      end


      working_des_cap_clg = [hp_des_cap_clg * 1000, cap_chiller].max
      runner.registerInfo("cap chiller: #{cap_chiller}")

      if working_des_cap_clg > hp_des_cap_clg
        no_hps = (working_des_cap_clg / (hp_des_cap_clg * 1000)).to_f.ceil
        runner.registerInfo("no. hps: #{no_hps}")
        # no_hps = (working_des_cap_clg/(hp_des_cap_clg*1000)).round(0)
        working_hp_cap_clg = hp_des_cap_clg * 1000
      else
        no_hps = 1
        working_hp_cap_clg = cap_chiller
      end
      (1..no_hps).each do |hp| # adding heat pumps to the loop
        # create water source heat pump object
        heatpump = OpenStudio::Model::HeatPumpPlantLoopEIRCooling.new(model)
        heatpump.setName('Cooling HeatPump' + hp.to_s)
        cooling_heatpumps.append(heatpump)
        heatpump_cooling = heatpump
        # heatpump.setCompanionHeatingHeatPump("Heating HeatPump" +hp.to_s)
        heatpump.autosizeLoadSideReferenceFlowRate
        heatpump.autosizeSourceSideReferenceFlowRate
        # AA added the below to auotsize
        # heatpump.autosizeReferenceCapacity
        heatpump.setReferenceCapacity(working_hp_cap_clg)
        # heatpump.setReferenceCapacity(hp_des_cap_htg*1000)
        # heatpump.setReferenceCoefficientofPerformance(cop)


        hpwh_eir_plr = OpenStudio::Model::CurveQuadratic.new(model)
        hpwh_eir_plr.setName('HPWH-EIR-PLR')
        hpwh_eir_plr.setCoefficient1Constant(cooling_hp_plr_coeff1constant)
        hpwh_eir_plr.setCoefficient2x(cooling_hp_plr_coeff2x)
        hpwh_eir_plr.setCoefficient3xPOW2(cooling_hp_plr_coeff3xPOW2)

        # assigning performance curves to the heat pump
        # heatpump.setCapacityModifierFunctionofTemperatureCurve(hpwh_cap)
        # heatpump.setElectricInputtoOutputRatioModifierFunctionofTemperatureCurve(hpwh_eir)
        heatpump.setElectricInputtoOutputRatioModifierFunctionofPartLoadRatioCurve(hpwh_eir_plr)
        add_lookup_performance_data(model, heatpump, 'hydronic_gshp', 'Carrier_30WG_90kW', runner)

        # adding the heat pump to the supply side of the heat pump loop
        # hp_loop.addSupplyBranchForComponent(heatpump) ##AA commented out
        cond_loop.addDemandBranchForComponent(heatpump) # #AA added
        heatpump.setCondenserType('WaterSource')

        # adding the heat pump to the demand side of the ground loop
        # ground_loop.addDemandBranchForComponent(heatpump) ##AA commented out
        # #AA added the below, can refine this later on
        chw_loop.addSupplyBranchForComponent(inter_clg_heat_exchanger)  # #may need to modify if multiple heat pumps
        intermed_clg_cond_loop.addSupplyBranchForComponent(heatpump)
      end

      # Add in heat pump
    end

    # end


    model.getBoilerHotWaters.sort.each do |boiler|
      runner.registerInfo("starting hot water loop #{Time.now}")

      cap_boiler = 0

      # get boilers and then nodes
      # model.getBoilerHotWater.each.do boiler
      # boiler.plantLoop =>optional plant loop
      runner.registerInfo("inside boiler loop #{Time.now} ")
      inlet = boiler.inletModelObject.get.to_Node.get # #AA need to modify this approach for multiple boilers
      outlet = boiler.outletModelObject.get.to_Node.get # #AA need to modify this approach for multiple boilers
      htg_loop = boiler.plantLoop.get
      htg_loop_sizing = htg_loop.sizingPlant
      htg_loop_sizing.setDesignLoopExitTemperature(hw_setpoint_c)
      htg_loop_sizing.setLoopDesignTemperatureDifference(11.1) # AA updated this 9/14
      # set new setpoint for loop
      htg_loop.supplyOutletNode.setpointManagers.each do |spm|
        spm.to_SetpointManagerScheduled.get.setSchedule(sched)
      end
      if boiler.autosizedNominalCapacity.is_initialized # #AA moved up, 7/12
        runner.registerInfo("nominal name:  #{boiler.name} and #{boiler.autosizedNominalCapacity.get.to_f}") # boiler capacity #{boiler.nominalCapacity.get.to_f}")
        runner.registerInfo("#{boiler.autosizedNominalCapacity.get.to_f.class}")
        cap_boiler += boiler.autosizedNominalCapacity.get.to_f # sum up capacity across boilers on loop
        runner.registerInfo("capacity:  #{cap_boiler}")
      end
      boiler.remove

      # make pump on HHW loop auto-sized

      htg_loop.supplyComponents.each do |sup_comp|
        next unless sup_comp.to_PumpVariableSpeed.is_initialized

        pump = sup_comp.to_PumpVariableSpeed.get
        runner.registerInfo('at pump')
        pump.autosizeRatedFlowRate
        pump.autosizeRatedPowerConsumption
      end



      runner.registerInfo("starting hp loop #{Time.now} ")


      working_des_cap_htg = [hp_des_cap_htg * 1000, cap_boiler].max

      if working_des_cap_htg > hp_des_cap_htg
        no_hps = (working_des_cap_htg / (hp_des_cap_htg * 1000)).to_f.ceil
        # no_hps = (working_des_cap/(hp_des_cap_htg*1000)).round(0)
        working_hp_cap_htg = hp_des_cap_htg * 1000
      else
        no_hps = 1
        working_hp_cap_htg = cap_boiler
      end

      # no_hps = 1 ##AA setting it this way for now
      # Ruby time.now() =>print at begining and end of sectoin
      # require Time
      heating_heatpumps = []

      (1..no_hps).each do |hp| # adding heat pumps to the loop
        # create water source heat pump object
        heatpump = OpenStudio::Model::HeatPumpPlantLoopEIRHeating.new(model)
        heatpump.setName('Heating HeatPump' + hp.to_s)
        # if cooling_heatpumps.length() > 0
        # heatpump.setCompanionCoolingHeatPump(cooling_heatpumps[0])
        # cooling_heatpumps[0].setCompanionHeatingHeatPump(heatpump) ##AA revise this for multiple heat pumps
        # end
        heatpump.autosizeLoadSideReferenceFlowRate
        heatpump.autosizeSourceSideReferenceFlowRate
        # AA added the below to auotsize
        # heatpump.autosizeReferenceCapacity
        # heatpump.setReferenceCapacity(hp_des_cap_htg*1000)
        # setting hp capacity
        heatpump.setReferenceCapacity(working_hp_cap_htg)
        # heatpump.setReferenceCoefficientofPerformance(cop)

        hpwh_eir_plr = OpenStudio::Model::CurveQuadratic.new(model)
        hpwh_eir_plr.setName('HPWH-EIR-PLR')
        hpwh_eir_plr.setCoefficient1Constant(hpwh_eir_plr_coefficient1constant)
        hpwh_eir_plr.setCoefficient2x(hpwh_eir_plr_coefficient2x)
        hpwh_eir_plr.setCoefficient3xPOW2(hpwh_eir_plr_coefficient3xPOW2)

        # assigning performance curves to the heat pump
        # heatpump.setCapacityModifierFunctionofTemperatureCurve(hpwh_cap)
        # heatpump.setElectricInputtoOutputRatioModifierFunctionofTemperatureCurve(hpwh_eir)
        heatpump.setElectricInputtoOutputRatioModifierFunctionofPartLoadRatioCurve(hpwh_eir_plr)
        add_lookup_performance_data(model, heatpump, 'hydronic_gshp', 'Carrier_61WG_Glycol_90kW', runner)


        # adding the heat pump to the supply side of the heat pump loop
        # hp_loop.addSupplyBranchForComponent(heatpump) ##AA commented out
        cond_loop.addDemandBranchForComponent(heatpump) # #AA added
        heatpump.setCondenserType('WaterSource')

        # adding the heat pump to the demand side of the ground loop
        # ground_loop.addDemandBranchForComponent(heatpump) ##AA commented out
        # #AA added the below, can refine this later on
        # htg_loop.addSupplyBranchForComponent(heatpump)  ##AA added, assuming only one HHW loop
        intermed_htg_cond_loop.addSupplyBranchForComponent(heatpump) # add heat pump to intermediate loop
        htg_loop.addSupplyBranchForComponent(inter_htg_heat_exchanger) # #adding intermediate heat exchanger to supply side of heating loop
        heating_heatpumps.append(heatpump)
        # #AA commented out hte below for now
        # model.getPlantLoops.each do |plant_loop|
        # next unless plant_loop.name.get.to_s == 'Hot Water Loop'
        # plant_loop.addSupplyBranchForComponent(heatpump) ##AA added

        # end
      end
      runner.registerInfo("end of hp loop #{Time.now} ")
      # adding availability manager to heat pump loop. This is based on users cut-off temperature input
      # AA commented this out
      # low_temp_off = OpenStudio::Model::AvailabilityManagerLowTemperatureTurnOff.new(model)
      # # low_temp_off.setTemperature(hpwh_cutoff_T)
      # low_temp_off.setSensorNode(oa_nodes[0])
      # hp_loop.addAvailabilityManager(low_temp_off) ##AA commented out

      ## End of creating Heat Pump Loop #######
      # AA commenting out the below to deal with later on

      next unless keep_setpoint != true

      # changing hardsized heating coil values by autosizing

      # AA don't need to repeat for cooling, since only heating temp changing
      runner.registerInfo("start of autosizing #{Time.now} ")
      next unless autosize_hc == true # only change coil to autosize if user choose to autosize it

      # model.getPlantLoops.each do |plant_loop| ##AA commented out since this is now in a loop thru the heating loops
      htg_loop.demandComponents.each do |dem_comp| # #AA revised since now in a loop of heating loops
        next unless dem_comp.to_CoilHeatingWater.is_initialized

        h_coil = dem_comp.to_CoilHeatingWater.get
        h_coil.setRatedInletWaterTemperature(hw_setpoint_c) # AA added
        h_coil.setRatedOutletWaterTemperature(hw_setpoint_c - delta_t_coil)
        h_coil.autosizeUFactorTimesAreaValue
        h_coil.autosizeMaximumWaterFlowRate
        h_coil.autosizeRatedCapacity # #AA added 8/10
      end
      htg_loop.autosizeMaximumLoopFlowRate # #AA added 8/10
      htg_loop.autocalculatePlantLoopVolume # #AA added 8/10
      # end ##AA commented out, getting rid of this loop
      # end
      # resize flow rates in vav terminal and autosize airflow rates
      # resize flow rates in vav terminal and air loops generally
      # boiler.remove() ##AA added 7/12
    end

    model.getAirLoopHVACs.each do |air_loop|
      # perform autosizing again after changes to coils
      # resize flow rates in vav terminal and air loops generally
      air_loop.autosizeDesignSupplyAirFlowRate
      air_loop_sizing = air_loop.sizingSystem
      air_loop_sizing.autosizeCoolingDesignCapacity
      air_loop_sizing.autosizeHeatingDesignCapacity
      air_loop.supplyComponents.each do |sup_comp|
        if sup_comp.to_FanVariableVolume.is_initialized
          fan = sup_comp.to_FanVariableVolume.get
          fan.autosizeMaximumFlowRate
        end
      end
      air_loop.demandComponents.each do |dem_comp|
        next unless dem_comp.to_AirTerminalSingleDuctVAVReheat.is_initialized

        term = dem_comp.to_AirTerminalSingleDuctVAVReheat.get
        term.autosizeMaximumHotWaterOrSteamFlowRate
        term.autosizeFixedMinimumAirFlowRate
        term.autosizeMaximumAirFlowRate
      end
    end
    runner.registerInfo("end of autosizing #{Time.now} ")
    # END HARDWARE ----------------------------------------------------------------------------------------------------

    # Register final condition
    # move down
    whs_ic = model.getBoilerHotWaters.size
    hp_ic =  model.getHeatPumpPlantLoopEIRHeatings.size

    runner.registerInfo("main part of measure done  #{Time.now} ")

    runner.registerFinalCondition("The building finished with #{whs_ic} hot water boilers and " \
                                  "and #{hp_ic} heat pump water heater(s).")


    # puts "***********************************"
    # puts "***********************************"
    # puts "Reporting HeatPumpPlantLoopEIRCooling objects"
    # puts "***********************************"
    # model.getHeatPumpPlantLoopEIRCoolings.each do |hp|
    # puts hp
    # end

    # puts "***********************************"
    # puts "***********************************"
    # puts "Reporting HeatPumpPlantLoopEIRHeating objects"
    # puts "***********************************"
    # model.getHeatPumpPlantLoopEIRHeatings.each do |hp|
    # puts hp
    # end

    # puts "***********************************"
    # puts "***********************************"
    # puts "Reporting TableLookup objects"
    # puts "***********************************"
    # model.getTableLookups.each do |table|
    # puts table
    # end

    # puts "***********************************"
    # puts "***********************************"
    # puts "Reporting TableIndependentVariable objects"
    # puts "***********************************"
    # model.getTableIndependentVariables.each do |ind_var|
    # puts ind_var
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
    ground_loads_ts = sql.timeSeries(ann_env_pd, 'Hourly', 'Plant Temperature Source Component Heat Transfer Rate',
                                     'Ground Loop Temperature Source (Ground Heat Exchanger Placeholder)')
    runner.registerInfo("Ground loads = #{ground_loads_ts}")
    if ground_loads_ts.is_initialized
      ground_loads = []
      vals = ground_loads_ts.get.values
      for i in 0..(vals.size - 1)
        ground_loads << vals[i]
      end
    end


    # Calculate maximum load on ground loop
    ground_loads_abs = ground_loads.map { |item| item.abs }
    max_ground_loop_load = ground_loads_abs.max

    # Convert to tons
    max_ground_loop_load_tons = tons_per_watt * max_ground_loop_load
    runner.registerInfo("max ground loop load tons: #{max_ground_loop_load_tons}")

    # source flow rate
    source_side_gpm = source_side_gpm_per_ton * max_ground_loop_load_tons
    source_side_mcs = source_side_gpm * mcs_per_gpm

    # #AA commenting this out for now, 9/14

    # for heatpump in heating_heatpumps
    # heatpump.setSourceSideReferenceFlowRate(source_side_mcs)
    # end

    # for heatpump in cooling_heatpumps
    # heatpump.setSourceSideReferenceFlowRate(source_side_mcs)
    # end


    # Make directory for GHEDesigner simulation
    ghedesigner_run_dir = "#{Dir.pwd}/GHEDesigner"
    FileUtils.mkdir_p(ghedesigner_run_dir) unless File.exist?(ghedesigner_run_dir)

    # Make json input file for GHEDesigner
    borefield_defaults_json_path = "#{File.dirname(__FILE__)}/resources/borefield_defaults.json" # #AA updated for this run
    borefield_defaults = JSON.parse(File.read(borefield_defaults_json_path))
    borefield_defaults['loads'] = {}
    borefield_defaults['loads']['ground_loads'] = ground_loads
    ghe_in_path = "#{ghedesigner_run_dir}/ghedesigner_input.json"
    File.write(ghe_in_path, JSON.pretty_generate(borefield_defaults))
    runner.registerInfo('GHEDesigner input JSON file created.')
    runner.registerInfo("ghe in path: #{ghe_in_path}") # #AA added
    runner.registerInfo("ann env pd #{ann_env_pd}") # #AA added


    # Make system call to run GHEDesigner
    start_time = Time.new
    # TODO: remove conda activate andrew
    # command = "conda activate andrew && ghedesigner '#{ghe_in_path}' '#{ghedesigner_run_dir}'"
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

    # Get some information from borefield inputs to set GHX param values
    pipe_thermal_conductivity_w_per_m_k = borefield_defaults['pipe']['conductivity']

    # Read GHEDesigner simulation summary file
    # Check unit strings for all numeric values in case GHEDesigner changes units
    sim_summary = JSON.parse(File.read("#{ghedesigner_run_dir}/SimulationSummary.json"))
    ghe_sys = sim_summary['ghe_system']

    number_of_boreholes = ghe_sys['number_of_boreholes']

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
    soil_volumetric_heat_capacity_j_per_m3_k = OpenStudio.convert(soil_volumetric_heat_capacity_kj_per_m3_k,
                                                                  'kJ/m^3*K', 'J/m^3*K').get

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
    ghx.setBoreHoleLength(active_borehole_length_m) # Depth of 1 borehole ##AA confirm this is correct
    ghx.setGroundThermalConductivity(soil_thermal_conductivity_w_per_m_k) # W/m-K
    ghx.setGroundThermalHeatCapacity(soil_volumetric_heat_capacity_j_per_m3_k) # J/m3-K
    ghx.setGroundTemperature(soil_undisturbed_ground_temp_c) # C
    ghx.setGroutThermalConductivity(grout_thermal_conductivity_w_per_m_k) # W/m-K
    ghx.setPipeThermalConductivity(pipe_thermal_conductivity_w_per_m_k) # W/m-K
    ghx.setPipeOutDiameter(pipe_outer_diameter_m) # m
    ghx.setUTubeDistance(u_tube_shank_spacing_m) # m
    ghx.setPipeThickness(pipe_thickness_m) # m
    reference_ratio = ghe_sys['borehole_diameter']['value'] / 2 / ghe_sys['active_borehole_length']['value']
    ghx.setGFunctionReferenceRatio(reference_ratio)
    # ghx.setMaximumLengthofSimulation() # TODO


    # ratio of borehole radius (mm) to active length(m)

    # G function
    ghx.removeAllGFunctions # Rempve the default gfunction inputs
    gfunc_data = CSV.read("#{ghedesigner_run_dir}/Gfunction.csv", headers: true)
    gfunc_data.each do |r|
      # ghx.addGFunction(r['ln(t/ts)'].to_f, r['H:79.59'].to_f)    # addGFunction(double gFunctionLN, double gFunctionGValue) ##AA adjust to use csv output
      ghx.addGFunction(r['ln(t/ts)'].to_f, r[1].to_f) # #AA adde dthis
    end

    # Replace temperature source with ground heat exchanger
    ground_loop.addSupplyBranchForComponent(ghx)
    ground_loop.removeSupplyBranchWithComponent(ground_temp_source)

    runner.registerInfo("end of ghx measure #{Time.now} ")

    true
  end
end


# register the measure to be used by the application
HVACHydronicGSHP.new.registerWithApplication
