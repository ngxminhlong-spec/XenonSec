local t = 0
for i = 1, 150000 do t = t + i % 7 end
print(t)
