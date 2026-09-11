--[[
Protected by XenonSec :: VM-based Lua obfuscator (5.1 target)
--]]
local _lKzuxgx = string.byte
local _aCYARG = string.char
local _pMYfqt = table.concat
local function _mBXkVtccC(_MbJihfp, _ImIyTK)
local _EIUVbygCur, _OtzpIkrr, _yxIGeVoD, _YrrFllGJsi = 0, 1, _MbJihfp, _ImIyTK
while _yxIGeVoD > 0 or _YrrFllGJsi > 0 do
local _JGRcfg, _qxbJWyrBCm = _yxIGeVoD % 2, _YrrFllGJsi % 2
if _JGRcfg ~= _qxbJWyrBCm then _EIUVbygCur = _EIUVbygCur + _OtzpIkrr end
_yxIGeVoD = (_yxIGeVoD - _JGRcfg) / 2
_YrrFllGJsi = (_YrrFllGJsi - _qxbJWyrBCm) / 2
_OtzpIkrr = _OtzpIkrr * 2
end
return _EIUVbygCur
end
local _f_NwqsHCZq = {135,176,27,29,25,20,240,8,129,90,16,254,149}
local _gtDNkFSrphP = 209314
local function _RKOilqu(_vuOSKf)
local _mdPgkiJY, _nPKCXzTN = {}, #_f_NwqsHCZq
for _HVuXpvs = 1, #_vuOSKf do
_mdPgkiJY[_HVuXpvs] = _aCYARG(_mBXkVtccC(_lKzuxgx(_vuOSKf, _HVuXpvs), _f_NwqsHCZq[((_HVuXpvs - 1) % _nPKCXzTN) + 1]))
end
return _pMYfqt(_mdPgkiJY)
end
local _iktoJFsxM = { "ÔïU\\|uJøvšÇÆç","É+$,!Â","É‚\",/ Å","Ôïknzqˆ","Ô±cn(","ÔïJOjR™B","Ôï^h~n¶zÊ,xÊ","É‚..)-Æ","Ôï~xp\\¯EË1{ÍÕå","ÔïhLxCšo÷\
h","É‚-./$È","ÔÀitw`","ÔïcYNP’cû^¶Òÿ÷b","ÔïJ{W_±cã+{¦ïöÃtS","Ôï]zpB£f","ÔÜn|","É‚-%+!Ã","É(/(&Â","ÔïiX^y†\\ê,^" }
local _GuAZIoJkk = {}
for _cYqKSL = 1, #_iktoJFsxM do
local _hfZQojiDS = _RKOilqu(_iktoJFsxM[_cYqKSL])
local _VpzxVUXUBl = _hfZQojiDS:sub(1, 1)
if _VpzxVUXUBl == "N" then _GuAZIoJkk[_cYqKSL] = tonumber(_hfZQojiDS:sub(2)) - _gtDNkFSrphP else _GuAZIoJkk[_cYqKSL] = _hfZQojiDS:sub(2) end
end
local _MwJPu_ymK = { {p={},v=true,c={{9,12,0,0},{27,5,0,0},{9,5,0,0},{3,16,0,0},{17,1,0,0},{16,0,0,0},{25,1,0,0},{25,1,0,0},{28,0,0,0}}} }
return ((function()
local _SdwpFvol = table.unpack or unpack
local _nNjkjCrL = string.byte
local _xRrBOsb = string.char
local _waKbvC = table.concat
local function _SRKmeV(_sIRDStVCF, _tWTgoUm)
local _VXLpyQhpzu, _tbMbSoTl, _vQAOMsV, _lhKgevwDkDS = 0, 1, _sIRDStVCF, _tWTgoUm
while _vQAOMsV > 0 or _lhKgevwDkDS > 0 do
local _YldZXeRlXb, _rSVfDm_D = _vQAOMsV % 2, _lhKgevwDkDS % 2
if _YldZXeRlXb ~= _rSVfDm_D then _VXLpyQhpzu = _VXLpyQhpzu + _tbMbSoTl end
_vQAOMsV = (_vQAOMsV - _YldZXeRlXb) / 2
_lhKgevwDkDS = (_lhKgevwDkDS - _rSVfDm_D) / 2
_tbMbSoTl = _tbMbSoTl * 2
end
return _VXLpyQhpzu
end
local function _hmFlHaOS(_FBBREAOJq, _FstXknbNAbq)
local _jDDvkDibgOD, _EghrQxquQ = {}, #_FstXknbNAbq
for _r_YtNxvcvE = 1, #_FBBREAOJq do
_jDDvkDibgOD[_r_YtNxvcvE] = _xRrBOsb(_SRKmeV(_nNjkjCrL(_FBBREAOJq, _r_YtNxvcvE), _FstXknbNAbq[((_r_YtNxvcvE - 1) % _EghrQxquQ) + 1]))
end
return _waKbvC(_jDDvkDibgOD)
end
local function _YZPBhRIVt(...)
return { n = select("#", ...), ... }
end
local function _zAwRpUh(_JRaJOtvlOx) return _JRaJOtvlOx ~= nil and _JRaJOtvlOx ~= false end
local _scFrRfyHN = {
[1] = function(_sIRDStVCF, _tWTgoUm) return _sIRDStVCF + _tWTgoUm end,
[2] = function(_sIRDStVCF, _tWTgoUm) return _sIRDStVCF - _tWTgoUm end,
[3] = function(_sIRDStVCF, _tWTgoUm) return _sIRDStVCF * _tWTgoUm end,
[4] = function(_sIRDStVCF, _tWTgoUm) return _sIRDStVCF / _tWTgoUm end,
[5] = function(_sIRDStVCF, _tWTgoUm) return _sIRDStVCF % _tWTgoUm end,
[6] = function(_sIRDStVCF, _tWTgoUm) return _sIRDStVCF ^ _tWTgoUm end,
[7] = function(_sIRDStVCF, _tWTgoUm) return _sIRDStVCF .. _tWTgoUm end,
[8] = function(_sIRDStVCF, _tWTgoUm) return _sIRDStVCF == _tWTgoUm end,
[9] = function(_sIRDStVCF, _tWTgoUm) return _sIRDStVCF ~= _tWTgoUm end,
[10] = function(_sIRDStVCF, _tWTgoUm) return _sIRDStVCF < _tWTgoUm end,
[11] = function(_sIRDStVCF, _tWTgoUm) return _sIRDStVCF > _tWTgoUm end,
[12] = function(_sIRDStVCF, _tWTgoUm) return _sIRDStVCF <= _tWTgoUm end,
[13] = function(_sIRDStVCF, _tWTgoUm) return _sIRDStVCF >= _tWTgoUm end,
}
local _acTAyJPr = {
["+"]=1, ["-"]=2, ["*"]=3, ["/"]=4, ["%"]=5, ["^"]=6, [".."]=7,
["=="]=8, ["~="]=9, ["<"]=10, [">"]=11, ["<="]=12, [">="]=13,
}
local _yaHyJvSdGG = {
[1] = function(_sIRDStVCF) return -_sIRDStVCF end,
[2] = function(_sIRDStVCF) return not _sIRDStVCF end,
[3] = function(_sIRDStVCF) return #_sIRDStVCF end,
}
local _nZDSpuYNb = { ["-"]=1, ["not"]=2, ["#"]=3 }
local _fcNZClHqDx = setmetatable({}, { __tostring = function() return "<xs-nil>" end })
local _DenmzfqfLR,_JukYPhLR,_RTFPuQwLsTz,_YNhxSxDCoWl,_fixnUnfKf,_yzBUjUNJQL,_XhmuKPJF,
_qLiNZbaeMfP,_EqdOkRx,_BTXIfqsU_XU,_IccGdcK,_iyZNPbAZTY,_tQUbVktPjpI,_XKCDOFmD,
_LCzzE_xwXv,_NpQHAivJyd,_vOLYBp,_ecUGBtj,_RFyltlBjS,_snKQrS,_eCiGSsK,
_lpvFyXvcuHw,_hFxhYLRNc,_YglgMcyvXK,_roioJkIpHn,_mLEjwvXy,
_VFpaqr,_MoiwGwEU,_PCvvQS
= 3,14,2,16,9,4,27,
8,13,18,11,15,6,25,
29,19,7,20,5,22,1,
24,10,23,21,26,
12,17,28
local function _AwRXRNuUH(_jIpAgbPoxuL, ...)
local _nQQPll, _cTezKbpww, _dvsLLTR = _jIpAgbPoxuL[1], _jIpAgbPoxuL[2], _jIpAgbPoxuL[3]
local _HeiaPjnF_c
_HeiaPjnF_c = function(_kHTdMrNNHj, _QmEhXo_, __HSiHHsVmr)
local _cCEVFqmrdTA = _cTezKbpww[_kHTdMrNNHj]
local _INQQKeQ = _cCEVFqmrdTA.c
local _ewpmdXEY = { vars = {}, parent = __HSiHHsVmr }
local _VWkwzf = _cCEVFqmrdTA.p
for _QrtTkT = 1, #_VWkwzf do
local _TGVIpZ = _QmEhXo_[_QrtTkT]
_ewpmdXEY.vars[_nQQPll[_VWkwzf[_QrtTkT]]] = (_TGVIpZ == nil) and _fcNZClHqDx or _TGVIpZ
end
local _McVbpYYT = nil
if _cCEVFqmrdTA.v then
local _fORqkqvlfNE = (_QmEhXo_.n or #_QmEhXo_) - #_VWkwzf
if _fORqkqvlfNE < 0 then _fORqkqvlfNE = 0 end
local _XxcQcXxsWVd = { n = _fORqkqvlfNE }
for _QeoNcgIiVzy = 1, _fORqkqvlfNE do _XxcQcXxsWVd[_QeoNcgIiVzy] = _QmEhXo_[#_VWkwzf + _QeoNcgIiVzy] end
_McVbpYYT = _XxcQcXxsWVd
end
local function _PUqUHU(_ErVttSRLNMP)
local _FBBREAOJq = _ewpmdXEY
while _FBBREAOJq do
if _FBBREAOJq.vars[_ErVttSRLNMP] ~= nil then return _FBBREAOJq end
_FBBREAOJq = _FBBREAOJq.parent
end
return nil
end
local _BU_nXgWeau, _fjwvddpVH = {}, 0
local function _Q__HRLuCA(_JRaJOtvlOx) _fjwvddpVH = _fjwvddpVH + 1; _BU_nXgWeau[_fjwvddpVH] = _JRaJOtvlOx end
local function _ctfpql() local _JRaJOtvlOx = _BU_nXgWeau[_fjwvddpVH]; _BU_nXgWeau[_fjwvddpVH] = nil; _fjwvddpVH = _fjwvddpVH - 1; return _JRaJOtvlOx end
local function _umFXrOt() return _BU_nXgWeau[_fjwvddpVH] end
local function _RwbMdIBdIh(_sBvTHxmMMCY)
local _WjCSBplngHp = _ewpmdXEY
return function(...)
return _HeiaPjnF_c(_sBvTHxmMMCY, _YZPBhRIVt(...), _WjCSBplngHp)
end
end
local _KYtNFBHYcbQ = 1
while true do
local _ybukDrgyBJ = _INQQKeQ[_KYtNFBHYcbQ]
if not _ybukDrgyBJ then return end
local _bZCoeiE = _ybukDrgyBJ[1]
if _bZCoeiE == _DenmzfqfLR then
_Q__HRLuCA(_nQQPll[_ybukDrgyBJ[2]]); _KYtNFBHYcbQ = _KYtNFBHYcbQ + 1
elseif _bZCoeiE == _JukYPhLR then
_Q__HRLuCA(nil); _KYtNFBHYcbQ = _KYtNFBHYcbQ + 1
elseif _bZCoeiE == _RTFPuQwLsTz then
_Q__HRLuCA(true); _KYtNFBHYcbQ = _KYtNFBHYcbQ + 1
elseif _bZCoeiE == _YNhxSxDCoWl then
_Q__HRLuCA(false); _KYtNFBHYcbQ = _KYtNFBHYcbQ + 1
elseif _bZCoeiE == _fixnUnfKf then
local _TBqGfSmcUnT = _nQQPll[_ybukDrgyBJ[2]]
local _MUYWwpcVQ = _PUqUHU(_TBqGfSmcUnT)
if _MUYWwpcVQ then
local _JRaJOtvlOx = _MUYWwpcVQ.vars[_TBqGfSmcUnT]
if _JRaJOtvlOx == _fcNZClHqDx then _Q__HRLuCA(nil) else _Q__HRLuCA(_JRaJOtvlOx) end
else
_Q__HRLuCA(_G[_TBqGfSmcUnT])
end
_KYtNFBHYcbQ = _KYtNFBHYcbQ + 1
elseif _bZCoeiE == _yzBUjUNJQL then
local _TBqGfSmcUnT = _nQQPll[_ybukDrgyBJ[2]]
local _JRaJOtvlOx = _ctfpql()
local _MUYWwpcVQ = _PUqUHU(_TBqGfSmcUnT)
if _MUYWwpcVQ then
_MUYWwpcVQ.vars[_TBqGfSmcUnT] = (_JRaJOtvlOx == nil) and _fcNZClHqDx or _JRaJOtvlOx
else
_G[_TBqGfSmcUnT] = _JRaJOtvlOx
end
_KYtNFBHYcbQ = _KYtNFBHYcbQ + 1
elseif _bZCoeiE == _XhmuKPJF then
local _TBqGfSmcUnT = _nQQPll[_ybukDrgyBJ[2]]
local _JRaJOtvlOx = _ctfpql()
_ewpmdXEY.vars[_TBqGfSmcUnT] = (_JRaJOtvlOx == nil) and _fcNZClHqDx or _JRaJOtvlOx
_KYtNFBHYcbQ = _KYtNFBHYcbQ + 1
elseif _bZCoeiE == _qLiNZbaeMfP then
_Q__HRLuCA({}); _KYtNFBHYcbQ = _KYtNFBHYcbQ + 1
elseif _bZCoeiE == _EqdOkRx then
local _lRJNfOVKLO = _ctfpql(); local _buqUGtN = _ctfpql()
_Q__HRLuCA(_buqUGtN[_lRJNfOVKLO]); _KYtNFBHYcbQ = _KYtNFBHYcbQ + 1
elseif _bZCoeiE == _BTXIfqsU_XU then
local _lqGenBBCDvs = _ctfpql(); local _lRJNfOVKLO = _ctfpql(); local _buqUGtN = _ctfpql()
_buqUGtN[_lRJNfOVKLO] = _lqGenBBCDvs; _KYtNFBHYcbQ = _KYtNFBHYcbQ + 1
elseif _bZCoeiE == _IccGdcK then
local _HjYtpLo = _ybukDrgyBJ[2]
local _wbjyvzrbTeW = _ctfpql()
local _uBjHcK = {}
for _GfBUMKR = _wbjyvzrbTeW, 1, -1 do _uBjHcK[_GfBUMKR] = _ctfpql() end
local _ZCsYZu = _ctfpql()
for _GfBUMKR = 1, _wbjyvzrbTeW do _ZCsYZu[_HjYtpLo + _GfBUMKR] = _uBjHcK[_GfBUMKR] end
_KYtNFBHYcbQ = _KYtNFBHYcbQ + 1
elseif _bZCoeiE == _iyZNPbAZTY then
_Q__HRLuCA(_umFXrOt()); _KYtNFBHYcbQ = _KYtNFBHYcbQ + 1
elseif _bZCoeiE == _tQUbVktPjpI then
local _wQGNSy = _ctfpql(); local _NDloMSqwbW = _ctfpql(); _Q__HRLuCA(_wQGNSy); _Q__HRLuCA(_NDloMSqwbW); _KYtNFBHYcbQ = _KYtNFBHYcbQ + 1
elseif _bZCoeiE == _XKCDOFmD then
for _GfBUMKR = 1, _ybukDrgyBJ[2] do _ctfpql() end
_KYtNFBHYcbQ = _KYtNFBHYcbQ + 1
elseif _bZCoeiE == _LCzzE_xwXv then
local _DQnmGsliL = _acTAyJPr[_nQQPll[_ybukDrgyBJ[2]]]
local _gepCVVp = _ctfpql(); local _tfzWrNHjdc = _ctfpql()
_Q__HRLuCA(_scFrRfyHN[_DQnmGsliL](_tfzWrNHjdc, _gepCVVp))
_KYtNFBHYcbQ = _KYtNFBHYcbQ + 1
elseif _bZCoeiE == _NpQHAivJyd then
local __ENPR_v = _nZDSpuYNb[_nQQPll[_ybukDrgyBJ[2]]]
local _lEUuKZJ = _ctfpql()
_Q__HRLuCA(_yaHyJvSdGG[__ENPR_v](_lEUuKZJ))
_KYtNFBHYcbQ = _KYtNFBHYcbQ + 1
elseif _bZCoeiE == _vOLYBp then
_KYtNFBHYcbQ = _ybukDrgyBJ[2]
elseif _bZCoeiE == _ecUGBtj then
local _TEBEXHc = _ctfpql()
if _zAwRpUh(_TEBEXHc) then _KYtNFBHYcbQ = _KYtNFBHYcbQ + 1 else _KYtNFBHYcbQ = _ybukDrgyBJ[2] end
elseif _bZCoeiE == _RFyltlBjS then
local _YQzgUCrTfeI = _ctfpql()
if _YQzgUCrTfeI == nil then _KYtNFBHYcbQ = _ybukDrgyBJ[2] else _KYtNFBHYcbQ = _KYtNFBHYcbQ + 1 end
elseif _bZCoeiE == _snKQrS then
local _dcgoG_JqYrC = _umFXrOt()
if _zAwRpUh(_dcgoG_JqYrC) then _KYtNFBHYcbQ = _KYtNFBHYcbQ + 1 else _KYtNFBHYcbQ = _ybukDrgyBJ[2] end
elseif _bZCoeiE == _eCiGSsK then
local _VduSKxKInj = _umFXrOt()
if _zAwRpUh(_VduSKxKInj) then _KYtNFBHYcbQ = _ybukDrgyBJ[2] else _KYtNFBHYcbQ = _KYtNFBHYcbQ + 1 end
elseif _bZCoeiE == _lpvFyXvcuHw then
_Q__HRLuCA(_RwbMdIBdIh(_ybukDrgyBJ[2])); _KYtNFBHYcbQ = _KYtNFBHYcbQ + 1
elseif _bZCoeiE == _hFxhYLRNc then
_ewpmdXEY = { vars = {}, parent = _ewpmdXEY }; _KYtNFBHYcbQ = _KYtNFBHYcbQ + 1
elseif _bZCoeiE == _YglgMcyvXK then
_ewpmdXEY = _ewpmdXEY.parent; _KYtNFBHYcbQ = _KYtNFBHYcbQ + 1
elseif _bZCoeiE == _roioJkIpHn then
if _McVbpYYT then _Q__HRLuCA(_McVbpYYT[1]) else _Q__HRLuCA(nil) end
_KYtNFBHYcbQ = _KYtNFBHYcbQ + 1
elseif _bZCoeiE == _mLEjwvXy then
local _gLf_RjHOnJ = _McVbpYYT and _McVbpYYT.n or 0
for _CpUkFRBhIwk = 1, _gLf_RjHOnJ do _Q__HRLuCA(_McVbpYYT[_CpUkFRBhIwk]) end
_Q__HRLuCA(_gLf_RjHOnJ)
_KYtNFBHYcbQ = _KYtNFBHYcbQ + 1
elseif _bZCoeiE == _VFpaqr then
local _nVzYDN = _ybukDrgyBJ[2]
local _rTSxSI = _ctfpql()
local _ywUhpwwiG = {}
for __hiHDt = _rTSxSI, 1, -1 do _ywUhpwwiG[__hiHDt] = _ctfpql() end
for __hiHDt = 1, _nVzYDN do
if __hiHDt <= _rTSxSI then _Q__HRLuCA(_ywUhpwwiG[__hiHDt]) else _Q__HRLuCA(nil) end
end
_KYtNFBHYcbQ = _KYtNFBHYcbQ + 1
elseif _bZCoeiE == _MoiwGwEU then
local _RniOQVVhOM, _FuldQfkfB, _ohIooRWRj = _ybukDrgyBJ[2], _ybukDrgyBJ[3], _ybukDrgyBJ[4]
local _IxNwnIquv, _Zawkdm = {}, 0
if _FuldQfkfB == 1 then
local _orRVGZD = _ctfpql()
local _mtQdCuLZhgl = {}
for _wGkyFkVQog = _orRVGZD, 1, -1 do _mtQdCuLZhgl[_wGkyFkVQog] = _ctfpql() end
local _CxXwdV = {}
for _wGkyFkVQog = _RniOQVVhOM, 1, -1 do _CxXwdV[_wGkyFkVQog] = _ctfpql() end
for _wGkyFkVQog = 1, _RniOQVVhOM do _IxNwnIquv[_wGkyFkVQog] = _CxXwdV[_wGkyFkVQog] end
for _wGkyFkVQog = 1, _orRVGZD do _IxNwnIquv[_RniOQVVhOM + _wGkyFkVQog] = _mtQdCuLZhgl[_wGkyFkVQog] end
_Zawkdm = _RniOQVVhOM + _orRVGZD
else
local _YgsNjUgVTna = {}
for _wGkyFkVQog = _RniOQVVhOM, 1, -1 do _YgsNjUgVTna[_wGkyFkVQog] = _ctfpql() end
_IxNwnIquv = _YgsNjUgVTna
_Zawkdm = _RniOQVVhOM
end
local _cxKmVp = _ctfpql()
local _PeLWjmtg = _YZPBhRIVt(_cxKmVp(_SdwpFvol(_IxNwnIquv, 1, _Zawkdm)))
if _ohIooRWRj == 1 then
for _waIth_frUm = 1, _PeLWjmtg.n do _Q__HRLuCA(_PeLWjmtg[_waIth_frUm]) end
_Q__HRLuCA(_PeLWjmtg.n)
else
_Q__HRLuCA(_PeLWjmtg[1])
end
_KYtNFBHYcbQ = _KYtNFBHYcbQ + 1
elseif _bZCoeiE == _PCvvQS then
local _MAlQCIA, _DPlsUWndiG = _ybukDrgyBJ[2], _ybukDrgyBJ[3]
if _DPlsUWndiG == 1 then
local _Rbkyury = _ctfpql()
local _IrMUdleU = {}
for _NtCpiOHcJV = _Rbkyury, 1, -1 do _IrMUdleU[_NtCpiOHcJV] = _ctfpql() end
local _SAoIBz = {}
for _NtCpiOHcJV = _MAlQCIA, 1, -1 do _SAoIBz[_NtCpiOHcJV] = _ctfpql() end
local _WREwzW = {}
for _NtCpiOHcJV = 1, _MAlQCIA do _WREwzW[_NtCpiOHcJV] = _SAoIBz[_NtCpiOHcJV] end
for _NtCpiOHcJV = 1, _Rbkyury do _WREwzW[_MAlQCIA + _NtCpiOHcJV] = _IrMUdleU[_NtCpiOHcJV] end
return _SdwpFvol(_WREwzW, 1, _MAlQCIA + _Rbkyury)
else
local _sZtxTh = {}
for _NtCpiOHcJV = _MAlQCIA, 1, -1 do _sZtxTh[_NtCpiOHcJV] = _ctfpql() end
return _SdwpFvol(_sZtxTh, 1, _MAlQCIA)
end
else
error("bad opcode")
end
end
end
return _HeiaPjnF_c(_dvsLLTR, _YZPBhRIVt(...), nil)
end
return _AwRXRNuUH
end)())({ _GuAZIoJkk, _MwJPu_ymK, 1 }, ...)