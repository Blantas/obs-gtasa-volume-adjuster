local description = [[Adjusts GTA San Andreas volume automatically to avoid playing copyrighted music.

All the script does is changes in game SFX volume option. It DOES access game's memory and reads/writes it, use at your own caution. Supported versions:
- 1.0
- 1.01 / 2.0 
- Latest Steam version

Changelog:

0.1 - Initial Release

- Blantas]]

local obs = obslua
local ffi = require("ffi")

-- Mem Func Definitions

ffi.cdef[[
typedef void* HANDLE;
typedef int BOOL;
typedef unsigned char BYTE;
typedef unsigned long DWORD;

typedef struct PROCESSENTRY32 {
	DWORD dwSize;
	DWORD cntUsage;
	DWORD th32ProcessID;
	DWORD th32DefaultHeapID;
	DWORD th32ModuleID;
	DWORD cntThreads;
	DWORD th32ParentProcessID;
	long pcPriClassBase;
	DWORD dwFlags;
	char szExeFile[260];
} PROCESSENTRY32;

typedef struct MODULEENTRY32 {
	DWORD dwSize;
	DWORD th32ModuleID;
	DWORD th32ProcessID;
	DWORD GlblcntUsage;
	DWORD ProccntUsage;
	BYTE* modBaseAddr;
	DWORD modBaseSize;
	HANDLE hModule;
	char szModule[256];
	char szExePath[260];
} MODULEENTRY32;

void Sleep(DWORD dwMilliseconds);

HANDLE __stdcall OpenProcess(DWORD dwDesiredAccess, int bInheritHandle, DWORD dwProcessId);
int __stdcall CloseHandle(HANDLE hObject);

typedef PROCESSENTRY32* LPPROCESSENTRY32;
typedef MODULEENTRY32* LPMODULEENTRY32;

BOOL __stdcall Process32Next(HANDLE hSnapshot, LPPROCESSENTRY32 lppe);
BOOL __stdcall Module32Next(HANDLE hSnapshot, LPMODULEENTRY32 lpme);

HANDLE __stdcall CreateToolhelp32Snapshot(DWORD dwFlags, DWORD th32ProcessID);

int __stdcall ReadProcessMemory(HANDLE hProcess, void* lpBaseAddress, void* lpBuffer, size_t nSize, size_t* lpNumberOfBytesRead);
int __stdcall WriteProcessMemory(HANDLE hProcess, void* lpBaseAddress, void* lpBuffer, size_t nSize, size_t* lpNumberOfBytesWritten);

DWORD __stdcall WaitForSingleObject(HANDLE hHandle, DWORD dwMilliseconds);

__declspec(dllimport) short __stdcall GetAsyncKeyState(int vKey);

]];

-- Memory Functions

local C = ffi.C;

function ReadProcessMemory(Process, Address, Cast, Size)
	-- Calculate read size from type if not specified.
	if not (Size) then
		Size = ffi.sizeof(Cast);
	end 
	
	-- Allocate memory to store the result.
	local Buffer = ffi.new("char[?]", Size);
	
	-- Cast the target read address to a pointer.
	local Address = ffi.cast("void*", Address);
	
	-- Invoke WinAPI ReadProcessMemory.
	if (ffi.C.ReadProcessMemory(Process, Address, Buffer, Size, nil) ~= 1) then
		return false;
	end
	
	-- Cast the result and return.
	return ffi.cast(Cast.."*", Buffer);
end

function WriteProcessMemory(Process, Address, Value, Cast, Size)
	-- Calculate write size if not specified.
	if not (Size) then
		Size = ffi.sizeof(Cast);
	end 
	
	-- Create buffer to store write value in.
	local Buffer = ffi.new(Cast.."[?]", Size);
	
	if (type(Value) == "table") then
		Buffer = Value;
	else
		Buffer[0] = Value;
	end
	
	local Address = ffi.cast("void*", Address);
	
	-- Invoke WinAPI WriteProcessMemory.
	return (ffi.C.WriteProcessMemory(Process, Address, Buffer, Size, nil) == 1);
end

function GetProcessID(ExecutableFilename)
	-- Get a handle to the process list.
	local ProcessList = ffi.C.CreateToolhelp32Snapshot(0x2, 0);

	local CurrentProcess = ffi.new("PROCESSENTRY32");
	CurrentProcess.dwSize = ffi.sizeof("PROCESSENTRY32");

	while (ffi.C.Process32Next(ProcessList, CurrentProcess) == 1) do
		--print(ffi.string(CurrentProcess.szExeFile):lower() .. " " .. ExecutableFilename:lower())
		if (ffi.string(CurrentProcess.szExeFile):lower() == ExecutableFilename:lower()) then
			-- Free resources and return the process ID.
			ffi.C.CloseHandle(ProcessList);
			return tonumber(CurrentProcess.th32ProcessID);
		end
	end

	-- Free resources and return nothing.
	ffi.C.CloseHandle(ProcessList);
