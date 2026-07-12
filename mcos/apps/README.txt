McOS 1.0 external apps
======================

Place trusted Lua application files in /mcos/apps.
Each app receives the McOS API as its first argument and returns an app table:

local api = ...

return {
    id = "my_app",
    name = "My App",
    icon = "APP",
    category = "Custom",
    run = function()
        api.message("My App", "Hello from an external application.")
    end,
}

Available API functions:
- api.notify(title, body, level)
- api.message(title, body)
- api.input(title, prompt, secret)
- api.confirm(title, question)
- api.run(program, ...)
- api.getTheme()
- api.getUserDir()
- api.getDisplayMode()

External apps are ordinary Lua code and are not sandboxed. Only install code you trust.
