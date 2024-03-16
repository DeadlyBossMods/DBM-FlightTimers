if GetLocale() ~= "ruRU" then return end
local L

L = DBM:GetModLocalization("FlightTimers")

L:SetGeneralLocalization({
	name = "Таймеры полета",
	Via  = "Через %s",
})

L:SetOptionLocalization({
	TimerOption = "Таймер для полетов",
	TimerViaOption = "Показывать таймеры для промежуточных остановок",
})