end

function GetModuleAddress(ProcessID, ModuleFilename)
	-- Get a handle to a list of modules attached to the specified process.
	local ModuleList = ffi.C.CreateToolhelp32Snapshot(0x8, ProcessID);

	local CurrentModule = ffi.new("MODULEENTRY32");
	CurrentModule.dwSize = ffi.sizeof("MODULEENTRY32");

	while (ffi.C.Module32Next(ModuleList, CurrentModule) == 1) do
		if (ffi.string(CurrentModule.szModule):lower() == ModuleFilename:lower()) then
			-- Free resources and return the module base address.
			ffi.C.CloseHandle(ModuleList);
			return tonumber(ffi.cast("DWORD", CurrentModule.modBaseAddr));
		end
	end

	-- Free resources and return nothing.
	ffi.C.CloseHandle(ModuleList);
end

-- Game stuff

local V_100 = 1
local V_101 = 2
local V_SR2 = 3

local SFX = 1
local activeBoxes = 2
local boxId = 3

local gameData = {
	-- { SFX Level, No. of Active Audio Boxes, Audio Box ID }
	[1] = { 0x75FCCC, 0x76DCBC, 0x76DC6C }, -- 1.0 
	[2] = { 0x76234C, 0x77033C, 0x7702EC }, -- 1.01 
	[3] = { 0x7D7374, 0x7FB0FC, 0x7FB0AC }, -- Steam r2
}

local audioZones = { 
	-- { audio zone id, name }
	{ 31, "destr1" },
	{ 32, "Bowl" },
	{ 33, "OVAL" },
	{ 34, "8stad" },
	{ 35, "dirtsta" },
	{ 36, "destr2" },
	{ 74, "Casino" },
	{ 93, "Tricas" },
	{ 118, "MAFACS" },
}

local muted = false
local originalSoundLevel

local gamePID
local gameBase
local Handle

-- OBS Script Settings

local version = V_100
local level = "3"
local defaultLevel = "16"

-- Other

local init = 0

-- Log

function script_log(message)
	obs.script_log(obs.LOG_INFO, message)
end

function findGame() 
	if init >= 3 then
		script_log("Looking for game...")
		gamePID = GetProcessID("gta_sa.exe")
		if not (gamePID) then
			script_log("Game is not running or couldn't be detected.")
		else
			Handle = C.OpenProcess(0x100038, false, gamePID)
			if Handle == nil then
				script_log("Couldn't access the process. Are you running OBS as admin?")
			else
				gameBase = GetModuleAddress(gamePID, "gta_sa.exe")
				--print("Base " .. gameBase)
				originalSoundLevel = getSoundLevel()
				
				obs.timer_remove(findGame)
				obs.timer_add(checkSound, "1000")
				
				script_log('Found game: PID ' .. gamePID)
			end
		end
		init = init + 1
	else
		script_log("Initializing...")
	end
end

function checkSound()
	local zoneFound = false
	--print("Version " .. version .. " - " .. gameBase .. ".")
	--print("Checking " .. (gameBase + gameData[tonumber(version)][2]))
	
	
	local inAudioZone = isInAudioZone()
	if inAudioZone == 255 then
		lostGame()
		return
	elseif inAudioZone == false then
		if zoneFound == false and muted == true then
			setSoundLevel(tonumber(defaultLevel) * 0.0625)
			muted = false
			script_log("Unmuting game...")
		end 
	else
		local zone = getCurrentAudioZone()
		if zone == 255 then
			lostGame()
			return
		end
		
		for _,value in pairs(audioZones) do
			if value[1] == zone then
				if muted == true then
					--print("Already muted")
				else
					--print("Found zone " .. value[2])
					originalSoundLevel = getSoundLevel()
					script_log("Muting game due to " .. value[2] .. " zone.")
					setSoundLevel(tonumber(level) * 0.0625)
					--WriteProcessMemory(Handle, (gameBase + gameData[version][SFX]), (tonumber(level) * 0.0625), "float", 4)
					muted = true
				end
				zoneFound = true
			end
		end
	end

	--print("Sound Level: " .. getSoundLevel())	
end

function lostGame()
	script_log("Game is unreachable.")
	obs.timer_remove(checkSound)
	obs.timer_add(findGame, "1000")
end

-- Checks if player is in any of audio zones

function isInAudioZone()
	local zones = ReadProcessMemory(Handle, (gameBase + gameData[version][activeBoxes]), "int", 4)
	if zones then
		--if zones[0] == 0 then return 0 end
		--return 1
		return (zones[0] > 0)
	end
	return 255
end

-- Get active audio zone id

