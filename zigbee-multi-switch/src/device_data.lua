local device_data = {}

device_data.endpoints = {
	["ShinaSystem/SBM300Z1"] = {1},
	["ShinaSystem/SBM300Z2"] = {1,2},
	["ShinaSystem/SBM300Z3"] = {1,2,3},
	["ShinaSystem/SBM300Z4"] = {1,2,3,4},
	["ShinaSystem/SBM300Z5"] = {1,2,3,4,5},
	["ShinaSystem/SBM300Z6"] = {1,2,3,4,5,6},
	["ShinaSystem/ISM300Z3"] = {1,2,3},
	["_TYZB01_vkwryfdr/TS0115"] = {1,2,3,4,7},
}

device_data.is_polling_manufacturer = {
	["ORVIBO"] = true,
	["_TZ3000_fvh3pjaz"] = true,
	["_TZ3000_wyhuocal"] = true,
}

return device_data

