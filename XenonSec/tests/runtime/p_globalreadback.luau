myvar = 42
myvar = myvar * 2
print("read back:", myvar)
function bump() total = (total or 0) + 1 return total end
bump() bump()
print("total:", total)
