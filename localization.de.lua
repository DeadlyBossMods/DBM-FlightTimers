if GetLocale() ~= "deDE" then return end
local L

L = DBM:GetModLocalization("FlightTimers")

L:SetGeneralLocalization({
	name = "Flug Timer"
})

L:SetOptionLocalization({
	TimerOption = "Timer für Flüge",
	TimerViaOption = "Timer für Zwischenstopps anzeigen",
})

L:SetTimerLocalization({
	["Via %s"] = "Über %s",
})