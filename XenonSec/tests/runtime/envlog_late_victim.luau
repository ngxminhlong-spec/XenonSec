local acc = 0
for i = 1, 300000 do
  acc = acc + i
  if i == 150000 then __swapLogger() end
end
print("secret output", acc)
