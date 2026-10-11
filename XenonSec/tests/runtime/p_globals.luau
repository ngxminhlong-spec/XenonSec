counter = 5
counter = counter + 1
print("counter:", counter)
function greet(n) return "hi " .. n end
print("greet:", greet("x"))
local realPrint = print
print = function(...) realPrint("[wrapped]", ...) end
print("hello")
