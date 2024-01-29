# ComStock™, Copyright (c) 2023 Alliance for Sustainable Energy, LLC. All rights reserved.
# See top level LICENSE.txt file for license terms.

# see the URL below for information on how to write OpenStudio measures
# http://nrel.github.io/OpenStudio-user-documentation/measures/measure_writing_guide/

require 'csv'
require 'openstudio'
require 'json'

# start the measure
class BuildExistingModel < OpenStudio::Measure::ModelMeasure

  # human readable name
  def name
    return "Build Existing Model"
  end

  # human readable description
  def description
    return "Builds the OpenStudio Model for an existing building."
  end

  # human readable description of modeling approach
  def modeler_description
    return "Builds the OpenStudio Model using the sampling csv file, which contains the specified parameters for each existing building. Based on the supplied building number, those parameters are used to run the OpenStudio measures with appropriate arguments and build up the OpenStudio model."
  end

  # define the arguments that the user will input
  def arguments(model)
    args = OpenStudio::Measure::OSArgumentVector.new

    building_id = OpenStudio::Ruleset::OSArgument.makeIntegerArgument("building_id", true)
    building_id.setDisplayName("Building ID")
    building_id.setDescription("The building number (between 1 and the number of samples).")
    args << building_id

    number_of_buildings_represented = OpenStudio::Ruleset::OSArgument.makeIntegerArgument("number_of_buildings_represented", false)
    number_of_buildings_represented.setDisplayName("Number of Buildings Represented")
    number_of_buildings_represented.setDescription("The total number of buildings represented by the existing building models.")
    args << number_of_buildings_represented

    workflow_json = OpenStudio::Ruleset::OSArgument.makeStringArgument("workflow_json", false)
    workflow_json.setDisplayName("Workflow JSON")
    workflow_json.setDescription("The name of the JSON file (in the resources dir) that dictates the order in which measures are to be run. If not provided, the order specified in resources/options_lookup.tsv will be used.")
    args << workflow_json

    return args
  end

  # define what happens when the measure is run
  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)

    # use the built-in error checking
    if !runner.validateUserArguments(arguments(model), user_arguments)
      return false
    end

    building_id = runner.getIntegerArgumentValue("building_id",user_arguments)
    number_of_buildings_represented = runner.getOptionalIntegerArgumentValue("number_of_buildings_represented",user_arguments)
    workflow_json = runner.getOptionalStringArgumentValue("workflow_json", user_arguments)

    # Get file/dir paths
    runner.registerInfo "Running in worker container `#{ENV['HOSTNAME']}`"
    resources_dir = File.absolute_path(File.join(File.dirname(__FILE__), "..", "..", "lib", "resources")) # Should have been uploaded per 'Additional Analysis Files' in PAT
    characteristics_dir = File.absolute_path(File.join(File.dirname(__FILE__), "..", "..", "lib", "housing_characteristics")) # Should have been uploaded per 'Additional Analysis Files' in PAT
    buildstock_file = File.join(resources_dir, "buildstock.rb")
    measures_dir = File.join(resources_dir, "measures")
    lookup_file = File.join(resources_dir, "options_lookup.tsv")
    # FIXME: Temporary
    buildstock_csv = File.absolute_path(File.join(characteristics_dir, "buildstock.csv")) # Should have been generated by the Worker Initialization Script (run_sampling.rb) or provided by the project
    if workflow_json.is_initialized
      workflow_json = File.join(resources_dir, workflow_json.get)
    else
      workflow_json = nil
    end

    # Load buildstock file
    require File.join(File.dirname(buildstock_file), File.basename(buildstock_file, File.extname(buildstock_file)))

    # Check file/dir paths exist
    check_dir_exists(measures_dir, runner)
    check_file_exists(lookup_file, runner)
    check_file_exists(buildstock_csv, runner)

    # Retrieve all data associated with sample number
    bldg_data = get_data_for_sample(buildstock_csv, building_id, runner)
    runner.registerInfo("bldg_data: #{bldg_data}")

    # Assign all building parameters from buildstock.csv to building as additional properties
    bldg_data.each do |k, v|
      model.getBuilding.additionalProperties.setFeature(k, v)
    end

    # Retrieve order of parameters to run
    parameters_ordered_superset = get_parameters_ordered_from_options_lookup_tsv(resources_dir, nil)
    if parameters_ordered_superset.empty?
      runner.registerError('No parameters were found.  Ensure that the options_lookup.tsv file is available in the /resources directory.')
      return false
    end

    # Obtain measures and arguments to be called
    measures = {}
    parameters_ordered = []
    parameters_ordered_superset.each do |parameter_name|
      # Get measure name and arguments associated with the option
      option_name = bldg_data[parameter_name]
      # Check that this parameter exists in the tsv
      if option_name.nil?
        runner.registerWarning("Could not find options for a parameter called '#{parameter_name}' in options_lookup.tsv. This could be an error (or not, if it's regarding an upgrade.) Check the tsv for typos and make sure that the parameter names in options_lookup.tsv match those in buildstock.csv.")
        next
      end
      print_option_assignment(parameter_name, option_name, runner)
      register_value(runner, parameter_name, option_name)
      parameters_ordered << parameter_name
      #
      # get_measure_args_from_option_name(lookup_file, option_name, parameter_name, runner).each do |measure_subdir, args_hash|
      #   if not measures.has_key?(measure_subdir)
      #     measures[measure_subdir] = {}
      #   else
      #     # Relocate to the end of the hash
      #     measures[measure_subdir] = measures.delete(measure_subdir)
      #   end
      #   # Append args_hash to measures[measure_subdir]
      #   args_hash.each do |k, v|
      #     measures[measure_subdir][k] = v
      #   end
      # end
    end

    # # Do the downselecting
    # if downselect_logic.is_initialized
    #
    #   downselect_logic = downselect_logic.get
    #   downselect_logic = downselect_logic.strip
    #   downselected = evaluate_logic(downselect_logic, runner, past_results = false)
    #
    #   if downselected.nil?
    #     return false
    #   end
    #
    #   unless downselected
    #     # Not in downselection; don't run existing home simulation
    #     runner.registerInfo("Sample is not in downselected parameters; will be registered as invalid.")
    #     runner.haltWorkflow('Invalid')
    #     return false
    #   end
    # end

    parameters_ordered.each do |parameter_name|
      option_name = bldg_data[parameter_name]
      print_option_assignment(parameter_name, option_name, runner)
      options_measure_args = get_measure_args_from_option_names(lookup_file, [option_name], parameter_name, runner)
      options_measure_args[option_name].each do |measure_subdir, args_hash|
        update_args_hash(measures, measure_subdir, args_hash, add_new = false)
      end
    end

    if not apply_measures(measures_dir, measures, runner, model, workflow_json, "measures.osw", true)
      return false
    end

    # Determine weight
    if not number_of_buildings_represented.nil?
        total_samples = 100 # Temporary
        #total_samples = runner.analysis[:analysis][:problem][:algorithm][:number_of_samples].to_f
        weight = number_of_buildings_represented.get / total_samples
        register_value(runner, "weight", weight.to_s)
    end

    return true

  end

  def get_data_for_sample(buildstock_csv, building_id, runner)
    CSV.foreach(buildstock_csv, headers:true) do |sample|
        next if sample[0].to_i != building_id
        return sample
    end
    # If we got this far, couldn't find the sample #
    msg = "Could not find row for #{building_id.to_s} in #{File.basename(buildstock_csv).to_s}."
    runner.registerError(msg)
    fail msg
  end

end

# register the measure to be used by the application
BuildExistingModel.new.registerWithApplication
