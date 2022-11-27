-- Copyright 2022 iquix
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

local CONFIGURATION = {
  -- Defines parameter values to send when the device is paired
  {parameter_number = 151, size = 2, configuration_value = 3},
  {parameter_number = 152, size = 2, configuration_value = 3},
}

local PARAMETERS = {
  -- Parameters map of Fibaro RGBW2
  powerRecovery = {parameter_number = 1, size = 1},
  
  input1Type = {parameter_number = 20, size = 1},
  input2Type = {parameter_number = 21, size = 1},
  input3Type = {parameter_number = 22, size = 1},
  input4Type = {parameter_number = 23, size = 1},
  
  powerReportingFrequency = {parameter_number = 62, size = 2},
  analogReportingThreshold = {parameter_number = 63, size = 2},
  analogReportingFrequency = {parameter_number = 64, size = 2},
  
  inputsMode = {parameter_number = 150, size = 1},
  dimmerRampRateLocal = {parameter_number = 151, size = 2},
  dimmerRampRateRemote = {parameter_number = 152, size = 2},
}


local params = {}

params.device_configuration = CONFIGURATION
params.device_parameters = PARAMETERS

params.to_numeric_value = function(new_value)
  local numeric = tonumber(new_value)
  if numeric == nil then -- in case the value is boolean
    numeric = new_value and 1 or 0
  end
  return numeric
end

return params