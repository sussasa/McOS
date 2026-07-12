-- McOS 1.0 bootstrap
local core = "/mcos/system/main.lua"

term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)

if not fs.exists(core) or fs.isDir(core) then
    term.setTextColor(colors.red)
    print("McOS 1.0 core is missing: " .. core)
    print("Run the McOS 1.0 installer again, or restore startup.lua from /mcos/backups.")
    return
end

local ok, result = pcall(shell.run, core)
if not ok or result == false then
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.red)
    print("\nMcOS 1.0 could not start:")
    print(ok and "The core returned failure." or tostring(result))
    print("Run the installer again or inspect /mcos/data/system.log.")
end
