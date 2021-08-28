local capabilities = require "st.capabilities"
local ZigbeeDriver = require "st.zigbee"
local defaults = require "st.zigbee.defaults"
local socket = require "socket"

local p_time = 0

local pushed_handler = function(driver, device, zb_rx)
	device:emit_event(capabilities.button.button.pushed())
end

local pressed_handler = function(driver, device, zb_rx)
	p_time = socket.gettime()
end

local released_handler = function(driver, device, zb_rx)
	local gap = socket.gettime() - p_time
	p_time = 0
	
	if gap > 10 then
		return
	elseif gap >= 0.5 then
		device:emit_event(capabilities.button.button.held())
	elseif gap >= 0 then
		device:emit_event(capabilities.button.button.pushed())
	end
end

local device_added = function(driver, device)
	device:emit_event(capabilities.button.supportedButtonValues({"pushed", "held"}))
	device:emit_event(capabilities.button.button.pushed())
end

local ikea_button_driver = {
	supported_capabilities = {
		capabilities.button,
		capabilities.battery,
	},
	zigbee_handlers = {
		cluster = {
			[0x0006] = {
				[0x01] = pushed_handler
			},
			[0x0008] = {
				[0x05] = pressed_handler,
				[0x07] = released_handler
			}
		},
	},
	lifecycle_handlers = {
		added = device_added
	}
}

defaults.register_for_default_handlers(ikea_button_driver, {capabilities.battery})
local zigbee_driver = ZigbeeDriver("ikea-shortcut-button", ikea_button_driver)
zigbee_driver:run()