function getCurrentAudioZone()
	local zone = ReadProcessMemory(Handle, (gameBase + gameData[version][boxId]), "int", 4)
	if zone then
		return zone[0]
	end
	return 255
end

-- Set game's sound level

function setSoundLevel(level)
	WriteProcessMemory(Handle, (gameBase + gameData[version][SFX]), level, "float", 4)
end

-- Get game's sound level

function getSoundLevel()
	local level = ReadProcessMemory(Handle, (gameBase + gameData[version][SFX]), "float", 4)
	if level then
		return level[0]
	end
	return 255
end

-- OBS Stuff

function script_description()
	return description
end

function script_load(settings) 
	script_log("Script loaded.")
	
	init = init + 1
	
	obs.timer_add(findGame, "1000")
end

function script_unload()
	--script_log("Script unloaded.")
	--obs.timer_remove(findGame)
end

function script_properties()
	local props = obs.obs_properties_create()
	
	local v = obs.obs_properties_add_list(props, "version", "Game Version", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
	--obs.obs_property_list_add_string(v, "Automatic", "auto")
	obs.obs_property_list_add_string(v, "1.0", V_100)
	obs.obs_property_list_add_string(v, "1.01", V_101)
	--obs.obs_property_list_add_string(v, "2.0", "20")
	obs.obs_property_list_add_string(v, "Steam r2", V_SR2)
	--obs.obs_property_set_long_description(v, "If you're unsure, choose automatic.")
		
	local l = obs.obs_properties_add_list(props, "level", "Adjust SFX volume to level", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
	obs.obs_property_list_add_string(l, "Mute", "0")
	obs.obs_property_list_add_string(l, "1 / 16", "1")
	obs.obs_property_list_add_string(l, "2 / 16", "2")
	obs.obs_property_list_add_string(l, "3 / 16", "3")
	obs.obs_property_list_add_string(l, "4 / 16", "4")
	obs.obs_property_list_add_string(l, "5 / 16", "5")
	obs.obs_property_list_add_string(l, "6 / 16", "6")
	obs.obs_property_list_add_string(l, "7 / 16", "7")
	obs.obs_property_list_add_string(l, "8 / 16", "8")
	obs.obs_property_list_add_string(l, "9 / 16", "9")
	obs.obs_property_list_add_string(l, "10 / 16", "10")
	obs.obs_property_list_add_string(l, "11 / 16", "11")
	obs.obs_property_list_add_string(l, "12 / 16", "12")
	obs.obs_property_list_add_string(l, "13 / 16", "13")
	obs.obs_property_list_add_string(l, "14 / 16", "14")
	obs.obs_property_list_add_string(l, "15 / 16", "15")
	obs.obs_property_list_add_string(l, "16 / 16", "16")
	obs.obs_property_set_long_description(l, "Only real values from in-game settings are available.")
	
	local d = obs.obs_properties_add_list(props, "defaultLevel", "Default SFX volume level", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
	obs.obs_property_list_add_string(d, "Mute", "0")
	obs.obs_property_list_add_string(d, "1 / 16", "1")
	obs.obs_property_list_add_string(d, "2 / 16", "2")
	obs.obs_property_list_add_string(d, "3 / 16", "3")
	obs.obs_property_list_add_string(d, "4 / 16", "4")
	obs.obs_property_list_add_string(d, "5 / 16", "5")
	obs.obs_property_list_add_string(d, "6 / 16", "6")
	obs.obs_property_list_add_string(d, "7 / 16", "7")
	obs.obs_property_list_add_string(d, "8 / 16", "8")
	obs.obs_property_list_add_string(d, "9 / 16", "9")
	obs.obs_property_list_add_string(d, "10 / 16", "10")
	obs.obs_property_list_add_string(d, "11 / 16", "11")
	obs.obs_property_list_add_string(d, "12 / 16", "12")
	obs.obs_property_list_add_string(d, "13 / 16", "13")
	obs.obs_property_list_add_string(d, "14 / 16", "14")
	obs.obs_property_list_add_string(d, "15 / 16", "15")
	obs.obs_property_list_add_string(d, "16 / 16", "16")
	obs.obs_property_set_long_description(l, "Only real values from in-game settings are available.")

	return props
end

function script_defaults(settings)
	script_log("Default settings loaded.")
	
	--obs.obs_data_set_default_string(settings, "version", "auto")
	obs.obs_data_set_default_string(settings, "version", V_100)
	obs.obs_data_set_default_string(settings, "level", "3")
	
	obs.obs_data_set_default_string(settings, "defaultLevel", "16")
	
	init = init + 1
end

function script_update(settings)
	script_log("Settings updated.")
	
	version = tonumber(obs.obs_data_get_string(settings, "version"))
	level = obs.obs_data_get_string(settings, "level")
	defaultLevel = obs.obs_data_get_string(settings, "defaultLevel")
	
	if init < 3 then
		init = init + 1
	end
end