--[[
    Infocyte Extension
    Name: Recover Files
    Type: Action
    Description: Recover list of files and folders to S3. Will bypass most file locks.
    Author: Infocyte
    Guid: 55f3d0f0-476a-44fe-a583-21e110c74541
    Created: 20191123
    Updated: 20191123 (Gerritz)
--]]


--[[ SECTION 1: Inputs --]]

-- S3 Bucket (mandatory)
s3_user = nil
s3_pass = nil
s3_region = 'us-east-2' -- 'us-east-2'
s3_bucket = 'test-extensions' -- 'test-extensions'
s3path_modifier = "evidence" -- /filename will be appended 
--S3 Path Format: <s3bucket>:<instancename>/<date>/<hostname>/<s3path_modifier>/<filename>

-- Proxy (optional)
proxy = nil -- "myuser:password@10.11.12.88:8888"

-- Powerforensics will be used to bypass file locks
use_powerforensics = true

-- Provide paths below (full file path or folders). Folders will take everything
-- in the folder.
-- Format them any of the following ways
-- NOTE: '\' needs to be escaped unless you make a explicit string like this: [[string]])
if hunt.env.is_windows() then
    paths = {
        [[c:\windows\system32\calc.exe]],
        'c:\\windows\\system32\\notepad.exe',
        'c:\\windows\\temp\\infocyte\\',
        "c:\\users\\adama\\ntuser.dat"
    }
else
    -- If linux or mac
    paths = {
        '/bin/cat'
    }
end


--[[ SECTION 2: Functions --]]

function path_exists(path)
    -- Check if a file or directory exists in this path
    -- add '/' on end to test if it is a folder
   local ok, err = os.rename(path, path)
   if not ok then
      if err == 13 then
         -- Permission denied, but it exists
         return true
      end
   end
   return ok, err
end

-- Infocyte Powershell Functions --
powershell = {}
function powershell.run_cmd(command)
    --[[
        Input:  [String] Small Powershell Command
        Output: [Bool] Success
                [String] Output
    ]]
    if not hunt.env.has_powershell() then
        hunt.error("Powershell not found.")
        throw "Powershell not found."
    end

    if not command or (type(command) ~= "string") then 
        hunt.error("Required input [String]command not provided.")
        throw "Required input [String]command not provided."
    end

    print("Initiatializing Powershell to run Command: "..command)
    cmd = ('powershell.exe -nologo -nop -command "& {'..command..'}"')
    pipe = io.popen(cmd, "r")
    output = pipe:read("*a") -- string output
    ret = pipe:close() -- success bool
    return ret, output
end

function powershell.run_script(psscript)
    --[[
        Input:  [String] Powershell script. Ideally wrapped between [==[ ]==] to avoid possible escape characters.
        Output: [Bool] Success
                [String] Output
    ]]
    if not hunt.env.has_powershell() then
        hunt.error("Powershell not found.")
        throw "Powershell not found."
    end

    if not psscript or (type(psscript) ~= "string") then 
        hunt.error("Required input [String]script not provided.")
        throw "Required input [String]script not provided."
    end

    print("Initiatializing Powershell to run Script")
    tempfile = os.getenv("systemroot").."\\temp\\icpowershell.log"

    -- Pipeline is write-only so we'll use transcript to get output
    script = '$Temp = [System.Environment]::GetEnvironmentVariable("TEMP","Machine")\n'
    script = script..'Start-Transcript -Path "'..tempfile..'" | Out-Null\n'
    script = script..psscript
    script = script..'\nStop-Transcript\n'

    pipe = io.popen("powershell.exe -noexit -nologo -nop -command -", "w")
    pipe:write(script)
    ret = pipe:close() -- success bool

    -- Get output
    file, err = io.open(tempfile, "r")
    if file then
        output = file:read("*all") -- String Output
        file:close()
        os.remove(tempfile)
    else 
        hunt.error("Powershell script failed to run: "..err)
    end
    return ret, output
