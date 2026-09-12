--[[
Protected by XenonSec :: VM-based Lua obfuscator (5.1 target)
--]]
local _ssPvZr = string.byte
local _irrSVYrevpv = string.char
local _MpoXmlUJ = table.concat
local function _KAqbSfx(_wuYNMQIJhM, _whwiwK)
local _IWZriI, _zKJEhz_BxN, _muVtgYQ, _uYJecr_ = 0, 1, _wuYNMQIJhM, _whwiwK
while _muVtgYQ > 0 or _uYJecr_ > 0 do
local _IiJzHt, _kAGkbc = _muVtgYQ % 2, _uYJecr_ % 2
if _IiJzHt ~= _kAGkbc then _IWZriI = _IWZriI + _zKJEhz_BxN end
_muVtgYQ = (_muVtgYQ - _IiJzHt) / 2
_uYJecr_ = (_uYJecr_ - _kAGkbc) / 2
_zKJEhz_BxN = _zKJEhz_BxN * 2
end
return _IWZriI
end
local _oorjIyhyLBw = {158,35,246,245,223,3,166,80,152,238,87,87,106,188,50,171}
local _GzMGAtOj = -585028
local function _uC_FbGQcINr(_dAFCHcmhzHO)
local _stxMgGEBhEf, _jVmSIDP = {}, #_oorjIyhyLBw
for _ctnJwzRVgE = 1, #_dAFCHcmhzHO do
_stxMgGEBhEf[_ctnJwzRVgE] = _irrSVYrevpv(_KAqbSfx(_ssPvZr(_dAFCHcmhzHO, _ctnJwzRVgE), _oorjIyhyLBw[((_ctnJwzRVgE - 1) % _jVmSIDP) + 1]))
end
return _MpoXmlUJ(_stxMgGEBhEf)
end
local _zYpldVPEctK = { "Í|›ªAí$Îœ\r","Í|¿‰qá#Ô­×FÍÎ","ÍS„œ±w","ÐÂÌê2—a","Í|—·¥TÕ$þ”","ÐÀÁï3–e","ÍOƒ”","ÐÀÆæ3–c","Í|®Œ«[Ë","ÐÃÃï;•g","ÐÀÀï3ži","ÐÃÀè3—e","Í\"Ž†î","Í|‡ª«@â","Í|© ˆWö)È€& ","Í|½³«Ká3Î","ÐÃÀì1Ÿi","Í|žºTô" }
local _CFyumai = {}
for _dBkNXKESRiJ = 1, #_zYpldVPEctK do
local _fYAiTpN = _uC_FbGQcINr(_zYpldVPEctK[_dBkNXKESRiJ])
local _IxgkbFEoGMm = _fYAiTpN:sub(1, 1)
if _IxgkbFEoGMm == "N" then _CFyumai[_dBkNXKESRiJ] = tonumber(_fYAiTpN:sub(2)) - _GzMGAtOj else _CFyumai[_dBkNXKESRiJ] = _fYAiTpN:sub(2) end
end
local _nwwkg_bXhL = { {p={},v=true,c={{3,3,0,0},{21,13,0,0},{3,13,0,0},{24,7,0,0},{10,1,0,0},{26,1,0,0},{13,0,0,0}}} }
return ((function()
local _DWieuhi = table.unpack or unpack
local _JVhvwNCuLvv = string.byte
local _M_pdrLQB = string.char
local _aTXWaaqi = table.concat
local function _oSevmAi(_VTkplXoB_G, _PhFQ_CL)
local _CbiLpa, _LnpTbjMmzY, _NzitKX, _pNARxAtz = 0, 1, _VTkplXoB_G, _PhFQ_CL
while _NzitKX > 0 or _pNARxAtz > 0 do
local _ePJUzWisY, _ekRctEBB = _NzitKX % 2, _pNARxAtz % 2
if _ePJUzWisY ~= _ekRctEBB then _CbiLpa = _CbiLpa + _LnpTbjMmzY end
_NzitKX = (_NzitKX - _ePJUzWisY) / 2
_pNARxAtz = (_pNARxAtz - _ekRctEBB) / 2
_LnpTbjMmzY = _LnpTbjMmzY * 2
end
return _CbiLpa
end
local function _lyxAkXrIwKg(_OVOHuK, _NIiRSZTlDt)
local _AEkXeuTvcp, _iuTdiA = {}, #_NIiRSZTlDt
for _SpkAxarw = 1, #_OVOHuK do
_AEkXeuTvcp[_SpkAxarw] = _M_pdrLQB(_oSevmAi(_JVhvwNCuLvv(_OVOHuK, _SpkAxarw), _NIiRSZTlDt[((_SpkAxarw - 1) % _iuTdiA) + 1]))
end
return _aTXWaaqi(_AEkXeuTvcp)
end
local function _CZmozRyvVTo(...)
return { n = select("#", ...), ... }
end
local function _VEudYmg(_MFYbPx) return _MFYbPx ~= nil and _MFYbPx ~= false end
local _QPVJrUWF = {
[1] = function(_VTkplXoB_G, _PhFQ_CL) return _VTkplXoB_G + _PhFQ_CL end,
[2] = function(_VTkplXoB_G, _PhFQ_CL) return _VTkplXoB_G - _PhFQ_CL end,
[3] = function(_VTkplXoB_G, _PhFQ_CL) return _VTkplXoB_G * _PhFQ_CL end,
[4] = function(_VTkplXoB_G, _PhFQ_CL) return _VTkplXoB_G / _PhFQ_CL end,
[5] = function(_VTkplXoB_G, _PhFQ_CL) return _VTkplXoB_G % _PhFQ_CL end,
[6] = function(_VTkplXoB_G, _PhFQ_CL) return _VTkplXoB_G ^ _PhFQ_CL end,
[7] = function(_VTkplXoB_G, _PhFQ_CL) return _VTkplXoB_G .. _PhFQ_CL end,
[8] = function(_VTkplXoB_G, _PhFQ_CL) return _VTkplXoB_G == _PhFQ_CL end,
[9] = function(_VTkplXoB_G, _PhFQ_CL) return _VTkplXoB_G ~= _PhFQ_CL end,
[10] = function(_VTkplXoB_G, _PhFQ_CL) return _VTkplXoB_G < _PhFQ_CL end,
[11] = function(_VTkplXoB_G, _PhFQ_CL) return _VTkplXoB_G > _PhFQ_CL end,
[12] = function(_VTkplXoB_G, _PhFQ_CL) return _VTkplXoB_G <= _PhFQ_CL end,
[13] = function(_VTkplXoB_G, _PhFQ_CL) return _VTkplXoB_G >= _PhFQ_CL end,
}
local _MdOGWcVQ = {
["+"]=1, ["-"]=2, ["*"]=3, ["/"]=4, ["%"]=5, ["^"]=6, [".."]=7,
["=="]=8, ["~="]=9, ["<"]=10, [">"]=11, ["<="]=12, [">="]=13,
}
local _pTEB_KnFI = {
[1] = function(_VTkplXoB_G) return -_VTkplXoB_G end,
[2] = function(_VTkplXoB_G) return not _VTkplXoB_G end,
[3] = function(_VTkplXoB_G) return #_VTkplXoB_G end,
}
local _teOjUJS = { ["-"]=1, ["not"]=2, ["#"]=3 }
local _CNQVzUJ = setmetatable({}, { __tostring = function() return "<xs-nil>" end })
local _QL_Fro,_WPyFccmr,_reGkNyvp,_lkKfUOV,_NAWaZRQww,_zIjW_nBka_G,_kRBUXuI,
_ZuqUvoLlLg,_kPmfOA,_ZAHERRvrL,_LshKNyE,_Mosxvv,_jHMYgtWH_,_yRVPBmAT,
_jGRONDbf,_xBGHhsEoMAW,_atCVhcgIWA,_BrFoVHuVdVB,_cTorFPmqQF,_KNVRvRrmsJS,_DzaxCVYmY,
_BowqAMffEQ,_zHmqYzIHroj,_oHrjFEgvfu,_wVDB_hrSGY,_XWDECU,
_MJfsaoXFvsL,_jgKMIKTZBz,_FvTi_vcRgMX
= 24,23,22,29,3,4,21,
17,16,6,19,9,12,26,
25,5,27,8,28,15,1,
7,14,11,18,2,
20,10,13
local function _NlvrGObv(_ifJQPBPqaLV, ...)
local _EdvZgmeS, _EEuZWa, _YwJfBrVqTJ = _ifJQPBPqaLV[1], _ifJQPBPqaLV[2], _ifJQPBPqaLV[3]
local _UuBpYEKXK
_UuBpYEKXK = function(_bCeFgzEbzqZ, __ewq_MjJscc, _sawcXgZZIdD)
local _CgQbwPXvTs = _EEuZWa[_bCeFgzEbzqZ]
local _SeVAxYDppE = _CgQbwPXvTs.c
local _rBSpzAtboV = { vars = {}, parent = _sawcXgZZIdD }
local _dWDTSZ = _CgQbwPXvTs.p
for _kKDpFcMDGb = 1, #_dWDTSZ do
local _jNjKFzifSjt = __ewq_MjJscc[_kKDpFcMDGb]
_rBSpzAtboV.vars[_EdvZgmeS[_dWDTSZ[_kKDpFcMDGb]]] = (_jNjKFzifSjt == nil) and _CNQVzUJ or _jNjKFzifSjt
end
local _rxIUpATaLD = nil
if _CgQbwPXvTs.v then
local _ahGNKlOCu = (__ewq_MjJscc.n or #__ewq_MjJscc) - #_dWDTSZ
if _ahGNKlOCu < 0 then _ahGNKlOCu = 0 end
local _LdfkmkbwE = { n = _ahGNKlOCu }
for _NbwHrWzrHb = 1, _ahGNKlOCu do _LdfkmkbwE[_NbwHrWzrHb] = __ewq_MjJscc[#_dWDTSZ + _NbwHrWzrHb] end
_rxIUpATaLD = _LdfkmkbwE
end
local function _HjAuULhwfIg(_OqvZsRD)
local _OVOHuK = _rBSpzAtboV
while _OVOHuK do
if _OVOHuK.vars[_OqvZsRD] ~= nil then return _OVOHuK end
_OVOHuK = _OVOHuK.parent
end
return nil
end
local _DECjWx, _meLhLVHeOs = {}, 0
local function _jyVqHJH(_MFYbPx) _meLhLVHeOs = _meLhLVHeOs + 1; _DECjWx[_meLhLVHeOs] = _MFYbPx end
local function _HZUjex() local _MFYbPx = _DECjWx[_meLhLVHeOs]; _DECjWx[_meLhLVHeOs] = nil; _meLhLVHeOs = _meLhLVHeOs - 1; return _MFYbPx end
local function _GHJdpWhadT() return _DECjWx[_meLhLVHeOs] end
local function _LYIcjSBehhN(_ktOdDSAryh)
local _CwXKw_ = _rBSpzAtboV
return function(...)
return _UuBpYEKXK(_ktOdDSAryh, _CZmozRyvVTo(...), _CwXKw_)
end
end
local _qKAZNKQnO = 1
while true do
local _vAMGUAJxsjP = _SeVAxYDppE[_qKAZNKQnO]
if not _vAMGUAJxsjP then return end
local _qPsNMbjLEA = _vAMGUAJxsjP[1]
if _qPsNMbjLEA == _QL_Fro then
_jyVqHJH(_EdvZgmeS[_vAMGUAJxsjP[2]]); _qKAZNKQnO = _qKAZNKQnO + 1
elseif _qPsNMbjLEA == _WPyFccmr then
_jyVqHJH(nil); _qKAZNKQnO = _qKAZNKQnO + 1
elseif _qPsNMbjLEA == _reGkNyvp then
_jyVqHJH(true); _qKAZNKQnO = _qKAZNKQnO + 1
elseif _qPsNMbjLEA == _lkKfUOV then
_jyVqHJH(false); _qKAZNKQnO = _qKAZNKQnO + 1
elseif _qPsNMbjLEA == _NAWaZRQww then
local _dyiNowAm = _EdvZgmeS[_vAMGUAJxsjP[2]]
local _aYxVxfsQpg = _HjAuULhwfIg(_dyiNowAm)
if _aYxVxfsQpg then
local _MFYbPx = _aYxVxfsQpg.vars[_dyiNowAm]
if _MFYbPx == _CNQVzUJ then _jyVqHJH(nil) else _jyVqHJH(_MFYbPx) end
else
_jyVqHJH(_G[_dyiNowAm])
end
_qKAZNKQnO = _qKAZNKQnO + 1
elseif _qPsNMbjLEA == _zIjW_nBka_G then
local _dyiNowAm = _EdvZgmeS[_vAMGUAJxsjP[2]]
local _MFYbPx = _HZUjex()
local _aYxVxfsQpg = _HjAuULhwfIg(_dyiNowAm)
if _aYxVxfsQpg then
_aYxVxfsQpg.vars[_dyiNowAm] = (_MFYbPx == nil) and _CNQVzUJ or _MFYbPx
else
_G[_dyiNowAm] = _MFYbPx
end
_qKAZNKQnO = _qKAZNKQnO + 1
elseif _qPsNMbjLEA == _kRBUXuI then
local _dyiNowAm = _EdvZgmeS[_vAMGUAJxsjP[2]]
local _MFYbPx = _HZUjex()
_rBSpzAtboV.vars[_dyiNowAm] = (_MFYbPx == nil) and _CNQVzUJ or _MFYbPx
_qKAZNKQnO = _qKAZNKQnO + 1
elseif _qPsNMbjLEA == _ZuqUvoLlLg then
_jyVqHJH({}); _qKAZNKQnO = _qKAZNKQnO + 1
elseif _qPsNMbjLEA == _kPmfOA then
local _FWYsHZBsC = _HZUjex(); local _OFzWsN = _HZUjex()
_jyVqHJH(_OFzWsN[_FWYsHZBsC]); _qKAZNKQnO = _qKAZNKQnO + 1
elseif _qPsNMbjLEA == _ZAHERRvrL then
local _TZjTXGOu = _HZUjex(); local _FWYsHZBsC = _HZUjex(); local _OFzWsN = _HZUjex()
_OFzWsN[_FWYsHZBsC] = _TZjTXGOu; _qKAZNKQnO = _qKAZNKQnO + 1
elseif _qPsNMbjLEA == _LshKNyE then
local _fjamPGhMYP = _vAMGUAJxsjP[2]
local _yhmzVSYRjL = _HZUjex()
local _bKrVGY = {}
for _aJPkJaZoi = _yhmzVSYRjL, 1, -1 do _bKrVGY[_aJPkJaZoi] = _HZUjex() end
local _lYvKeIi_zg = _HZUjex()
for _aJPkJaZoi = 1, _yhmzVSYRjL do _lYvKeIi_zg[_fjamPGhMYP + _aJPkJaZoi] = _bKrVGY[_aJPkJaZoi] end
_qKAZNKQnO = _qKAZNKQnO + 1
elseif _qPsNMbjLEA == _Mosxvv then
_jyVqHJH(_GHJdpWhadT()); _qKAZNKQnO = _qKAZNKQnO + 1
elseif _qPsNMbjLEA == _jHMYgtWH_ then
local _JSZLBqGhno = _HZUjex(); local _WcrEdq = _HZUjex(); _jyVqHJH(_JSZLBqGhno); _jyVqHJH(_WcrEdq); _qKAZNKQnO = _qKAZNKQnO + 1
elseif _qPsNMbjLEA == _yRVPBmAT then
for _aJPkJaZoi = 1, _vAMGUAJxsjP[2] do _HZUjex() end
_qKAZNKQnO = _qKAZNKQnO + 1
elseif _qPsNMbjLEA == _jGRONDbf then
local _lbdjxNneWmE = _MdOGWcVQ[_EdvZgmeS[_vAMGUAJxsjP[2]]]
local _cnUaYu = _HZUjex(); local _DCDRJzU = _HZUjex()
_jyVqHJH(_QPVJrUWF[_lbdjxNneWmE](_DCDRJzU, _cnUaYu))
_qKAZNKQnO = _qKAZNKQnO + 1
elseif _qPsNMbjLEA == _xBGHhsEoMAW then
local _cXrVis = _teOjUJS[_EdvZgmeS[_vAMGUAJxsjP[2]]]
local _rQLEUHRyJTL = _HZUjex()
_jyVqHJH(_pTEB_KnFI[_cXrVis](_rQLEUHRyJTL))
_qKAZNKQnO = _qKAZNKQnO + 1
elseif _qPsNMbjLEA == _atCVhcgIWA then
_qKAZNKQnO = _vAMGUAJxsjP[2]
elseif _qPsNMbjLEA == _BrFoVHuVdVB then
local _UJXjlyNch = _HZUjex()
if _VEudYmg(_UJXjlyNch) then _qKAZNKQnO = _qKAZNKQnO + 1 else _qKAZNKQnO = _vAMGUAJxsjP[2] end
elseif _qPsNMbjLEA == _cTorFPmqQF then
local _XioTzia = _HZUjex()
if _XioTzia == nil then _qKAZNKQnO = _vAMGUAJxsjP[2] else _qKAZNKQnO = _qKAZNKQnO + 1 end
elseif _qPsNMbjLEA == _KNVRvRrmsJS then
local _grISWBzM_hF = _GHJdpWhadT()
if _VEudYmg(_grISWBzM_hF) then _qKAZNKQnO = _qKAZNKQnO + 1 else _qKAZNKQnO = _vAMGUAJxsjP[2] end
elseif _qPsNMbjLEA == _DzaxCVYmY then
local _KytHIEfuHn = _GHJdpWhadT()
if _VEudYmg(_KytHIEfuHn) then _qKAZNKQnO = _vAMGUAJxsjP[2] else _qKAZNKQnO = _qKAZNKQnO + 1 end
elseif _qPsNMbjLEA == _BowqAMffEQ then
_jyVqHJH(_LYIcjSBehhN(_vAMGUAJxsjP[2])); _qKAZNKQnO = _qKAZNKQnO + 1
elseif _qPsNMbjLEA == _zHmqYzIHroj then
_rBSpzAtboV = { vars = {}, parent = _rBSpzAtboV }; _qKAZNKQnO = _qKAZNKQnO + 1
elseif _qPsNMbjLEA == _oHrjFEgvfu then
_rBSpzAtboV = _rBSpzAtboV.parent; _qKAZNKQnO = _qKAZNKQnO + 1
elseif _qPsNMbjLEA == _wVDB_hrSGY then
if _rxIUpATaLD then _jyVqHJH(_rxIUpATaLD[1]) else _jyVqHJH(nil) end
_qKAZNKQnO = _qKAZNKQnO + 1
elseif _qPsNMbjLEA == _XWDECU then
local _DvUwVcxNj = _rxIUpATaLD and _rxIUpATaLD.n or 0
for _ubKWAwVIbF = 1, _DvUwVcxNj do _jyVqHJH(_rxIUpATaLD[_ubKWAwVIbF]) end
_jyVqHJH(_DvUwVcxNj)
_qKAZNKQnO = _qKAZNKQnO + 1
elseif _qPsNMbjLEA == _MJfsaoXFvsL then
local _zYZgCeBi = _vAMGUAJxsjP[2]
local _gMNaiHc = _HZUjex()
local _ultOncJNz = {}
for _uAiM_fLfH = _gMNaiHc, 1, -1 do _ultOncJNz[_uAiM_fLfH] = _HZUjex() end
for _uAiM_fLfH = 1, _zYZgCeBi do
if _uAiM_fLfH <= _gMNaiHc then _jyVqHJH(_ultOncJNz[_uAiM_fLfH]) else _jyVqHJH(nil) end
end
_qKAZNKQnO = _qKAZNKQnO + 1
elseif _qPsNMbjLEA == _jgKMIKTZBz then
local _HQgNCUNKAQ, _UbHIoKq, _iUvJch = _vAMGUAJxsjP[2], _vAMGUAJxsjP[3], _vAMGUAJxsjP[4]
local _hTOOJuEQh, _JVPiKd = {}, 0
if _UbHIoKq == 1 then
local _MKK_ua = _HZUjex()
local _DVwlXE = {}
for _exHTfawViBD = _MKK_ua, 1, -1 do _DVwlXE[_exHTfawViBD] = _HZUjex() end
local _qMNtOy = {}
for _exHTfawViBD = _HQgNCUNKAQ, 1, -1 do _qMNtOy[_exHTfawViBD] = _HZUjex() end
for _exHTfawViBD = 1, _HQgNCUNKAQ do _hTOOJuEQh[_exHTfawViBD] = _qMNtOy[_exHTfawViBD] end
for _exHTfawViBD = 1, _MKK_ua do _hTOOJuEQh[_HQgNCUNKAQ + _exHTfawViBD] = _DVwlXE[_exHTfawViBD] end
_JVPiKd = _HQgNCUNKAQ + _MKK_ua
else
local _yyxzz_ = {}
for _exHTfawViBD = _HQgNCUNKAQ, 1, -1 do _yyxzz_[_exHTfawViBD] = _HZUjex() end
_hTOOJuEQh = _yyxzz_
_JVPiKd = _HQgNCUNKAQ
end
local _WlqAevXL = _HZUjex()
local _bMJXVkz = _CZmozRyvVTo(_WlqAevXL(_DWieuhi(_hTOOJuEQh, 1, _JVPiKd)))
if _iUvJch == 1 then
for _AlKU_iXyHuX = 1, _bMJXVkz.n do _jyVqHJH(_bMJXVkz[_AlKU_iXyHuX]) end
_jyVqHJH(_bMJXVkz.n)
else
_jyVqHJH(_bMJXVkz[1])
end
_qKAZNKQnO = _qKAZNKQnO + 1
elseif _qPsNMbjLEA == _FvTi_vcRgMX then
local _uqbFHB, _bxvpzgYwbi = _vAMGUAJxsjP[2], _vAMGUAJxsjP[3]
if _bxvpzgYwbi == 1 then
local _ZIgJCfRyDyT = _HZUjex()
local _EmRGSxgB = {}
for _EWOdcMze = _ZIgJCfRyDyT, 1, -1 do _EmRGSxgB[_EWOdcMze] = _HZUjex() end
local _ucCBLdHCCja = {}
for _EWOdcMze = _uqbFHB, 1, -1 do _ucCBLdHCCja[_EWOdcMze] = _HZUjex() end
local _KEGAjyYq = {}
for _EWOdcMze = 1, _uqbFHB do _KEGAjyYq[_EWOdcMze] = _ucCBLdHCCja[_EWOdcMze] end
for _EWOdcMze = 1, _ZIgJCfRyDyT do _KEGAjyYq[_uqbFHB + _EWOdcMze] = _EmRGSxgB[_EWOdcMze] end
return _DWieuhi(_KEGAjyYq, 1, _uqbFHB + _ZIgJCfRyDyT)
else
local _xVVlYYXxbRR = {}
for _EWOdcMze = _uqbFHB, 1, -1 do _xVVlYYXxbRR[_EWOdcMze] = _HZUjex() end
return _DWieuhi(_xVVlYYXxbRR, 1, _uqbFHB)
end
else
error("bad opcode")
end
end
end
return _UuBpYEKXK(_YwJfBrVqTJ, _CZmozRyvVTo(...), nil)
end
return _NlvrGObv
end)())({ _CFyumai, _nwwkg_bXhL, 1 }, ...)