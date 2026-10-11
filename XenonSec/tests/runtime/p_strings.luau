local s = "hello"
print(#s, s:upper(), s:sub(2, 3), string.rep("ab", 3))
print(("%d-%s"):format(5, "x"), string.byte("A"), string.char(66))
print(select("#", nil, nil), table.unpack({1, 2, 3}))
