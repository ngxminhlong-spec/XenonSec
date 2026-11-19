return [===[
-- Hook check off: this build does not read the debug library at all.
local %hookGet% = nil
local %hookSet% = nil
local %hookST% = function() return 0 end
]===]