end

-- PowerForensics (optional)
function powershell.install_powerforensics()
    --[[
        Checks for NuGet and installs Powerforensics
        Output: [bool] Success
    ]]
    if not powershell then 
        hunt.error("Infocyte's powershell lua functions are not available. Add Infocyte's powershell.* functions.")
        throw "Error"
    end
    script = [==[
        # Download/Install PowerForensics
        $n = Get-PackageProvider -name NuGet
        if ($n.version.major -lt 2) {
            if ($n.version.minor -lt 8) {
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force
            }
        }
        if (-NOT (Get-Module -ListAvailable -Name PowerForensics)) {
            Write-Host "Installing PowerForensics"
            Install-Module -name PowerForensics -Scope CurrentUser -Force
        }
    ]==]
    ret, output = powershell.run_script(script)
    if ret then 
        hunt.debug("Powershell Succeeded:\n"..output)
    else 
        hunt.error("Powershell Failed:\n"..output)
    end
    return ret
end

--[[ SECTION 3: Collection --]]

-- Check required inputs
if not s3_region or not s3_bucket then
    hunt.error("s3_region and s3_bucket not set")
    return
end

host_info = hunt.env.host_info()
osversion = host_info:os()
hunt.debug("Starting Extention. Hostname: " .. host_info:hostname() .. ", Domain: " .. host_info:domain() .. ", OS: " .. host_info:os() .. ", Architecture: " .. host_info:arch())

-- Make tempdir
logfolder = os.getenv("temp").."\\ic"
lf = hunt.fs.ls(logfolder)
if #lf == 0 then os.execute("mkdir "..logfolder) end

if use_powerforensics and hunt.env.has_powershell() then
    powershell.install_powerforensics()
end


instance = hunt.net.api()
if instance == '' then
    instancename = 'offline'
elseif instance:match("infocyte") then
    -- get instancename
    instancename = instance:match("(.+).infocyte.com")
end
s3 = hunt.recovery.s3(s3_user, s3_pass, s3_region, s3_bucket)
s3path_preamble = instancename..'/'..os.date("%Y%m%d")..'/'..host_info:hostname().."/"..s3path_modifier


for _, p in pairs(paths) do
    for _, path in pairs(hunt.fs.ls(p)) do
        -- If file is being used or locked, this copy will get passed it (usually)
        outpath = os.getenv("temp").."\\ic\\"..path:name()
        infile, err = io.open(path:path(), "rb")
        if not infile and use_powerforensics and hunt.env.has_powershell() then
            -- Assume file locked by kernel, use powerforensics to copy
            cmd = 'Copy-ForensicFile -Path '..path:path()..' -Destination '..outpath
            hunt.debug("File Locked. Executing: "..cmd)
            ret, out = powershell.run_cmd(cmd)
            hunt.debug("Powerforensics output: "..out)
        elseif not infile then
            hunt.error("Could not open "..path:path().." ["..err.."].\nTry enabling powerforensics to bypass file lock.")
            goto continue
        else
            data = infile:read("*all")
            infile:close()

            outfile = io.open(outpath, "wb")
            outfile:write(data)
            outfile:flush()
            outfile:close()
        end

        -- Hash the file copy
        if path_exists(outpath) then
            hash = hunt.hash.sha1(outpath)
            s3path = s3path_preamble.."/"..path:name().."-"..hash
            link = "https://"..s3_bucket..".s3."..s3_region..".amazonaws.com/" .. s3path

            -- Upload to S3
            success, err = s3:upload_file(outpath, s3path)
            if success then
                hunt.log("Uploaded "..path:path().." (sha1=".. hash .. ") to S3 at "..link)
            else
                hunt.error("Error on s3 upload of "..path:path()..": "..err)
            end

            os.remove(outpath)
        else
            hunt.error("File read/copy failed on "..path:path())
        end
        ::continue::
    end
end
os.execute("RMDIR /S/Q "..os.getenv("temp").."\\ic")
