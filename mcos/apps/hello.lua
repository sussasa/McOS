-- Example McOS 1.0 external app.
local api = ...

return {
    id = "ext_hello",
    name = "Hello App",
    icon = "HI",
    category = "Examples",
    run = function()
        api.message("Hello App", "This app was loaded from /mcos/apps/hello.lua. You can use this file as a template for your own McOS apps.")
    end,
}
