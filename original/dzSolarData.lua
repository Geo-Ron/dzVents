--[[
	Prerequisits
	==================================
	Requires Domoticz v3.8551 or later
	Platform independent

	CHANGE LOG: See http://www.domoticz.com/forum/viewtopic.php?t=19220 

Virtual Lux sensor and other real-time solar data

-- Authors  ----------------------------------------------------------------
	V1.0 - Sébastien Joly - Great original work
	V1.1 - Neutrino - Adaptation to Domoticz
	V1.2 - Jmleglise - An acceptable approximation of the lux below 1° altitude for Dawn and dusk + translation + several changes to be more userfriendly.
	V1.3 - Jmleglise - No update of the Lux data when <=0 to get the sunset and sunrise with lastUpdate
	V1.4 - use the API instead of updateDevice to update the data of the virtual sensor to be able of using devicechanged['Lux'] in our scripts. (Due to a bug in Domoticz that doesn't catch the devicechanged event of the virtual sensor)
	V1.5 - xces - UTC time calculation.
	V2.0 - BakSeeDaa - Converted to dzVents and changed quite many things.
	V2.4.1-DarkSky - oredin - Use Dark Sky API instead of WU API
]]--

-- Variables to customize ------------------------------------------------
local city = 'HAMONT'					-- Only for log purpose
local countryCode = 'BE'							-- Only for log purpose
local idxSolarAzimuth = 116						-- (Integer) Virtual Azimuth Device ID
local idxSolarAltitude = 117					-- (Integer) Your virtual Solar Altitude Device I
-- local wuAPIkey = '92ebf28146f4d93d'		-- Weather Underground API Key
local dsAPIkey = '5cdc6810ab9c6006e1147c1dbd7d3ef5'		-- Dark Sky API Key
local WMOID = '06377'									-- (String) Nearest synop station for ogimet.
local logToFile = false									-- (Boolean) Set to true if you also wish to log to a file. It might get big by time. 
local tmpLogFile = '/tmp/logSun.txt'-- Logging to this file if logging to file is activated
local fetchIntervalDayMins = 15 -- Day time scraping interval. Never set this below 4 if you have a free WU API account.
local fetchIntervalNightMins = 30 -- Night time scraping interval. 

-- Optional Domoticz devices
local idxLux = 115 -- (Integer) Domoticz virtual Lux device ID
local idxCloudCover = 118 -- (Integer) Domoticz Cloud Cover (PERCENTAGE TYPE) sensor device ID
--local idxPressure = nil -- (Integer) Device ID of your Pressure Device if you have one. Not striclty needed since the script take the Dark Sky value by default


local latitude = 51.247907	-- Latitude. (Decimal number) Decimal Degrees. E.g. something like 51.748485
local longitude = 5.543212	-- Longitude. (Decimal number) Decimal Degrees. E.g.something like 5.629728. 51.247907, 5.543212
local altitude = 40	-- Altitude. (Integer) Meters above sea level.


-- Please don't make any changes below this line (Except for setting logging level)
local scriptName = 'solarData'
local scriptVersion = '2.4.1-DarkSky'

return {
	active = true,
	logging = {
		-- level = domoticz.LOG_DEBUG, -- Uncomment to override the dzVents global logging setting
		marker = scriptName..' '..scriptVersion
	},
	on = {
		timer = {
			'every '..tostring(fetchIntervalDayMins)..' minutes at daytime',
			'every '..tostring(fetchIntervalNightMins)..' minutes at nighttime',
		},
		httpResponses = {
			scriptName..'DS',
		},
	},
	data = {
		lastOkta = {initial=0}
	},
	execute = function(domoticz, item)

		if item.isTimer then
			local url = 'https://api.darksky.net/forecast/'..dsAPIkey..'/'..latitude..','..longitude..'?exclude=minutely,hourly,daily,alerts,flags&lang=fr&units=ca'
			domoticz.log('Requesting new weather data from Dark Sky API...', domoticz.LOG_DEBUG)
			domoticz.log('URL used: '..url, domoticz.LOG_DEBUG)
			domoticz.openURL({url = url, method = 'GET', callback = scriptName..'DS'}).afterSec(10)
		end

		if not item.isHTTPResponse then return end
        	local response = item
        
		if response.trigger ~= scriptName..'DS' then return end
		domoticz.log('Dark Sky API json data has been received', domoticz.LOG_DEBUG)

		local function leapYear(year)   
			return year%4==0 and (year%100~=0 or year%400==0)
		end

		local dsAPIData = response.json
		if not dsAPIData then
			domoticz.log('Could not find any dsAPIData in the DS API response', domoticz.LOG_ERROR)
			return
		end

		local arbitraryTwilightLux = 6.32 -- W/m² egal 800 Lux (the theoritical value is 4.74 but I have more accurate result with 6.32...)
		local constantSolarRadiation = 1361 -- Solar Constant W/m²

		-- In case of that latitude, longitude and altitude has not been defined in the configuration,
		-- we simply use the values that is returned for the current observation location.
		-- Reading longitude, latitude and altitude from the observation_location instead of from 
		-- display_location. API documentation is not so clear about what display_location is.
		if not latitude then
		    domoticz.log('You must change the latitude value !', domoticz.LOG_ERROR)
		    return
		end
		if not longitude then
		    domoticz.log('You must change the longitude value !', domoticz.LOG_ERROR)
		    return
		end
		if not altitude then
		    domoticz.log('You must change the altitude value !', domoticz.LOG_ERROR)
		    return
		end

		local relativePressure = dsAPIData.currently.pressure -- if you have an another way to get the Pressure, (local barometer ...) then you may optimize the script
		if idxPressure and domoticz.devices(idxPressure).barometer then
		    relativePressure = domoticz.devices(idxPressure).barometer
		end

		local year = os.date('%Y')
		local numOfDay = os.date('%j')
		local nbDaysInYear = (leapYear(year) and 366 or 365)

		local angularSpeed = 360/365.25
		local declination = math.deg(math.asin(0.3978 * math.sin(math.rad(angularSpeed) *(numOfDay - (81 - 2 * math.sin((math.rad(angularSpeed) * (numOfDay - 2))))))))
		local timeDecimal = (os.date('!%H') + os.date('!%M') / 60) -- Coordinated Universal Time  (UTC)
		local solarHour = timeDecimal + (4 * longitude / 60 )    -- The solar Hour
		local hourlyAngle = 15 * ( 12 - solarHour )          -- hourly Angle of the sun
		local sunAltitude = math.deg(math.asin(math.sin(math.rad(latitude))* math.sin(math.rad(declination)) + math.cos(math.rad(latitude)) * math.cos(math.rad(declination)) * math.cos(math.rad(hourlyAngle))))-- the height of the sun in degree, compared with the horizon

		local azimuth = math.acos((math.sin(math.rad(declination)) - math.sin(math.rad(latitude)) * math.sin(math.rad(sunAltitude))) / (math.cos(math.rad(latitude)) * math.cos(math.rad(sunAltitude) ))) * 180 / math.pi -- deviation of the sun from the North, in degree
		local sinAzimuth = (math.cos(math.rad(declination)) * math.sin(math.rad(hourlyAngle))) / math.cos(math.rad(sunAltitude))
		if(sinAzimuth<0) then azimuth=360-azimuth end
		local sunstrokeDuration = math.deg(2/15 * math.acos(- math.tan(math.rad(latitude)) * math.tan(math.rad(declination)))) -- duration of sunstroke in the day . Not used in this calculation.
		local RadiationAtm = constantSolarRadiation * (1 +0.034 * math.cos( math.rad( 360 * numOfDay / nbDaysInYear ))) -- Sun radiation  (in W/m²) in the entrance of atmosphere.
		-- Coefficient of mitigation M
		local absolutePressure = relativePressure - domoticz.utils.round((altitude/ 8.3),1) -- hPa
		local sinusSunAltitude = math.sin(math.rad(sunAltitude))
		local M0 = math.sqrt(1229 + math.pow(614 * sinusSunAltitude,2)) - 614 * sinusSunAltitude
		local M = M0 * relativePressure/absolutePressure

		domoticz.log('', domoticz.LOG_INFO)
		domoticz.log('==============  SUN  LOG ==================', domoticz.LOG_INFO)
		domoticz.log(city .. 'latitude: ' .. latitude .. ', longitude: ' .. longitude, domoticz.LOG_INFO)
		domoticz.log('Home altitude = ' .. tostring(altitude) .. ' m', domoticz.LOG_DEBUG)
		domoticz.log('Angular Speed = ' .. angularSpeed .. ' per day', domoticz.LOG_DEBUG)
		domoticz.log('Declination = ' .. declination .. '°', domoticz.LOG_DEBUG)
		domoticz.log('Universal Coordinated Time (UTC) '.. timeDecimal ..' H.dd', domoticz.LOG_DEBUG)
		domoticz.log('Solar Hour '.. solarHour ..' H.dd', domoticz.LOG_DEBUG)
		domoticz.log('Altitude of the sun = ' .. sunAltitude .. '°', domoticz.LOG_INFO)
		domoticz.log('Angular hourly = '.. hourlyAngle .. '°', domoticz.LOG_DEBUG)
		domoticz.log('Azimuth of the sun = ' .. azimuth .. '°', domoticz.LOG_INFO)
		domoticz.log('Duration of the sun stroke of the day = ' .. domoticz.utils.round(sunstrokeDuration,2) ..' H.dd', domoticz.LOG_DEBUG)
		domoticz.log('Radiation max in atmosphere = ' .. domoticz.utils.round(RadiationAtm,2) .. ' W/m²', domoticz.LOG_DEBUG)
		domoticz.log('Local relative pressure = ' .. relativePressure .. ' hPa', domoticz.LOG_DEBUG)
		domoticz.log('Absolute pressure in atmosphere = ' .. absolutePressure .. ' hPa', domoticz.LOG_DEBUG)
		domoticz.log('Coefficient of mitigation M = ' .. M ..' M0 = '..M0, domoticz.LOG_DEBUG)
		domoticz.log('', domoticz.LOG_INFO)

		local okta = dsAPIData.currently.cloudCover
		-- We store the last fetched value here to be used as a backup value
		domoticz.log('Using the newly fetched cloud cover value: '..okta..' with UTC timestamp: '..dsAPIData.currently.time, domoticz.LOG_DEBUG)
		domoticz.data.lastOkta = okta

		local Kc = 1-0.75*math.pow(okta,3.4)  -- Factor of mitigation for the cloud layer

		local directRadiation, scatteredRadiation, totalRadiation, Lux, weightedLux
		if sunAltitude > 1 then -- Below 1° of Altitude , the formulae reach their limit of precision.
			directRadiation = RadiationAtm * math.pow(0.6,M) * sinusSunAltitude
			scatteredRadiation = RadiationAtm * (0.271 - 0.294 * math.pow(0.6,M)) * sinusSunAltitude
			totalRadiation = scatteredRadiation + directRadiation
			Lux = totalRadiation / 0.0079  -- Radiation in Lux. 1 Lux = 0,0079 W/m²
			weightedLux = Lux * Kc   -- radiation of the Sun with the cloud layer
		elseif sunAltitude <= 1 and sunAltitude >= -7  then -- apply theoretical Lux of twilight
			directRadiation = 0
			scatteredRadiation = 0
			arbitraryTwilightLux=arbitraryTwilightLux-(1-sunAltitude)/8*arbitraryTwilightLux
			totalRadiation = scatteredRadiation + directRadiation + arbitraryTwilightLux 
			Lux = totalRadiation / 0.0079  -- Radiation in Lux. 1 Lux = 0,0079 W/m²
			weightedLux = Lux * Kc   -- radiation of the Sun with the cloud layer
		elseif sunAltitude < -7 then  -- no management of nautical and astronomical twilight...
			directRadiation = 0
			scatteredRadiation = 0
			totalRadiation = 0
			Lux = 0
			weightedLux = 0  --  should be around 3,2 Lux for the nautic twilight. Nevertheless.
		end

		domoticz.log('Okta = '..okta, domoticz.LOG_INFO)
		domoticz.log('Kc = ' .. Kc, domoticz.LOG_DEBUG)
		domoticz.log('Direct Radiation = '.. domoticz.utils.round(directRadiation,2) ..' W/m²', domoticz.LOG_INFO)
		domoticz.log('Scattered Radiation = '.. domoticz.utils.round(scatteredRadiation,2) ..' W/m²', domoticz.LOG_DEBUG)
		domoticz.log('Total radiation = ' .. domoticz.utils.round(totalRadiation,2) ..' W/m²', domoticz.LOG_DEBUG)
		domoticz.log('Total Radiation in lux = '.. domoticz.utils.round(Lux,2)..' Lux', domoticz.LOG_DEBUG)
		domoticz.log('Total weighted lux  = '.. domoticz.utils.round(weightedLux,2)..' Lux', domoticz.LOG_INFO)

		-- No update if Lux is already 0. So lastUpdate of the Lux sensor will keep the time when Lux has reached 0.
		-- (Kind of timeofday['SunsetInMinutes'])
		if idxLux and domoticz.devices(idxLux).lux + domoticz.utils.round(weightedLux, 0) > 0 then
			domoticz.devices(idxLux).updateLux(domoticz.utils.round(weightedLux,0))
		end
		domoticz.devices(idxSolarAzimuth).updateCustomSensor(domoticz.utils.round(azimuth,0))
		domoticz.devices(idxSolarAltitude).updateCustomSensor(domoticz.utils.round(sunAltitude,0))
		local oktaPercent = domoticz.utils.round(okta*100)
		local fetchIntervalMins = (domoticz.time.matchesRule('at daytime') and fetchIntervalDayMins or fetchIntervalNightMins)
		if idxCloudCover and ((domoticz.devices(idxCloudCover).percentage ~= oktaPercent)
		or (domoticz.devices(idxCloudCover).lastUpdate.minutesAgo >= (60 - fetchIntervalMins))) then
			domoticz.devices(idxCloudCover).updatePercentage(oktaPercent)
		end 

		if logToFile then
			local logDebug = os.date('%Y-%m-%d %H:%M:%S',os.time())
			logDebug=logDebug..' Azimuth:' .. azimuth .. ' Height:' .. sunAltitude
			logDebug=logDebug..' cloud cover:' .. okta..'  KC:'.. Kc
			logDebug=logDebug..' Direct:'..directRadiation..' inDirect:'..scatteredRadiation..' TotalRadiation:'..totalRadiation..' LuxCloud:'.. domoticz.utils.round(weightedLux,2)
			os.execute('echo '..logDebug..' >>'..tmpLogFile)  -- compatible Linux & Windows
		end

	end
}