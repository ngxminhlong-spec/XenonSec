--[[
Protected by XenonSec :: VM-based Lua obfuscator (5.1 target)
--]]
local _NpbzHdAZRt = string.byte
local _kquaIJGxzO = string.char
local _jTMIhSq = table.concat
local function _BdXCCDGcB(_vrGMLHuu, _RTbacVN)
local _bE_JecFHFh, _HJJc_pP, _Xidk_Xl_Zf, _IhqIQvKvcp = 0, 1, _vrGMLHuu, _RTbacVN
while _Xidk_Xl_Zf > 0 or _IhqIQvKvcp > 0 do
local _pXlZ_loOW, _X_uXWFW = _Xidk_Xl_Zf % 2, _IhqIQvKvcp % 2
if _pXlZ_loOW ~= _X_uXWFW then _bE_JecFHFh = _bE_JecFHFh + _HJJc_pP end
_Xidk_Xl_Zf = (_Xidk_Xl_Zf - _pXlZ_loOW) / 2
_IhqIQvKvcp = (_IhqIQvKvcp - _X_uXWFW) / 2
_HJJc_pP = _HJJc_pP * 2
end
return _bE_JecFHFh
end
local _LIBSZiIuTcw = {249,58,33,35,241,79,194,244,234,96,250,189,172}
local _GMeRKd = -266373
local function _YSYiPX(_LShHMTonK)
local _wsHpudx, _PCRyGUwxREl = {}, #_LIBSZiIuTcw
for _fXGnDrfSEQ = 1, #_LShHMTonK do
_wsHpudx[_fXGnDrfSEQ] = _kquaIJGxzO(_BdXCCDGcB(_NpbzHdAZRt(_LShHMTonK, _fXGnDrfSEQ), _LIBSZiIuTcw[((_fXGnDrfSEQ - 1) % _PCRyGUwxREl) + 1]))
end
return _jTMIhSq(_wsHpudx)
end
local _ahLpCP = { "™;YP¿","∑…|Ù√","™eEu®®ßàÇ’Êçy","™JSJü;","∑√z˚∆","™e~Bù∂ÉΩ∂","™[[Z—&±‘çÉ","∑¿Ú«","∑¬Û√","∑√w˙Õ","∑¡~˜«","™ey@°Æ¢Ö6ûÕ","™els∫<Æô∫±Õ" }
local _CDntaTmwqd = {}
for _CRfyxtaOzTs = 1, #_ahLpCP do
local _XswIHYw = _YSYiPX(_ahLpCP[_CRfyxtaOzTs])
local _zZHT_Aew = _XswIHYw:sub(1, 1)
if _zZHT_Aew == "N" then _CDntaTmwqd[_CRfyxtaOzTs] = tonumber(_XswIHYw:sub(2)) - _GMeRKd else _CDntaTmwqd[_CRfyxtaOzTs] = _XswIHYw:sub(2) end
end
local _hwsZBQvVRj = { {p={},v=true,c={{18,4,0,0},{9,1,0,0},{18,1,0,0},{27,7,0,0},{5,1,0,0},{22,1,0,0},{3,0,0,0},{22,1,0,0},{3,0,0,0},{22,1,0,0},{28,0,0,0}}} }
return ((function()
local _UVYKRRRnzng = table.unpack or unpack
local _Synaxz = string.byte
local _Evxrts = string.char
local _seuLeoFcYw = table.concat
local function _PJrbQzToMTL(__pGxHZP, _rUMcZ_Ia)
local _dTMNkODJHRu, _CFARkXxj, _PAFBCEBjEy, _wjaHYDp = 0, 1, __pGxHZP, _rUMcZ_Ia
while _PAFBCEBjEy > 0 or _wjaHYDp > 0 do
local _uKdWpDMzz, _JkZiQzL = _PAFBCEBjEy % 2, _wjaHYDp % 2
if _uKdWpDMzz ~= _JkZiQzL then _dTMNkODJHRu = _dTMNkODJHRu + _CFARkXxj end
_PAFBCEBjEy = (_PAFBCEBjEy - _uKdWpDMzz) / 2
_wjaHYDp = (_wjaHYDp - _JkZiQzL) / 2
_CFARkXxj = _CFARkXxj * 2
end
return _dTMNkODJHRu
end
local function _aVYyiuIi(_FMqjfa, _apQNOpW)
local _AVFquqJu, _HTsaBBa = {}, #_apQNOpW
for _mqprqC = 1, #_FMqjfa do
_AVFquqJu[_mqprqC] = _Evxrts(_PJrbQzToMTL(_Synaxz(_FMqjfa, _mqprqC), _apQNOpW[((_mqprqC - 1) % _HTsaBBa) + 1]))
end
return _seuLeoFcYw(_AVFquqJu)
end
local function _FretHaQg(...)
return { n = select("#", ...), ... }
end
local function _vwpLfKVMCnM(_ONiacx) return _ONiacx ~= nil and _ONiacx ~= false end
local _tZKZqPsX = {
[1] = function(__pGxHZP, _rUMcZ_Ia) return __pGxHZP + _rUMcZ_Ia end,
[2] = function(__pGxHZP, _rUMcZ_Ia) return __pGxHZP - _rUMcZ_Ia end,
[3] = function(__pGxHZP, _rUMcZ_Ia) return __pGxHZP * _rUMcZ_Ia end,
[4] = function(__pGxHZP, _rUMcZ_Ia) return __pGxHZP / _rUMcZ_Ia end,
[5] = function(__pGxHZP, _rUMcZ_Ia) return __pGxHZP % _rUMcZ_Ia end,
[6] = function(__pGxHZP, _rUMcZ_Ia) return __pGxHZP ^ _rUMcZ_Ia end,
[7] = function(__pGxHZP, _rUMcZ_Ia) return __pGxHZP .. _rUMcZ_Ia end,
[8] = function(__pGxHZP, _rUMcZ_Ia) return __pGxHZP == _rUMcZ_Ia end,
[9] = function(__pGxHZP, _rUMcZ_Ia) return __pGxHZP ~= _rUMcZ_Ia end,
[10] = function(__pGxHZP, _rUMcZ_Ia) return __pGxHZP < _rUMcZ_Ia end,
[11] = function(__pGxHZP, _rUMcZ_Ia) return __pGxHZP > _rUMcZ_Ia end,
[12] = function(__pGxHZP, _rUMcZ_Ia) return __pGxHZP <= _rUMcZ_Ia end,
[13] = function(__pGxHZP, _rUMcZ_Ia) return __pGxHZP >= _rUMcZ_Ia end,
}
local _idKDz_nFJh = {
["+"]=1, ["-"]=2, ["*"]=3, ["/"]=4, ["%"]=5, ["^"]=6, [".."]=7,
["=="]=8, ["~="]=9, ["<"]=10, [">"]=11, ["<="]=12, [">="]=13,
}
local _kvcnjPv = {
[1] = function(__pGxHZP) return -__pGxHZP end,
[2] = function(__pGxHZP) return not __pGxHZP end,
[3] = function(__pGxHZP) return #__pGxHZP end,
}
local _STBlSlk = { ["-"]=1, ["not"]=2, ["#"]=3 }
local __CeOKh = setmetatable({}, { __tostring = function() return "<xs-nil>" end })
local _mHxAmfHC,_cFDluZu,_RWxJgHR,_jVUUcr,_KOGWUn,_jpcNAxLV,_CQfkWNabW,
_VPYlWI_BDTO,_ccdPDA,_yibnomja,_kWieLgq,_OpgriVskY,__BWzZeBl,_NvsaFoiK,
_paFdpMvyHNI,_jIfegdjHo,_uKUuoiDZh,_ZNXozrMfeuK,_bPsiSBQ,_djQYEe,_hcnab_,
_pynaEsvnFwb,_FUyu_BEQzhU,_pXRpYRmnp,_nTSJfwfh,_KaSdatHQ,
_PKweGnuEdGR,_felYNrtT,_NCAFGAYn
= 27,21,13,3,18,15,9,
19,25,2,10,12,11,22,
8,4,26,7,6,17,24,
23,14,1,16,29,
20,5,28
local function _PcalgHy(_kCgbVmffj, ...)
local _xDMWqnvVUVS, _lHilSp, _qQcSXdMjjSs = _kCgbVmffj[1], _kCgbVmffj[2], _kCgbVmffj[3]
local _oWPjlb
_oWPjlb = function(_fWzXcLElW, _AOMqRDnU, _wdgPguK)
local _EVXh_SHXVrA = _lHilSp[_fWzXcLElW]
local _nWGbHW = _EVXh_SHXVrA.c
local _kjLzGPFuW_ = { vars = {}, parent = _wdgPguK }
local _QDZNLZ = _EVXh_SHXVrA.p
for _sVzKvEXrj = 1, #_QDZNLZ do
local _ZfQioAIUpno = _AOMqRDnU[_sVzKvEXrj]
_kjLzGPFuW_.vars[_xDMWqnvVUVS[_QDZNLZ[_sVzKvEXrj]]] = (_ZfQioAIUpno == nil) and __CeOKh or _ZfQioAIUpno
end
local _mraQqNB = nil
if _EVXh_SHXVrA.v then
local _rTiRCEu = (_AOMqRDnU.n or #_AOMqRDnU) - #_QDZNLZ
if _rTiRCEu < 0 then _rTiRCEu = 0 end
local _VDxTImaX = { n = _rTiRCEu }
for _JQcWdnhvnY = 1, _rTiRCEu do _VDxTImaX[_JQcWdnhvnY] = _AOMqRDnU[#_QDZNLZ + _JQcWdnhvnY] end
_mraQqNB = _VDxTImaX
end
local function _ay_sriiUMC(_GfQyNbzK)
local _FMqjfa = _kjLzGPFuW_
while _FMqjfa do
if _FMqjfa.vars[_GfQyNbzK] ~= nil then return _FMqjfa end
_FMqjfa = _FMqjfa.parent
end
return nil
end
local _hARcDdkZrh, _rGKJXSSQDt = {}, 0
local function _jzYIl_(_ONiacx) _rGKJXSSQDt = _rGKJXSSQDt + 1; _hARcDdkZrh[_rGKJXSSQDt] = _ONiacx end
local function _WPovFr() local _ONiacx = _hARcDdkZrh[_rGKJXSSQDt]; _hARcDdkZrh[_rGKJXSSQDt] = nil; _rGKJXSSQDt = _rGKJXSSQDt - 1; return _ONiacx end
local function _JBY_JHrpral() return _hARcDdkZrh[_rGKJXSSQDt] end
local function _SbMljW(_hDWhKRWZlB)
local _kjRhjzO = _kjLzGPFuW_
return function(...)
return _oWPjlb(_hDWhKRWZlB, _FretHaQg(...), _kjRhjzO)
end
end
local _OfB_nsa_E = 1
while true do
local _Vnsyjzh = _nWGbHW[_OfB_nsa_E]
if not _Vnsyjzh then return end
local _uflVvvelCoL = _Vnsyjzh[1]
if _uflVvvelCoL == _mHxAmfHC then
_jzYIl_(_xDMWqnvVUVS[_Vnsyjzh[2]]); _OfB_nsa_E = _OfB_nsa_E + 1
elseif _uflVvvelCoL == _cFDluZu then
_jzYIl_(nil); _OfB_nsa_E = _OfB_nsa_E + 1
elseif _uflVvvelCoL == _RWxJgHR then
_jzYIl_(true); _OfB_nsa_E = _OfB_nsa_E + 1
elseif _uflVvvelCoL == _jVUUcr then
_jzYIl_(false); _OfB_nsa_E = _OfB_nsa_E + 1
elseif _uflVvvelCoL == _KOGWUn then
local _PzvpzJI = _xDMWqnvVUVS[_Vnsyjzh[2]]
local _JmKDAbbJ = _ay_sriiUMC(_PzvpzJI)
if _JmKDAbbJ then
local _ONiacx = _JmKDAbbJ.vars[_PzvpzJI]
if _ONiacx == __CeOKh then _jzYIl_(nil) else _jzYIl_(_ONiacx) end
else
_jzYIl_(_G[_PzvpzJI])
end
_OfB_nsa_E = _OfB_nsa_E + 1
elseif _uflVvvelCoL == _jpcNAxLV then
local _PzvpzJI = _xDMWqnvVUVS[_Vnsyjzh[2]]
local _ONiacx = _WPovFr()
local _JmKDAbbJ = _ay_sriiUMC(_PzvpzJI)
if _JmKDAbbJ then
_JmKDAbbJ.vars[_PzvpzJI] = (_ONiacx == nil) and __CeOKh or _ONiacx
else
_G[_PzvpzJI] = _ONiacx
end
_OfB_nsa_E = _OfB_nsa_E + 1
elseif _uflVvvelCoL == _CQfkWNabW then
local _PzvpzJI = _xDMWqnvVUVS[_Vnsyjzh[2]]
local _ONiacx = _WPovFr()
_kjLzGPFuW_.vars[_PzvpzJI] = (_ONiacx == nil) and __CeOKh or _ONiacx
_OfB_nsa_E = _OfB_nsa_E + 1
elseif _uflVvvelCoL == _VPYlWI_BDTO then
_jzYIl_({}); _OfB_nsa_E = _OfB_nsa_E + 1
elseif _uflVvvelCoL == _ccdPDA then
local _jIVpUQKpV = _WPovFr(); local _RiGhYeDnDlW = _WPovFr()
_jzYIl_(_RiGhYeDnDlW[_jIVpUQKpV]); _OfB_nsa_E = _OfB_nsa_E + 1
elseif _uflVvvelCoL == _yibnomja then
local _UhNxHO = _WPovFr(); local _jIVpUQKpV = _WPovFr(); local _RiGhYeDnDlW = _WPovFr()
_RiGhYeDnDlW[_jIVpUQKpV] = _UhNxHO; _OfB_nsa_E = _OfB_nsa_E + 1
elseif _uflVvvelCoL == _kWieLgq then
local _qpIZjXS_ = _Vnsyjzh[2]
local _gVBYdgfal = _WPovFr()
local _oOTjRNrDj = {}
for _rIoGpmQleQS = _gVBYdgfal, 1, -1 do _oOTjRNrDj[_rIoGpmQleQS] = _WPovFr() end
local _KsiNznO = _WPovFr()
for _rIoGpmQleQS = 1, _gVBYdgfal do _KsiNznO[_qpIZjXS_ + _rIoGpmQleQS] = _oOTjRNrDj[_rIoGpmQleQS] end
_OfB_nsa_E = _OfB_nsa_E + 1
elseif _uflVvvelCoL == _OpgriVskY then
_jzYIl_(_JBY_JHrpral()); _OfB_nsa_E = _OfB_nsa_E + 1
elseif _uflVvvelCoL == __BWzZeBl then
local _VbxOloACRK = _WPovFr(); local _hsOOIaDUe = _WPovFr(); _jzYIl_(_VbxOloACRK); _jzYIl_(_hsOOIaDUe); _OfB_nsa_E = _OfB_nsa_E + 1
elseif _uflVvvelCoL == _NvsaFoiK then
for _rIoGpmQleQS = 1, _Vnsyjzh[2] do _WPovFr() end
_OfB_nsa_E = _OfB_nsa_E + 1
elseif _uflVvvelCoL == _paFdpMvyHNI then
local _LpbdxPCL = _idKDz_nFJh[_xDMWqnvVUVS[_Vnsyjzh[2]]]
local _lGEJtPXUq = _WPovFr(); local _DRWVFJCFlw = _WPovFr()
_jzYIl_(_tZKZqPsX[_LpbdxPCL](_DRWVFJCFlw, _lGEJtPXUq))
_OfB_nsa_E = _OfB_nsa_E + 1
elseif _uflVvvelCoL == _jIfegdjHo then
local _EgZGkwuMgX = _STBlSlk[_xDMWqnvVUVS[_Vnsyjzh[2]]]
local _NBHfpDZGrCw = _WPovFr()
_jzYIl_(_kvcnjPv[_EgZGkwuMgX](_NBHfpDZGrCw))
_OfB_nsa_E = _OfB_nsa_E + 1
elseif _uflVvvelCoL == _uKUuoiDZh then
_OfB_nsa_E = _Vnsyjzh[2]
elseif _uflVvvelCoL == _ZNXozrMfeuK then
local _xaV_Ggv = _WPovFr()
if _vwpLfKVMCnM(_xaV_Ggv) then _OfB_nsa_E = _OfB_nsa_E + 1 else _OfB_nsa_E = _Vnsyjzh[2] end
elseif _uflVvvelCoL == _bPsiSBQ then
local _KBnqMKL = _WPovFr()
if _KBnqMKL == nil then _OfB_nsa_E = _Vnsyjzh[2] else _OfB_nsa_E = _OfB_nsa_E + 1 end
elseif _uflVvvelCoL == _djQYEe then
local _RHuDibIx = _JBY_JHrpral()
if _vwpLfKVMCnM(_RHuDibIx) then _OfB_nsa_E = _OfB_nsa_E + 1 else _OfB_nsa_E = _Vnsyjzh[2] end
elseif _uflVvvelCoL == _hcnab_ then
local _HcWiyhFzc = _JBY_JHrpral()
if _vwpLfKVMCnM(_HcWiyhFzc) then _OfB_nsa_E = _Vnsyjzh[2] else _OfB_nsa_E = _OfB_nsa_E + 1 end
elseif _uflVvvelCoL == _pynaEsvnFwb then
_jzYIl_(_SbMljW(_Vnsyjzh[2])); _OfB_nsa_E = _OfB_nsa_E + 1
elseif _uflVvvelCoL == _FUyu_BEQzhU then
_kjLzGPFuW_ = { vars = {}, parent = _kjLzGPFuW_ }; _OfB_nsa_E = _OfB_nsa_E + 1
elseif _uflVvvelCoL == _pXRpYRmnp then
_kjLzGPFuW_ = _kjLzGPFuW_.parent; _OfB_nsa_E = _OfB_nsa_E + 1
elseif _uflVvvelCoL == _nTSJfwfh then
if _mraQqNB then _jzYIl_(_mraQqNB[1]) else _jzYIl_(nil) end
_OfB_nsa_E = _OfB_nsa_E + 1
elseif _uflVvvelCoL == _KaSdatHQ then
local _fi_uTBIim = _mraQqNB and _mraQqNB.n or 0
for _TJiAdLIe = 1, _fi_uTBIim do _jzYIl_(_mraQqNB[_TJiAdLIe]) end
_jzYIl_(_fi_uTBIim)
_OfB_nsa_E = _OfB_nsa_E + 1
elseif _uflVvvelCoL == _PKweGnuEdGR then
local _fJahFjGM = _Vnsyjzh[2]
local _fOskXsFPTm = _WPovFr()
local _eEQONqSxYXR = {}
for _FRkj_R = _fOskXsFPTm, 1, -1 do _eEQONqSxYXR[_FRkj_R] = _WPovFr() end
for _FRkj_R = 1, _fJahFjGM do
if _FRkj_R <= _fOskXsFPTm then _jzYIl_(_eEQONqSxYXR[_FRkj_R]) else _jzYIl_(nil) end
end
_OfB_nsa_E = _OfB_nsa_E + 1
elseif _uflVvvelCoL == _felYNrtT then
local _OWKgfGyKuqX, _vBginwa, _uXBxCsIMry = _Vnsyjzh[2], _Vnsyjzh[3], _Vnsyjzh[4]
local _ftqlzWKjq, _fHvHOE = {}, 0
if _vBginwa == 1 then
local _kEFFAgbcyKO = _WPovFr()
local _hvVALgZHQi = {}
for _QoEkVrPPBtu = _kEFFAgbcyKO, 1, -1 do _hvVALgZHQi[_QoEkVrPPBtu] = _WPovFr() end
local _UBiW_S = {}
for _QoEkVrPPBtu = _OWKgfGyKuqX, 1, -1 do _UBiW_S[_QoEkVrPPBtu] = _WPovFr() end
for _QoEkVrPPBtu = 1, _OWKgfGyKuqX do _ftqlzWKjq[_QoEkVrPPBtu] = _UBiW_S[_QoEkVrPPBtu] end
for _QoEkVrPPBtu = 1, _kEFFAgbcyKO do _ftqlzWKjq[_OWKgfGyKuqX + _QoEkVrPPBtu] = _hvVALgZHQi[_QoEkVrPPBtu] end
_fHvHOE = _OWKgfGyKuqX + _kEFFAgbcyKO
else
local _QZdLzPRyvG = {}
for _QoEkVrPPBtu = _OWKgfGyKuqX, 1, -1 do _QZdLzPRyvG[_QoEkVrPPBtu] = _WPovFr() end
_ftqlzWKjq = _QZdLzPRyvG
_fHvHOE = _OWKgfGyKuqX
end
local _swUWHOnvD = _WPovFr()
local _OYVIzcDyUm = _FretHaQg(_swUWHOnvD(_UVYKRRRnzng(_ftqlzWKjq, 1, _fHvHOE)))
if _uXBxCsIMry == 1 then
for _TpZrePP = 1, _OYVIzcDyUm.n do _jzYIl_(_OYVIzcDyUm[_TpZrePP]) end
_jzYIl_(_OYVIzcDyUm.n)
else
_jzYIl_(_OYVIzcDyUm[1])
end
_OfB_nsa_E = _OfB_nsa_E + 1
elseif _uflVvvelCoL == _NCAFGAYn then
local _vuSSnOyb, _UEPICK = _Vnsyjzh[2], _Vnsyjzh[3]
if _UEPICK == 1 then
local _aMSzGeN = _WPovFr()
local _uLPyADYW = {}
for _QNkDllEeQsM = _aMSzGeN, 1, -1 do _uLPyADYW[_QNkDllEeQsM] = _WPovFr() end
local _bbsOUStY = {}
for _QNkDllEeQsM = _vuSSnOyb, 1, -1 do _bbsOUStY[_QNkDllEeQsM] = _WPovFr() end
local _RrpFPQiNL = {}
for _QNkDllEeQsM = 1, _vuSSnOyb do _RrpFPQiNL[_QNkDllEeQsM] = _bbsOUStY[_QNkDllEeQsM] end
for _QNkDllEeQsM = 1, _aMSzGeN do _RrpFPQiNL[_vuSSnOyb + _QNkDllEeQsM] = _uLPyADYW[_QNkDllEeQsM] end
return _UVYKRRRnzng(_RrpFPQiNL, 1, _vuSSnOyb + _aMSzGeN)
else
local _DyofJA = {}
for _QNkDllEeQsM = _vuSSnOyb, 1, -1 do _DyofJA[_QNkDllEeQsM] = _WPovFr() end
return _UVYKRRRnzng(_DyofJA, 1, _vuSSnOyb)
end
else
error("bad opcode")
end
end
end
return _oWPjlb(_qQcSXdMjjSs, _FretHaQg(...), nil)
end
return _PcalgHy
end)())({ _CDntaTmwqd, _hwsZBQvVRj, 1 }, ...)