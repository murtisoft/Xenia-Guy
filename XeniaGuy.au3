#NoTrayIcon
#cs ----------------------------------------------------------------------------
	 AutoIt Version: 3.3.18.0
	 Author:         Claude Sonnet, Grok, and two hundred lines of human code
	 Script Function:
		A GUI manager for xenia
#ce ----------------------------------------------------------------------------

#include <GUIConstantsEx.au3>
#include <GuiEdit.au3>
#include <GuiListView.au3>
#include <WindowsConstants.au3>
#include <EditConstants.au3>
#include <File.au3>
#include <FileConstants.au3>
#include <InetConstants.au3>
#include <ProgressConstants.au3>
#include <ComboConstants.au3>
#include <ButtonConstants.au3>
#include <TabConstants.au3>
#include <Array.au3>
#include <Date.au3>
#include <Misc.au3>
#include <GDIPlus.au3>
#include <GuiImageList.au3>
#include <WinAPIGdi.au3>

; ---- single instance: a second launch just brings the running window to the front ----
If Not _Singleton("XeniaGuy_SingleInstance", 1) Then
	Local $hOld = WinGetHandle("[REGEXPTITLE:^Xenia Guy: A Xenia Canary GUI( - .*)?$; CLASS:AutoIt v3 GUI]")
	If $hOld Then
		If BitAND(WinGetState($hOld), 16) Then WinSetState($hOld, "", @SW_RESTORE)
		WinActivate($hOld)
	EndIf
	Exit
EndIf

Global $g_Xenia = @ScriptDir & "\xenia_canary.exe"
Global $g_DataDir = @ScriptDir & "\XeniaGuy"
Global $g_GameDir = @ScriptDir & "\games"
Global $g_CacheDir = $g_DataDir & "\Cache"
Global $g_PosterDir = $g_CacheDir & "\Posters"
Global $g_bPlayReq = False ; set by a double click, handled by the main loop
Global $g_PID = 0, $g_aRowMap[1], $g_aRowState[1], $g_aRowSerial[1], $g_aRowName[1], $g_aRowFile[1], $g_aRowDate[1]
Global $g_aGames, $hGUI, $idList, $idSearch, $g_idSub
Global $idOpen, $idRefresh, $idPlay, $idStop, $idConfig, $idUpdates
Global $idContext, $idBootCustom, $idBootGlobal, $idManagePatches, $idCustomConfig, $idShortcut
Global $sIni = $g_DataDir & "\Settings.ini"
Global $sGamesIni = $g_DataDir & "\Games.ini"
; Xenia's own patches folder (next to the exe) - not created by this tool
Global $sPatchesDir = @ScriptDir & "\patches"
Global $g_PatchFile = ""

; in-memory caches
Global $g_oCompat = 0, $g_oTitle = 0, $g_oDate = 0 ; title id -> rating / official title / last check date (compatibility database)
Global $g_oKnown = 0 ; lower case setting name -> real name (from xenia-canary.config.toml)
Global $g_oInfo = ObjCreate("Scripting.Dictionary") ; game path -> "name|serial|version"
Global $g_oSize = ObjCreate("Scripting.Dictionary") ; game path -> bytes
Global $g_oImg = ObjCreate("Scripting.Dictionary") ; title id -> image list index
Global $g_oQueued = ObjCreate("Scripting.Dictionary") ; title ids already queued for a poster download

; status line at the bottom of the main window - used instead of message boxes
Global Const $g_sHint = "Double-click a game to boot it with its custom parameters. Right-click for patches, custom config and shortcuts. Shift + Refresh List identifies every game again."
Global $g_idHint = 0, $g_hStatusTimer = 0
Global Const $XG_OK = 0x2E7D32, $XG_WARN = 0x9C5700, $XG_ERR = 0xB00020, $XG_INFO = 0x707070
$g_oInfo.CompareMode = 1
$g_oSize.CompareMode = 1

; posters
Global Const $g_sUrlPoster = "https://raw.githubusercontent.com/xenia-manager/x360db/main/titles/"
Global Const $g_iPosterW = 48, $g_iPosterH = 66
Global $g_hIL = 0, $g_sQueue = ""
Global $g_aDLId[3] = ["", "", ""], $g_aDLH[3] = [0, 0, 0]

; custom-draw layout of the list view notification (NMLVCUSTOMDRAW, up to iSubItem)
; (the NMHDR header is padded to 24 bytes on 64 bit, so an extra int is needed there or every field is read from the wrong place)
Global Const $XG_tagLVCD = (@AutoItX64 ? _
		"hwnd hWndFrom;uint_ptr IDFrom;int Code;int Pad;dword Stage;handle hdc;long rcL;long rcT;long rcR;long rcB;dword_ptr ItemSpec;uint ItemState;lparam ItemParam;dword ClrText;dword ClrBk;int SubItem" : _
		"hwnd hWndFrom;uint_ptr IDFrom;int Code;dword Stage;handle hdc;long rcL;long rcT;long rcR;long rcB;dword_ptr ItemSpec;uint ItemState;lparam ItemParam;dword ClrText;dword ClrBk;int SubItem")

_GDIPlus_Startup()
OnAutoItExitRegister("_OnExit")

Func _OnExit()
	_GDIPlus_Shutdown()
EndFunc

; Shows feedback on the main window's status line; it goes back to the normal hint after a few seconds
Func _Status($sText, $iColor = $XG_INFO)
	If Not $g_idHint Then Return
	$sText = StringReplace(StringReplace($sText, @CRLF, "  "), @LF, "  ")
	If StringLen($sText) > 170 Then $sText = StringLeft($sText, 167) & "..."
	GUICtrlSetColor($g_idHint, $iColor)
	GUICtrlSetData($g_idHint, $sText)
	$g_hStatusTimer = TimerInit()
EndFunc

Func _StatusTick()
	If $g_hStatusTimer <> 0 And TimerDiff($g_hStatusTimer) > 8000 Then
		$g_hStatusTimer = 0
		GUICtrlSetColor($g_idHint, $XG_INFO)
		GUICtrlSetData($g_idHint, $g_sHint)
	EndIf
EndFunc

Func _LoadSettings()
	Local $s = IniRead($sIni, "Settings", "GameDir", "")
	If $s <> "" And FileExists($s) Then $g_GameDir = $s
EndFunc

Func _SaveSettings()
	IniWrite($sIni, "Settings", "GameDir", $g_GameDir)
EndFunc

Func _EnsureDirs()
	If Not FileExists($g_DataDir) Then DirCreate($g_DataDir)
	If Not FileExists($g_CacheDir) Then DirCreate($g_CacheDir)
	If Not FileExists($g_PosterDir) Then DirCreate($g_PosterDir)
EndFunc

; Centers a (still hidden) child window on its parent
Func _CenterOnParent($hChild, $hParent)
	If BitAND(WinGetState($hParent), 16) Then Return ; parent is minimized
	Local $aP = WinGetPos($hParent)
	Local $aC = WinGetPos($hChild)
	If Not IsArray($aP) Or Not IsArray($aC) Then Return
	WinMove($hChild, "", $aP[0] + Int(($aP[2] - $aC[2]) / 2), $aP[1] + Int(($aP[3] - $aC[3]) / 2))
EndFunc

; Strips Xenia status junk: <null>, (Preloading shaders...), [Patches ...] and anything after
Func _CleanName($sName)
	$sName = StringRegExpReplace($sName, "\s*(?:<.*|\(Preloading.*|\[.*)$", "")
	Return StringStripWS($sName, 3)
EndFunc

Func _JsonUnescape($s)
	If Not StringInStr($s, "\") Then Return $s
	Local $a = StringRegExp($s, "\\u([0-9A-Fa-f]{4})", 3)
	If IsArray($a) Then
		For $i = 0 To UBound($a) - 1
			$s = StringReplace($s, "\u" & $a[$i], ChrW(Dec($a[$i])), 0, 1)
		Next
	EndIf
	$s = StringReplace($s, '\"', '"')
	$s = StringReplace($s, "\/", "/")
	$s = StringReplace($s, "\\", "\")
	Return $s
EndFunc

; ===== Compatibility database =====
; Loads rating + official title per title id from the cached compatibility_data.json
Func _LoadCompat()
	Local $sFile = $g_CacheDir & "\compatibility_data.json"
	If Not FileExists($sFile) Then Return False
	Local $h = FileOpen($sFile, BitOR($FO_READ, $FO_UTF8_NOBOM))
	If $h = -1 Then Return False
	Local $sText = FileRead($h)
	FileClose($h)
	Local $a = StringRegExp($sText, '(?s)"id":\s*"([0-9A-Fa-f]{8})",\s*"title":\s*"((?:[^"\\]|\\.)*)",\s*"updated":\s*"([^"]*)",\s*"state":\s*"([^"]+)"', 3)
	If Not IsArray($a) Then Return False
	Local $oS = ObjCreate("Scripting.Dictionary"), $oT = ObjCreate("Scripting.Dictionary"), $oD = ObjCreate("Scripting.Dictionary")
	Local $sId
	For $k = 0 To UBound($a) - 4 Step 4
		$sId = StringUpper($a[$k])
		$oS.Item($sId) = $a[$k + 3]
		$oT.Item($sId) = StringStripWS(_JsonUnescape($a[$k + 1]), 3)
		$oD.Item($sId) = StringLeft($a[$k + 2], 10) ; YYYY-MM-DD of the last check
	Next
	$g_oCompat = $oS
	$g_oTitle = $oT
	$g_oDate = $oD
	Return True
EndFunc

Func _GetCompat($sSerial)
	If Not IsObj($g_oCompat) Or $sSerial = "" Then Return ""
	Local $sKey = StringUpper($sSerial)
	If $g_oCompat.Exists($sKey) Then Return $g_oCompat.Item($sKey)
	Return ""
EndFunc

; Date (YYYY-MM-DD) of the last compatibility check for a title id
Func _GetCompatDate($sSerial)
	If Not IsObj($g_oDate) Or $sSerial = "" Then Return ""
	Local $sKey = StringUpper($sSerial)
	If $g_oDate.Exists($sKey) Then Return $g_oDate.Item($sKey)
	Return ""
EndFunc

; The compatibility database has the most accurate names, so it wins over what Xenia reported
Func _ResolveName($sSerial, $sFallback)
	If IsObj($g_oTitle) And $sSerial <> "" Then
		Local $sKey = StringUpper($sSerial)
		If $g_oTitle.Exists($sKey) Then Return $g_oTitle.Item($sKey)
	EndIf
	Return $sFallback
EndFunc

; ===== Identifying games =====
; Forget cached Name/Serial/Version for every game (keeps custom args) and identify them again
Func _ReIdentifyAll()
	If Not IsArray($g_aGames) Then Return
	For $i = 1 To $g_aGames[0]
		IniDelete($sGamesIni, $g_aGames[$i], "Name")
		IniDelete($sGamesIni, $g_aGames[$i], "Serial")
		IniDelete($sGamesIni, $g_aGames[$i], "Version")
		IniDelete($sGamesIni, $g_aGames[$i], "Failed")
	Next
	$g_oInfo.RemoveAll()
	_FillList(GUICtrlRead($idSearch))
EndFunc

Func _IdentifyGame($sPath)
	Local $sName = "", $sSerial = "", $sVersion = "", $aMatch = 0
	WinSetTitle($hGUI, "", "Xenia Guy: A Xenia Canary GUI - identifying " & StringRegExpReplace($sPath, "^.*\\", ""))
	For $iTry = 1 To 2
		$aMatch = _IdentifyOnce($sPath)
		If IsArray($aMatch) Then ExitLoop
	Next
	If IsArray($aMatch) Then
		$sSerial = $aMatch[0]
		$sVersion = $aMatch[1]
		$sName = _CleanName($aMatch[2])
		IniWrite($sGamesIni, $sPath, "Name", $sName)
		IniWrite($sGamesIni, $sPath, "Serial", $sSerial)
		IniWrite($sGamesIni, $sPath, "Version", $sVersion)
		IniDelete($sGamesIni, $sPath, "Failed")
	Else
		; nothing trustworthy was found: show the file name, remember the failure only for today, store no guessed data
		$sName = StringRegExpReplace($sPath, "^.*\\|\.[^.]+$", "")
		IniWrite($sGamesIni, $sPath, "Failed", @YEAR & @MON & @MDAY)
	EndIf
	Return StringReplace($sName, "|", "/") & "|" & $sSerial & "|" & $sVersion
EndFunc

; Starts Xenia on one game and reads serial / version / name from the title of THAT process' window.
; Returns the regex match array, or 0 when the process died, timed out or never showed a valid title.
Func _IdentifyOnce($sPath)
	Local $pid = Run('"' & $g_Xenia & '" "' & $sPath & '" --gpu=null --apu=nop --headless', @ScriptDir, @SW_HIDE)
	If Not $pid Then Return 0
	Local $hTimer = TimerInit(), $sTitle, $sLast = "", $aWin, $aMatch = 0
	While TimerDiff($hTimer) < 20000
		$sTitle = ""
		$aWin = WinList("[CLASS:XeniaWindowClass]")
		For $w = 1 To $aWin[0][0]
			; only the window that belongs to the process started above - games the user runs themselves are ignored
			If WinGetProcess($aWin[$w][1]) = $pid Then $sTitle = $aWin[$w][0]
		Next
		$aMatch = StringRegExp($sTitle, "\[([0-9A-Fa-f]+) (v[\d.]+)\]\s*(.+)$", 1)
		If IsArray($aMatch) Then
			If $sTitle == $sLast Then ExitLoop ; accept only a title that was stable for two reads
			$sLast = $sTitle
		EndIf
		$aMatch = 0
		If Not ProcessExists($pid) Then ExitLoop ; Xenia closed or crashed on its own
		Sleep(100)
	WEnd
	If ProcessExists($pid) Then ProcessClose($pid)
	Return $aMatch
EndFunc

Func _GetGameInfo($sPath)
	If $g_oInfo.Exists($sPath) Then Return $g_oInfo.Item($sPath)
	Local $sResult
	Local $sSerial = IniRead($sGamesIni, $sPath, "Serial", "")
	If $sSerial = "" And IniRead($sGamesIni, $sPath, "Failed", "") <> @YEAR & @MON & @MDAY Then
		$sResult = _IdentifyGame($sPath)
	Else
		Local $sName = _CleanName(IniRead($sGamesIni, $sPath, "Name", StringRegExpReplace($sPath, "^.*\\|\.[^.]+$", "")))
		Local $sVersion = IniRead($sGamesIni, $sPath, "Version", "")
		$sResult = StringReplace($sName, "|", "/") & "|" & $sSerial & "|" & $sVersion
	EndIf
	$g_oInfo.Item($sPath) = $sResult
	Return $sResult
EndFunc

; ===== Posters =====
Func _PosterPath($sId)
	Return $g_PosterDir & "\" & $sId & ".jpg"
EndFunc

; Scales a poster file to icon size and adds it to the list view's image list
Func _AddPosterToList($sFile)
	Local $hImg = _GDIPlus_ImageLoadFromFile($sFile)
	If $hImg = 0 Then Return -1
	Local $hScaled = _GDIPlus_ImageResize($hImg, $g_iPosterW, $g_iPosterH)
	_GDIPlus_ImageDispose($hImg)
	If $hScaled = 0 Then Return -1
	Local $hBmp = _GDIPlus_BitmapCreateHBITMAPFromBitmap($hScaled)
	_GDIPlus_ImageDispose($hScaled)
	If $hBmp = 0 Then Return -1
	Local $iIdx = _GUIImageList_Add($g_hIL, $hBmp)
	_WinAPI_DeleteObject($hBmp)
	Return $iIdx
EndFunc

; Image list index for a title id, or -1. Loads from disk when cached, otherwise queues a download.
Func _PosterIndex($sSerial)
	If $sSerial = "" Then Return -1
	Local $k = StringUpper($sSerial)
	If $g_oImg.Exists($k) Then Return $g_oImg.Item($k)
	Local $sFile = _PosterPath($k)
	If FileExists($sFile) Then
		Local $iIdx = _AddPosterToList($sFile)
		If $iIdx >= 0 Then
			$g_oImg.Item($k) = $iIdx
			Return $iIdx
		EndIf
		FileDelete($sFile) ; unreadable download, fetch it again
	EndIf
	Local $sNone = $g_PosterDir & "\" & $k & ".none"
	; a "no poster" marker is honoured for the rest of the day, then we try again
	If FileExists($sNone) And StringLeft(FileGetTime($sNone, 0, 1), 8) = @YEAR & @MON & @MDAY Then Return -1
	If Not $g_oQueued.Exists($k) Then
		$g_oQueued.Item($k) = 1
		$g_sQueue &= $k & "|"
	EndIf
	Return -1
EndFunc

Func _ApplyPoster($sId)
	Local $iIdx = _PosterIndex($sId)
	If $iIdx < 0 Then Return
	For $r = 0 To $g_aRowMap[0] - 1
		If $g_aRowSerial[$r + 1] = $sId Then _GUICtrlListView_SetItemImage($idList, $r, $iIdx)
	Next
EndFunc

; Called from the main loop: keeps up to 3 poster downloads running in the background
Func _PosterTick()
	Local $sId, $sPart, $p, $bOk
	For $s = 0 To 2
		If $g_aDLH[$s] <> 0 Then
			If InetGetInfo($g_aDLH[$s], $INET_DOWNLOADCOMPLETE) Then
				$bOk = InetGetInfo($g_aDLH[$s], $INET_DOWNLOADSUCCESS)
				InetClose($g_aDLH[$s])
				$g_aDLH[$s] = 0
				$sId = $g_aDLId[$s]
				$sPart = _PosterPath($sId) & ".part"
				If $bOk And FileGetSize($sPart) > 500 Then
					FileMove($sPart, _PosterPath($sId), $FC_OVERWRITE)
					_ApplyPoster($sId)
				Else
					FileDelete($sPart)
					FileWrite($g_PosterDir & "\" & $sId & ".none", "")
				EndIf
			EndIf
		ElseIf $g_sQueue <> "" Then
			$p = StringInStr($g_sQueue, "|")
			$sId = StringLeft($g_sQueue, $p - 1)
			$g_sQueue = StringTrimLeft($g_sQueue, $p)
			$g_aDLId[$s] = $sId
			$g_aDLH[$s] = InetGet($g_sUrlPoster & $sId & "/artwork/boxart.jpg", _PosterPath($sId) & ".part", $INET_FORCERELOAD, $INET_DOWNLOADBACKGROUND)
		EndIf
	Next
EndFunc

; ===== Main window =====
Func _BuildGUI()
	$hGUI = GUICreate("Xenia Guy: A Xenia Canary GUI", 1240, 776)
	GUISetFont(9, 400, 0, "Segoe UI")
	GUISetBkColor(0xF4F5F7)

	; header band - built from pieces that leave the search box area free, so nothing can sit on top of it
	GUICtrlCreateLabel("", 0, 0, 830, 64)
	GUICtrlSetBkColor(-1, 0xFFFFFF)
	GUICtrlCreateLabel("", 830, 0, 410, 19)
	GUICtrlSetBkColor(-1, 0xFFFFFF)
	GUICtrlCreateLabel("", 830, 45, 410, 19)
	GUICtrlSetBkColor(-1, 0xFFFFFF)
	GUICtrlCreateLabel("", 1220, 19, 20, 26)
	GUICtrlSetBkColor(-1, 0xFFFFFF)
	Local $idTitle = GUICtrlCreateLabel("Xenia Guy", 20, 8, 400, 30)
	GUICtrlSetFont($idTitle, 17, 600, 0, "Segoe UI")
	GUICtrlSetBkColor($idTitle, $GUI_BKCOLOR_TRANSPARENT)
	$g_idSub = GUICtrlCreateLabel("", 20, 40, 700, 18)
	GUICtrlSetColor($g_idSub, 0x707070)
	GUICtrlSetBkColor($g_idSub, $GUI_BKCOLOR_TRANSPARENT)
	$idSearch = GUICtrlCreateInput("", 830, 19, 390, 26)
	GUICtrlSetFont($idSearch, 10, 400, 0, "Segoe UI")
	_GUICtrlEdit_SetCueBanner(GUICtrlGetHandle($idSearch), "Search games or file names...", True)
	; HWND_TOP: make sure the search box is the top-most control at its position
	DllCall("user32.dll", "bool", "SetWindowPos", "hwnd", GUICtrlGetHandle($idSearch), "hwnd", 0, "int", 0, "int", 0, "int", 0, "int", 0, "uint", 0x13)
	GUICtrlCreateLabel("", 0, 64, 1240, 1)
	GUICtrlSetBkColor(-1, 0xD8D8D8)

	; toolbar
	$idPlay    = GUICtrlCreateButton("Boot", 20, 78, 84, 30)
	$idStop    = GUICtrlCreateButton("Stop", 110, 78, 84, 30)
	$idOpen    = GUICtrlCreateButton("Games Folder", 226, 78, 110, 30)
	$idRefresh = GUICtrlCreateButton("Refresh List", 342, 78, 110, 30)
	$idConfig  = GUICtrlCreateButton("Global Config", 1002, 78, 120, 30)
	$idUpdates = GUICtrlCreateButton("Updates", 1130, 78, 90, 30)

	$idList = GUICtrlCreateListView("Icon|Name|Serial|Version|Compatibility|Space On Disk", 20, 120, 1200, 618, BitOR($LVS_SHOWSELALWAYS, $LVS_SINGLESEL), _
			BitOR($LVS_EX_FULLROWSELECT, $LVS_EX_GRIDLINES, $LVS_EX_DOUBLEBUFFER))
	GUICtrlSetFont($idList, 10, 400, 0, "Segoe UI")
	_GUICtrlListView_SetColumnWidth($idList, 0, 66)
	_GUICtrlListView_SetColumnWidth($idList, 1, 580)
	_GUICtrlListView_SetColumnWidth($idList, 2, 100)
	_GUICtrlListView_SetColumnWidth($idList, 3, 80)
	_GUICtrlListView_SetColumnWidth($idList, 4, 200)
	_GUICtrlListView_SetColumnWidth($idList, 5, 130)
	$g_hIL = _GUIImageList_Create($g_iPosterW, $g_iPosterH)
	_GUICtrlListView_SetImageList($idList, $g_hIL, 1)

	$g_idHint = GUICtrlCreateLabel($g_sHint, 20, 748, 1200, 18)
	GUICtrlSetColor($g_idHint, $XG_INFO)

	$idContext = GUICtrlCreateContextMenu($idList)
	$idBootCustom = GUICtrlCreateMenuItem("Boot with custom config", $idContext)
	$idBootGlobal = GUICtrlCreateMenuItem("Boot with global config", $idContext)
	GUICtrlCreateMenuItem("", $idContext)
	$idManagePatches = GUICtrlCreateMenuItem("Manage game patches", $idContext)
	$idCustomConfig = GUICtrlCreateMenuItem("Custom config", $idContext)
	GUICtrlCreateMenuItem("", $idContext)
	$idShortcut = GUICtrlCreateMenuItem("Create a desktop shortcut", $idContext)

	GUIRegisterMsg($WM_NOTIFY, "_OnNotify")
	GUISetState()
EndFunc

; Dumps (STFS packages / Games on Demand) have no extension. They start with LIVE, PIRS or "CON "
; and carry a content type at 0x344 - only game-like types are accepted.
Func _IsStfsGame($sPath)
	Local $h = FileOpen($sPath, BitOR($FO_READ, $FO_BINARY))
	If $h = -1 Then Return False
	Local $sMagic = String(FileRead($h, 4))
	Local $bOk = False
	If $sMagic = "0x4C495645" Or $sMagic = "0x50495253" Or $sMagic = "0x434F4E20" Then
		FileSetPos($h, 0x344, 0)
		Local $sType = String(FileRead($h, 4))
		$bOk = ($sType = "0x00007000" Or $sType = "0x00004000" Or $sType = "0x00001000" Or $sType = "0x000D0000" Or $sType = "0x000A0000")
	EndIf
	FileClose($h)
	Return $bOk
EndFunc

Func _ScanGames($bFill = True)
	Local $aImg = _FileListToArrayRec($g_GameDir, "*.iso;*.xex;*.zar", 1, 1, 1, 2)
	Local $aAll = _FileListToArrayRec($g_GameDir, "*", 1, 1, 0, 2)
	Local $sAll = ""
	If IsArray($aImg) Then
		For $i = 1 To $aImg[0]
			$sAll &= $aImg[$i] & "|"
		Next
	EndIf
	If IsArray($aAll) Then
		For $i = 1 To $aAll[0]
			; skip anything with a normal extension and the data folders that belong to Games on Demand
			If StringRegExp($aAll[$i], "\.[A-Za-z0-9]{1,5}$") Then ContinueLoop
			If StringInStr($aAll[$i], ".data\") Then ContinueLoop
			If _IsStfsGame($aAll[$i]) Then $sAll &= $aAll[$i] & "|"
		Next
	EndIf
	$g_oSize.RemoveAll()
	If $sAll = "" Then
		$g_aGames = 0
	Else
		$g_aGames = StringSplit(StringTrimRight($sAll, 1), "|")
		Local $iBytes
		For $i = 1 To $g_aGames[0]
			$iBytes = FileGetSize($g_aGames[$i])
			If FileExists($g_aGames[$i] & ".data") Then $iBytes += DirGetSize($g_aGames[$i] & ".data") ; Games on Demand keep their content here
			$g_oSize.Item($g_aGames[$i]) = $iBytes
		Next
	EndIf
	If $bFill Then _FillList(GUICtrlRead($idSearch))
EndFunc

; Shows what is already known right away, then identifies the remaining games one at a time;
; every game appears in the list (at its sorted position) as soon as it has been identified.
Func _FillList($sFilter)
	_BuildRows($sFilter)
	If IsArray($g_aGames) Then
		For $i = 1 To $g_aGames[0]
			If _IsKnown($g_aGames[$i]) Then ContinueLoop
			_GetGameInfo($g_aGames[$i]) ; identifies the game (slow) and caches the result
			_InsertRow($i, $sFilter)
		Next
	EndIf
	WinSetTitle($hGUI, "", "Xenia Guy: A Xenia Canary GUI")
	_UpdateSubtitle()
EndFunc

; True when the game has been identified before (info cached in memory or in Games.ini)
Func _IsKnown($sPath)
	If $g_oInfo.Exists($sPath) Then Return True
	If IniRead($sGamesIni, $sPath, "Serial", "") <> "" Then Return True
	Return IniRead($sGamesIni, $sPath, "Failed", "") = @YEAR & @MON & @MDAY ; a failed attempt is not repeated on the same day
EndFunc

Func _UpdateSubtitle()
	Local $iTotal = IsArray($g_aGames) ? $g_aGames[0] : 0
	Local $c = $g_aRowMap[0]
	GUICtrlSetData($g_idSub, $c & (($c = $iTotal) ? "" : " of " & $iTotal) & " game" & (($iTotal = 1) ? "" : "s") & "   -   " & $g_GameDir)
EndFunc

; Adds one (just identified) game to the list at its sorted position
Func _InsertRow($i, $sFilter)
	Local $aInfo = StringSplit(_GetGameInfo($g_aGames[$i]), "|", 2)
	Local $sSerial = StringUpper($aInfo[1])
	Local $sName = _ResolveName($sSerial, $aInfo[0])
	Local $sFile = StringRegExpReplace($g_aGames[$i], "^.*\\", "")
	If $sFilter <> "" And Not StringInStr($sName, $sFilter) And Not StringInStr($sFile, $sFilter) Then Return
	Local $iPos = 0
	While $iPos < $g_aRowMap[0] And StringCompare($g_aRowName[$iPos + 1], $sName) <= 0
		$iPos += 1
	WEnd
	Local $sState = _GetCompat($sSerial)
	_RowIns($g_aRowMap, $iPos + 1, $i)
	_RowIns($g_aRowState, $iPos + 1, $sState)
	_RowIns($g_aRowSerial, $iPos + 1, $sSerial)
	_RowIns($g_aRowName, $iPos + 1, $sName)
	_RowIns($g_aRowFile, $iPos + 1, $sFile)
	_RowIns($g_aRowDate, $iPos + 1, _GetCompatDate($sSerial))
	$g_aRowMap[0] += 1
	_ListAddRow($iPos, $sName, $sSerial, $aInfo[2], $sState, _FmtSize($g_oSize.Item($g_aGames[$i])))
	_UpdateSubtitle()
EndFunc

Func _FmtSize($iBytes)
	Return Round($iBytes / 1073741824, 2) & " GiB"
EndFunc

; Adds one row to the list view at $iPos (-1 = at the end), with the poster when there is one
Func _ListAddRow($iPos, $sName, $sSerial, $sVersion, $sState, $sSize)
	Local $iImg = _PosterIndex($sSerial)
	Local $iRow = _GUICtrlListView_InsertItem($idList, "", $iPos, ($iImg < 0) ? -1 : $iImg)
	If $iImg < 0 Then _GUICtrlListView_SetItemImage($idList, $iRow, -2) ; -2 = no image (-1 would show a stale one)
	_GUICtrlListView_AddSubItem($idList, $iRow, $sName, 1)
	_GUICtrlListView_AddSubItem($idList, $iRow, $sSerial, 2)
	_GUICtrlListView_AddSubItem($idList, $iRow, $sVersion, 3)
	_GUICtrlListView_AddSubItem($idList, $iRow, $sState, 4)
	_GUICtrlListView_AddSubItem($idList, $iRow, $sSize, 5)
EndFunc

; Inserts one element into a 1D array. _ArrayInsert is avoided on purpose: it splits strings on "|"
; and mishandles empty values, which left the row arrays out of step with the list.
Func _RowIns(ByRef $a, $iIdx, $vVal)
	Local $n = UBound($a)
	If $iIdx > $n Then $iIdx = $n
	ReDim $a[$n + 1]
	For $k = $n To $iIdx + 1 Step -1
		$a[$k] = $a[$k - 1]
	Next
	$a[$iIdx] = $vVal
EndFunc

; Rebuilds the list from the games that are already identified
Func _BuildRows($sFilter)
	_GUICtrlListView_BeginUpdate($idList)
	_GUICtrlListView_DeleteAllItems($idList)
	ReDim $g_aRowMap[1], $g_aRowState[1], $g_aRowSerial[1], $g_aRowName[1], $g_aRowFile[1], $g_aRowDate[1]
	$g_aRowMap[0] = 0
	Local $iTotal = 0, $c = 0
	If IsArray($g_aGames) Then
		$iTotal = $g_aGames[0]
		Local $aRows[$iTotal]
		Local $aInfo, $sSerial, $sName, $sFile
		For $i = 1 To $iTotal
			If Not _IsKnown($g_aGames[$i]) Then ContinueLoop ; identified later, one at a time
			$aInfo = StringSplit(_GetGameInfo($g_aGames[$i]), "|", 2)
			$sSerial = StringUpper($aInfo[1])
			$sName = _ResolveName($sSerial, $aInfo[0])
			$sFile = StringRegExpReplace($g_aGames[$i], "^.*\\", "")
			If $sFilter <> "" And Not StringInStr($sName, $sFilter) And Not StringInStr($sFile, $sFilter) Then ContinueLoop
			; one record per game, sorted by name: name, game index, serial, version, rating, size, file name, check date
			$aRows[$c] = $sName & Chr(1) & $i & Chr(1) & $sSerial & Chr(1) & $aInfo[2] & Chr(1) & _GetCompat($sSerial) & Chr(1) & _
					_FmtSize($g_oSize.Item($g_aGames[$i])) & Chr(1) & $sFile & Chr(1) & _GetCompatDate($sSerial)
			$c += 1
		Next
		If $c > 0 Then
			ReDim $aRows[$c]
			_ArraySort($aRows)
			ReDim $g_aRowMap[$c + 1], $g_aRowState[$c + 1], $g_aRowSerial[$c + 1], $g_aRowName[$c + 1], $g_aRowFile[$c + 1], $g_aRowDate[$c + 1]
			$g_aRowMap[0] = $c
			Local $aF
			For $r = 0 To $c - 1
				$aF = StringSplit($aRows[$r], Chr(1), 2)
				$g_aRowMap[$r + 1] = Int($aF[1])
				$g_aRowName[$r + 1] = $aF[0]
				$g_aRowSerial[$r + 1] = $aF[2]
				$g_aRowState[$r + 1] = $aF[4]
				$g_aRowFile[$r + 1] = $aF[6]
				$g_aRowDate[$r + 1] = $aF[7]
				_ListAddRow(-1, $aF[0], $aF[2], $aF[3], $aF[4], $aF[5])
			Next
		EndIf
	EndIf
	_GUICtrlListView_EndUpdate($idList)
	_UpdateSubtitle()
EndFunc

Func _GetSelectedPath()
	Local $iSel = _GUICtrlListView_GetSelectedIndices($idList)
	If $iSel = "" Then Return ""
	Local $iRow = Int($iSel)
	If $iRow < 0 Or $iRow >= $g_aRowMap[0] Then Return ""
	Local $iIdx = $g_aRowMap[$iRow + 1]
	If $iIdx < 1 Or $iIdx > $g_aGames[0] Then Return ""
	Return $g_aGames[$iIdx]
EndFunc

Func _GetSelectedName()
	Local $iSel = _GUICtrlListView_GetSelectedIndices($idList)
	If $iSel = "" Then Return ""
	Return _GUICtrlListView_GetItemText($idList, Int($iSel), 1)
EndFunc

; ===== Custom parameters =====
; Parameters are stored in Games.ini without dashes, separated by "|", and get "--" added when the game starts.
; ---- setting names known to Xenia, read from the global config file ----
Func _LoadKnownSettings()
	$g_oKnown = 0
	Local $sFile = @ScriptDir & "\xenia-canary.config.toml"
	If Not FileExists($sFile) Then Return False
	Local $h = FileOpen($sFile, BitOR($FO_READ, $FO_UTF8_NOBOM))
	If $h = -1 Then Return False
	Local $sText = FileRead($h)
	FileClose($h)
	; "key = value" lines; a key that was commented out ("#key = value", no space after #) still counts
	Local $a = StringRegExp($sText, "(?m)^[ \t]*#?([A-Za-z_][A-Za-z0-9_]*)[ \t]*=", 3)
	If Not IsArray($a) Then Return False
	Local $o = ObjCreate("Scripting.Dictionary")
	For $i = 0 To UBound($a) - 1
		$o.Item(StringLower($a[$i])) = $a[$i]
	Next
	$g_oKnown = $o
	Return True
EndFunc

; Splits on white space; text inside double quotes stays together (the quotes themselves are dropped)
Func _SplitTokens($sLine)
	Local $aOut[0], $sTok = "", $bQ = False, $bHas = False, $c
	For $i = 1 To StringLen($sLine)
		$c = StringMid($sLine, $i, 1)
		If $c = '"' Then
			$bQ = Not $bQ
			$bHas = True
		ElseIf ($c = " " Or $c = @TAB) And Not $bQ Then
			If $bHas Then
				ReDim $aOut[UBound($aOut) + 1]
				$aOut[UBound($aOut) - 1] = $sTok
			EndIf
			$sTok = ""
			$bHas = False
		Else
			$sTok &= $c
			$bHas = True
		EndIf
	Next
	If $bHas Then
		ReDim $aOut[UBound($aOut) + 1]
		$aOut[UBound($aOut) - 1] = $sTok
	EndIf
	Return $aOut
EndFunc

; Does this token begin a new parameter (as opposed to being part of the previous value, e.g. a path with a space)?
Func _IsParamStart($sTok)
	Local $s = StringRegExpReplace($sTok, "^-+", "")
	If $s <> $sTok Then Return True ; it has dashes
	Local $sKey = StringRegExpReplace($s, "=.*$", "")
	If IsObj($g_oKnown) And $g_oKnown.Exists(StringLower($sKey)) Then Return True
	If StringInStr($s, "=") And StringRegExp($sKey, "^[A-Za-z_][A-Za-z0-9_]*$") Then Return True
	Return False
EndFunc

; Cleans free-form parameter text and returns one "key=value" (or "key") per line, separated by @LF.
; - any number of parameters per line, with or without leading dashes
; - duplicates are removed (the last one wins)
; - with $bValidate, names that are not in the global config are removed too
; $sRemoved receives what was dropped and why, one per line.
Func _CleanParams($sText, ByRef $sRemoved, $bValidate = True)
	$sRemoved = ""
	$sText = StringReplace(StringReplace($sText, "|", @LF), @CR, "")
	Local $aLines = StringSplit($sText, @LF, 2)
	Local $aKeys[0], $aVals[0], $aTok, $aP[0], $sP, $sKey, $sVal, $iEq, $iN
	For $l = 0 To UBound($aLines) - 1
		$aTok = _SplitTokens($aLines[$l])
		ReDim $aP[0]
		For $t = 0 To UBound($aTok) - 1
			If _IsParamStart($aTok[$t]) Or UBound($aP) = 0 Then
				ReDim $aP[UBound($aP) + 1]
				$aP[UBound($aP) - 1] = $aTok[$t]
			Else
				$aP[UBound($aP) - 1] &= " " & $aTok[$t] ; continuation of a value that contains spaces
			EndIf
		Next
		For $k = 0 To UBound($aP) - 1
			$sP = StringRegExpReplace($aP[$k], "^-+", "")
			$iEq = StringInStr($sP, "=")
			If $iEq Then
				$sKey = StringStripWS(StringLeft($sP, $iEq - 1), 3)
				$sVal = StringStripWS(StringTrimLeft($sP, $iEq), 3)
			Else
				$sKey = StringStripWS($sP, 3)
				$sVal = ""
			EndIf
			If $sKey = "" Then ContinueLoop
			If Not StringRegExp($sKey, "^[A-Za-z_][A-Za-z0-9_]*$") Then
				$sRemoved &= $aP[$k] & "  (not a valid name)" & @LF
				ContinueLoop
			EndIf
			If $bValidate And IsObj($g_oKnown) Then
				If Not $g_oKnown.Exists(StringLower($sKey)) Then
					$sRemoved &= $sKey & "  (not in the config file)" & @LF
					ContinueLoop
				EndIf
				$sKey = $g_oKnown.Item(StringLower($sKey)) ; use the spelling from the config file
			EndIf
			$iN = UBound($aKeys)
			ReDim $aKeys[$iN + 1], $aVals[$iN + 1]
			$aKeys[$iN] = $sKey
			$aVals[$iN] = $iEq ? $sKey & "=" & $sVal : $sKey
		Next
	Next

	; redundant parameters: the same setting given more than once
	Local $oLast = ObjCreate("Scripting.Dictionary"), $sOut = ""
	For $i = 0 To UBound($aKeys) - 1
		$oLast.Item(StringLower($aKeys[$i])) = $i
	Next
	For $i = 0 To UBound($aKeys) - 1
		If $oLast.Item(StringLower($aKeys[$i])) <> $i Then
			$sRemoved &= $aVals[$i] & "  (repeated, the last one is used)" & @LF
		Else
			$sOut &= $aVals[$i] & @LF
		EndIf
	Next
	$sRemoved = StringTrimRight($sRemoved, 1)
	Return StringTrimRight($sOut, 1)
EndFunc

; Shows the vertical scroll bar of a multi-line edit only when its text does not fit
Func _EditScrollSync($idEdit)
	Local $hEdit = GUICtrlGetHandle($idEdit)
	Local $iLines = _GUICtrlEdit_GetLineCount($hEdit)
	Local $bNeed = False
	If $iLines >= 2 Then
		Local $aR = _GUICtrlEdit_GetRECT($hEdit)
		Local $aA = _GUICtrlEdit_PosFromChar($hEdit, 0)
		Local $aB = _GUICtrlEdit_PosFromChar($hEdit, _GUICtrlEdit_LineIndex($hEdit, $iLines - 1))
		If IsArray($aR) And IsArray($aA) And IsArray($aB) Then
			Local $iLineH = ($aB[1] - $aA[1]) / ($iLines - 1)
			If $iLineH > 0 Then $bNeed = (($iLines + 0.2) * $iLineH > ($aR[3] - $aR[1]))
		EndIf
	EndIf
	DllCall("user32.dll", "bool", "ShowScrollBar", "hwnd", $hEdit, "int", 1, "bool", $bNeed)
EndFunc

; Clean parameters (see _CleanParams) without checking the names, separated by @LF
Func _NormalizeParams($sText)
	Local $sRem
	Return _CleanParams($sText, $sRem, False)
EndFunc

; Turns clean parameters (@LF separated) into a command line fragment: " --a=1 --b"
Func _ArgsString($sNorm)
	If $sNorm = "" Then Return ""
	Local $a = StringSplit($sNorm, @LF, 2), $s = ""
	For $i = 0 To UBound($a) - 1
		If StringInStr($a[$i], " ") Then
			$s &= ' "--' & $a[$i] & '"'
		Else
			$s &= " --" & $a[$i]
		EndIf
	Next
	Return $s
EndFunc

Func _GetCustomArgs($sPath)
	Return _ArgsString(_NormalizeParams(IniRead($sGamesIni, $sPath, "CustomArgs", "")))
EndFunc

; Boots the selected game. The game's custom parameters are used unless $bCustom is False.
Func _Play($bCustom = True)
	Local $sPath = _GetSelectedPath()
	If $sPath = "" Then
		_Status("Select a game first.", $XG_WARN)
		Return
	EndIf
	If ProcessExists($g_PID) Then
		_Status("Xenia is already running. Stop it first.", $XG_WARN)
		Return
	EndIf
	If Not FileExists($g_Xenia) Then
		_Status("xenia_canary.exe was not found next to this program.", $XG_ERR)
		Return
	EndIf
	Local $sCmd = '"' & $g_Xenia & '" "' & $sPath & '"'
	If $bCustom Then $sCmd &= _GetCustomArgs($sPath)
	$g_PID = Run($sCmd, @ScriptDir)
	If $g_PID = 0 Then
		_Status("Could not start xenia_canary.exe.", $XG_ERR)
	Else
		_Status("Booting " & _GetSelectedName() & ($bCustom ? "" : " with the global config") & "...", $XG_OK)
	EndIf
EndFunc

Func _Stop()
	If ProcessExists($g_PID) Then ProcessClose($g_PID)
EndFunc

Func _BootCustom()
	_Play(True)
EndFunc

Func _BootGlobal()
	_Play(False)
EndFunc

; ===== Game patches =====
Func _FindPatchFile($sTitleId)
	If $sTitleId = "" Or Not FileExists($sPatchesDir) Then Return ""
	Local $aFiles = _FileListToArray($sPatchesDir, $sTitleId & "*.patch.toml", 1)
	If IsArray($aFiles) And $aFiles[0] > 0 Then Return $sPatchesDir & "\" & $aFiles[1]
	Return ""
EndFunc

Func _ReadPatchEntries($sFile, ByRef $aNames, ByRef $aEnabled, ByRef $aAuthors, ByRef $aDescs, ByRef $aStarts, ByRef $aEnds)
	Local $h = FileOpen($sFile, BitOR($FO_READ, $FO_UTF8_NOBOM))
	If $h = -1 Then Return 0
	Local $sText = FileRead($h)
	FileClose($h)
	Local $aLines = StringSplit(StringReplace($sText, @CR, ""), @LF, 2)
	ReDim $aNames[0], $aEnabled[0], $aAuthors[0], $aDescs[0], $aStarts[0], $aEnds[0]
	Local $iPatch = -1
	For $i = 0 To UBound($aLines) - 1
		Local $sLine = StringStripWS($aLines[$i], 3)
		If $sLine = "[[patch]]" Then
			If $iPatch >= 0 Then $aEnds[$iPatch] = $i - 1
			$iPatch += 1
			ReDim $aNames[$iPatch + 1], $aEnabled[$iPatch + 1], $aAuthors[$iPatch + 1], $aDescs[$iPatch + 1], $aStarts[$iPatch + 1], $aEnds[$iPatch + 1]
			$aStarts[$iPatch] = $i
			$aEnds[$iPatch] = UBound($aLines) - 1
			$aNames[$iPatch] = "Patch " & ($iPatch + 1)
			$aAuthors[$iPatch] = ""
			$aDescs[$iPatch] = ""
			$aEnabled[$iPatch] = False
		ElseIf $iPatch >= 0 Then
			Local $aM = StringRegExp($sLine, '^name\s*=\s*"([^"]*)"', 1)
			If IsArray($aM) Then $aNames[$iPatch] = $aM[0]
			$aM = StringRegExp($sLine, '^author\s*=\s*"([^"]*)"', 1)
			If IsArray($aM) Then $aAuthors[$iPatch] = $aM[0]
			$aM = StringRegExp($sLine, '^desc\s*=\s*"([^"]*)"', 1)
			If IsArray($aM) Then $aDescs[$iPatch] = $aM[0]
			$aM = StringRegExp($sLine, '^is_enabled\s*=\s*(true|false)', 1)
			If IsArray($aM) Then $aEnabled[$iPatch] = ($aM[0] = "true")
		EndIf
	Next
	If $iPatch >= 0 Then $aEnds[$iPatch] = UBound($aLines) - 1
	Return $iPatch + 1
EndFunc

; ---- patch choices live in Games.ini, in the game's own section: Patches=|name|name| (enabled patches only) ----
; Patches are inactive by default, so only the enabled ones are stored. Xenia's patch files are replaced on every
; update, so the choice is kept here and re-applied to the patch file afterwards.
Func _PatchKey($s)
	Return StringReplace($s, "|", "/")
EndFunc

; $sOn = "|name|name|" of the patches that should be enabled; every other patch in the file is switched off.
; Applied to one patch file in a single read and a single write. True if the file changed.
Func _ApplyChoicesToFile($sFile, $sOn)
	Local $h = FileOpen($sFile, BitOR($FO_READ, $FO_UTF8_NOBOM))
	If $h = -1 Then Return False
	Local $sText = FileRead($h)
	FileClose($h)
	Local $aLines = StringSplit($sText, @LF, 2)
	Local $iN = UBound($aLines)
	Local $iBlock = -1, $iEnabledIdx = -1, $sPName = "", $bChanged = False
	Local $sLine, $aM, $iWant, $sCur, $sIndent, $sCR
	For $i = 0 To $iN
		$sLine = ""
		If $i < $iN Then $sLine = StringStripWS($aLines[$i], 3)
		If $i = $iN Or $sLine = "[[patch]]" Then
			; close the previous patch block
			If $iBlock >= 0 And $iEnabledIdx >= 0 And $sPName <> "" Then
				$iWant = StringInStr($sOn, "|" & _PatchKey($sPName) & "|", 1) ? 1 : 0
				$sCur = $aLines[$iEnabledIdx]
				If (StringRegExp($sCur, "=\s*true") ? 1 : 0) <> $iWant Then
					$sIndent = StringRegExpReplace($sCur, "^(\s*).*$", "\1")
					$sCR = (StringRight($sCur, 1) = @CR) ? @CR : ""
					$aLines[$iEnabledIdx] = $sIndent & "is_enabled = " & (($iWant = 1) ? "true" : "false") & $sCR
					$bChanged = True
				EndIf
			EndIf
			$iBlock = $i
			$iEnabledIdx = -1
			$sPName = ""
		ElseIf $iBlock >= 0 Then
			$aM = StringRegExp($sLine, '^name\s*=\s*"([^"]*)"', 1)
			If IsArray($aM) Then $sPName = $aM[0]
			If StringRegExp($sLine, "^is_enabled\s*=") Then $iEnabledIdx = $i
		EndIf
	Next
	If Not $bChanged Then Return False
	$h = FileOpen($sFile, BitOR($FO_OVERWRITE, $FO_UTF8_NOBOM))
	If $h = -1 Then Return False
	FileWrite($h, _ArrayToString($aLines, @LF))
	FileClose($h)
	Return True
EndFunc

; Applies a list of enabled patches to every patch file of one title. Returns how many files changed.
Func _ApplyPatchChoices($sTitleId, $sOn)
	If $sTitleId = "" Or Not FileExists($sPatchesDir) Then Return 0
	Local $aFiles = _FileListToArray($sPatchesDir, $sTitleId & "*.patch.toml", 1)
	If Not IsArray($aFiles) Then Return 0
	Local $iChanged = 0
	For $f = 1 To $aFiles[0]
		If _ApplyChoicesToFile($sPatchesDir & "\" & $aFiles[$f], $sOn) Then $iChanged += 1
	Next
	Return $iChanged
EndFunc

; Saves the enabled patches under the game's file name in Games.ini (nothing is stored when none are enabled).
Func _SavePatchChoices($sPath, $sTitleId, ByRef $aNames, ByRef $aChecked)
	Local $sOn = "|"
	For $i = 0 To UBound($aNames) - 1
		If $aChecked[$i] Then $sOn &= _PatchKey($aNames[$i]) & "|"
	Next
	If $sOn = "|" Then
		IniDelete($sGamesIni, $sPath, "Patches")
	Else
		IniWrite($sGamesIni, $sPath, "Patches", $sOn)
	EndIf
	_ApplyPatchChoices($sTitleId, $sOn)
EndFunc

; Only games with saved choices are touched - the other few hundred patch files are left alone.
Func _ReapplyAllPatchChoices()
	Local $aSec = IniReadSectionNames($sGamesIni)
	If @error Then Return 0
	Local $sOn, $iFiles = 0
	For $i = 1 To $aSec[0]
		$sOn = IniRead($sGamesIni, $aSec[$i], "Patches", "")
		If $sOn = "" Then ContinueLoop
		$iFiles += _ApplyPatchChoices(IniRead($sGamesIni, $aSec[$i], "Serial", ""), $sOn)
	Next
	Return $iFiles
EndFunc

; One-time move of the old [Patches] <TitleID>.on / .off entries into each game's own section.
Func _MigratePatchChoices()
	If Not IsArray($g_aGames) Then Return
	Local $sSerial, $sOn
	For $i = 1 To $g_aGames[0]
		If IniRead($sGamesIni, $g_aGames[$i], "Patches", "") <> "" Then ContinueLoop
		$sSerial = IniRead($sGamesIni, $g_aGames[$i], "Serial", "")
		If $sSerial = "" Then ContinueLoop
		$sOn = IniRead($sGamesIni, "Patches", $sSerial & ".on", "")
		If $sOn <> "" And $sOn <> "|" Then IniWrite($sGamesIni, $g_aGames[$i], "Patches", $sOn)
		IniDelete($sGamesIni, "Patches", $sSerial & ".on")
		IniDelete($sGamesIni, "Patches", $sSerial & ".off")
	Next
EndFunc

Func _ManagePatches()
	Local $sPath = _GetSelectedPath()
	If $sPath = "" Then Return
	Local $aInfo = StringSplit(_GetGameInfo($sPath), "|", 2)
	Local $sTitleId = $aInfo[1]
	Local $sName = _ResolveName($sTitleId, $aInfo[0])
	$g_PatchFile = _FindPatchFile($sTitleId)

	Local $aNames[0], $aEnabled[0], $aAuthors[0], $aDescs[0], $aStarts[0], $aEnds[0]
	Local $iCount = 0
	If $g_PatchFile <> "" Then $iCount = _ReadPatchEntries($g_PatchFile, $aNames, $aEnabled, $aAuthors, $aDescs, $aStarts, $aEnds)

	Local $hDlg = GUICreate("Game patches", 860, 520, -1, -1, -1, -1, $hGUI)
	_CenterOnParent($hDlg, $hGUI)
	GUISetFont(9, 400, 0, "Segoe UI", $hDlg)

	; header band
	GUICtrlCreateLabel("", 0, 0, 860, 64)
	GUICtrlSetBkColor(-1, 0xFFFFFF)
	Local $idTitle = GUICtrlCreateLabel($sName, 20, 10, 820, 28)
	GUICtrlSetFont($idTitle, 14, 600, 0, "Segoe UI")
	GUICtrlSetBkColor($idTitle, $GUI_BKCOLOR_TRANSPARENT)
	Local $idSub = GUICtrlCreateLabel("Title ID " & $sTitleId & "   -   " & $iCount & " patch" & (($iCount = 1) ? "" : "es"), 20, 40, 820, 18)
	GUICtrlSetColor($idSub, 0x707070)
	GUICtrlSetBkColor($idSub, $GUI_BKCOLOR_TRANSPARENT)
	GUICtrlCreateLabel("", 0, 64, 860, 1)
	GUICtrlSetBkColor(-1, 0xD8D8D8)

	; left: patch list
	Local $idHead1 = GUICtrlCreateLabel("PATCHES", 20, 80, 200, 16)
	GUICtrlSetFont($idHead1, 8, 700)
	GUICtrlSetColor($idHead1, 0x707070)
	Local $idPList = GUICtrlCreateListView("Patch", 20, 100, 400, 316, BitOR($LVS_SHOWSELALWAYS, $LVS_SINGLESEL), BitOR($LVS_EX_FULLROWSELECT, $LVS_EX_CHECKBOXES, $LVS_EX_DOUBLEBUFFER))
	_GUICtrlListView_SetColumnWidth($idPList, 0, 376)
	Local $idAll = GUICtrlCreateButton("Enable all", 20, 426, 90, 28)
	Local $idNone = GUICtrlCreateButton("Disable all", 116, 426, 90, 28)
	Local $idCount = GUICtrlCreateLabel("", 220, 432, 200, 18, 0x02) ; right aligned
	GUICtrlSetColor($idCount, 0x707070)

	; right: details of the selected patch
	Local $idHead2 = GUICtrlCreateLabel("DETAILS", 444, 80, 200, 16)
	GUICtrlSetFont($idHead2, 8, 700)
	GUICtrlSetColor($idHead2, 0x707070)
	Local $idPName = GUICtrlCreateLabel("", 444, 102, 396, 26)
	GUICtrlSetFont($idPName, 12, 600)
	Local $idPAuthor = GUICtrlCreateLabel("", 444, 132, 396, 18)
	GUICtrlSetColor($idPAuthor, 0x707070)
	Local $idPDesc = GUICtrlCreateEdit("", 444, 160, 396, 256, BitOR($ES_READONLY, $ES_MULTILINE), 0)
	Local $idNote = GUICtrlCreateLabel("Patches only apply when apply_patches is true in Global Config. Enabled patches are remembered across patch updates.", 444, 426, 396, 34)
	GUICtrlSetColor($idNote, 0x707070)

	; footer
	Local $idFile = GUICtrlCreateLabel("", 20, 474, 600, 20)
	GUICtrlSetColor($idFile, 0x707070)
	Local $idSave = GUICtrlCreateButton("Save", 650, 470, 90, 32)
	Local $idCancel = GUICtrlCreateButton("Cancel", 750, 470, 90, 32)

	If $iCount = 0 Then
		GUICtrlSetData($idFile, "No patch file was found for this game in " & $sPatchesDir)
		GUICtrlSetData($idPName, "No patches")
		GUICtrlSetData($idPDesc, "Use Updates > Update game patches to download the patch collection.")
		GUICtrlSetState($idSave, $GUI_DISABLE)
		GUICtrlSetState($idAll, $GUI_DISABLE)
		GUICtrlSetState($idNone, $GUI_DISABLE)
	Else
		GUICtrlSetData($idFile, "File: " & StringRegExpReplace($g_PatchFile, "^.*\\", ""))
		For $i = 0 To $iCount - 1
			_GUICtrlListView_AddItem($idPList, $aNames[$i])
			If $aEnabled[$i] Then _GUICtrlListView_SetItemChecked($idPList, $i, True)
		Next
		_GUICtrlListView_SetItemSelected($idPList, 0, True)
	EndIf

	GUISetState(@SW_SHOW, $hDlg)
	GUISetState(@SW_DISABLE, $hGUI)

	; the details panel and counter are only rewritten when they change, which keeps them from flickering
	Local $iLastSel = -2, $iLastChecked = -1, $iSel, $iChecked, $m, $sFeedback = ""
	While 1
		$m = GUIGetMsg()
		Switch $m
			Case $GUI_EVENT_CLOSE, $idCancel
				ExitLoop
			Case $idAll, $idNone
				For $i = 0 To $iCount - 1
					_GUICtrlListView_SetItemChecked($idPList, $i, ($m = $idAll))
				Next
			Case $idSave
				If $iCount > 0 Then
					Local $aChk[$iCount]
					For $i = 0 To $iCount - 1
						$aChk[$i] = _GUICtrlListView_GetItemChecked($idPList, $i)
					Next
					_SavePatchChoices($sPath, $sTitleId, $aNames, $aChk)
					$sFeedback = "Patches saved for " & $sName & "."
				EndIf
				ExitLoop
		EndSwitch

		If $iCount > 0 Then
			$iSel = _GUICtrlListView_GetSelectedIndices($idPList)
			If $iSel = "" Then
				$iSel = -1
			Else
				$iSel = Int($iSel)
			EndIf
			If $iSel <> $iLastSel Then
				$iLastSel = $iSel
				If $iSel >= 0 And $iSel < $iCount Then
					GUICtrlSetData($idPName, $aNames[$iSel])
					GUICtrlSetData($idPAuthor, ($aAuthors[$iSel] = "") ? "" : "by " & $aAuthors[$iSel])
					GUICtrlSetData($idPDesc, ($aDescs[$iSel] = "") ? "No description." : $aDescs[$iSel])
				EndIf
			EndIf
			$iChecked = 0
			For $i = 0 To $iCount - 1
				If _GUICtrlListView_GetItemChecked($idPList, $i) Then $iChecked += 1
			Next
			If $iChecked <> $iLastChecked Then
				$iLastChecked = $iChecked
				GUICtrlSetData($idCount, $iChecked & " of " & $iCount & " enabled")
			EndIf
		EndIf
		Sleep(10)
	WEnd
	GUISetState(@SW_ENABLE, $hGUI)
	GUIDelete($hDlg)
	GUISwitch($hGUI)
	If $sFeedback <> "" Then _Status($sFeedback, $XG_OK)
EndFunc

; ===== Custom config window =====
Func _CustomConfig()
	Local $sPath = _GetSelectedPath()
	If $sPath = "" Then Return
	Local $sName = _GetSelectedName()
	Local $bCheck = _LoadKnownSettings() ; names are validated against the global config file
	Local $sStored = StringReplace(_NormalizeParams(IniRead($sGamesIni, $sPath, "CustomArgs", "")), @LF, @CRLF)

	Local $hDlg = GUICreate("Custom config", 560, 500, -1, -1, -1, -1, $hGUI)
	_CenterOnParent($hDlg, $hGUI)
	GUISetFont(9, 400, 0, "Segoe UI", $hDlg)

	GUICtrlCreateLabel("", 0, 0, 560, 64)
	GUICtrlSetBkColor(-1, 0xFFFFFF)
	Local $idTitle = GUICtrlCreateLabel($sName, 20, 10, 520, 28)
	GUICtrlSetFont($idTitle, 14, 600, 0, "Segoe UI")
	GUICtrlSetBkColor($idTitle, $GUI_BKCOLOR_TRANSPARENT)
	Local $idSub = GUICtrlCreateLabel("Custom launch parameters", 20, 40, 520, 18)
	GUICtrlSetColor($idSub, 0x707070)
	GUICtrlSetBkColor($idSub, $GUI_BKCOLOR_TRANSPARENT)
	GUICtrlCreateLabel("", 0, 64, 560, 1)
	GUICtrlSetBkColor(-1, 0xD8D8D8)

	Local $idHelp = GUICtrlCreateLabel("Type one or more parameters per line, with or without dashes, for example: gpu=vulkan apu=nop. " & _
			"Repeated parameters and names that are not in the config file are removed when you save.", 20, 78, 520, 36)
	GUICtrlSetColor($idHelp, 0x505050)
	; the vertical scroll bar is only shown when the text does not fit; long lines wrap
	Local $idEdit = GUICtrlCreateEdit($sStored, 20, 120, 520, 200, BitOR($ES_MULTILINE, $ES_WANTRETURN, $ES_AUTOVSCROLL, $WS_VSCROLL))
	GUICtrlSetFont($idEdit, 10, 400, 0, "Consolas")

	Local $idPHead = GUICtrlCreateLabel("COMMAND LINE PREVIEW", 20, 332, 300, 16)
	GUICtrlSetFont($idPHead, 8, 700)
	GUICtrlSetColor($idPHead, 0x707070)
	Local $idPrev = GUICtrlCreateLabel("", 20, 352, 520, 36)
	GUICtrlSetFont($idPrev, 9, 400, 0, "Consolas")
	GUICtrlSetColor($idPrev, 0x1F4E79)
	Local $idStatus = GUICtrlCreateLabel("", 20, 392, 520, 44)

	Local $idClear = GUICtrlCreateButton("Clear", 20, 452, 80, 30)
	Local $idSave = GUICtrlCreateButton("Save", 370, 452, 80, 30)
	Local $idCancel = GUICtrlCreateButton("Cancel", 460, 452, 80, 30)
	GUISetState(@SW_SHOW, $hDlg)
	GUISetState(@SW_DISABLE, $hGUI)
	_EditScrollSync($idEdit)

	Local $sPrev = Chr(1), $sCur, $sShow, $sNorm, $sRem, $sFeedback = "", $iFbColor = $XG_OK
	While 1
		Switch GUIGetMsg()
			Case $GUI_EVENT_CLOSE, $idCancel
				ExitLoop
			Case $idClear
				GUICtrlSetData($idEdit, "")
			Case $idSave
				$sNorm = _CleanParams(GUICtrlRead($idEdit), $sRem, $bCheck)
				If $sNorm = "" Then
					IniDelete($sGamesIni, $sPath, "CustomArgs")
					$sFeedback = "Custom config cleared for " & $sName & "."
				Else
					IniWrite($sGamesIni, $sPath, "CustomArgs", StringReplace($sNorm, @LF, "|"))
					$sFeedback = "Custom config saved for " & $sName & "."
				EndIf
				If $sRem <> "" Then
					$sFeedback &= " Removed: " & StringReplace($sRem, @LF, "; ")
					$iFbColor = $XG_WARN
				EndIf
				ExitLoop
		EndSwitch
		; preview, check result and scroll bar are only refreshed when the text changed
		$sCur = GUICtrlRead($idEdit)
		If $sCur <> $sPrev Then
			$sPrev = $sCur
			$sNorm = _CleanParams($sCur, $sRem, $bCheck)
			$sShow = StringStripWS(_ArgsString($sNorm), 3)
			If $sShow = "" Then $sShow = "(none - the global config is used)"
			GUICtrlSetData($idPrev, $sShow)
			If $sRem <> "" Then
				GUICtrlSetColor($idStatus, 0xB00020)
				GUICtrlSetData($idStatus, "Will be removed on save:" & @CRLF & StringReplace($sRem, @LF, "; "))
			ElseIf Not $bCheck Then
				GUICtrlSetColor($idStatus, 0x9C5700)
				GUICtrlSetData($idStatus, "xenia-canary.config.toml was not found, so setting names cannot be checked.")
			ElseIf StringStripWS($sCur, 8) = "" Then
				GUICtrlSetData($idStatus, "")
			Else
				GUICtrlSetColor($idStatus, 0x2E7D32)
				GUICtrlSetData($idStatus, "All parameters are valid.")
			EndIf
			_EditScrollSync($idEdit)
		EndIf
	WEnd

	GUISetState(@SW_ENABLE, $hGUI)
	GUIDelete($hDlg)
	GUISwitch($hGUI)
	If $sFeedback <> "" Then _Status($sFeedback, $iFbColor)
EndFunc

Func _CreateShortcut()
	Local $sPath = _GetSelectedPath()
	Local $sName = _GetSelectedName()
	If $sPath = "" Then Return
	Local $sFile = StringStripWS(StringRegExpReplace($sName, '[\\/:*?"<>|]', ""), 3) ; no characters Windows forbids in file names
	If $sFile = "" Then $sFile = "Xenia Game"
	Local $sLink = @DesktopDir & "\" & $sFile & ".lnk"
	Local $sShortcutArgs = '"' & $sPath & '"' & _GetCustomArgs($sPath)
	If FileCreateShortcut($g_Xenia, $sLink, @ScriptDir, $sShortcutArgs, "Launch " & $sName & " with Xenia") Then
		_Status("Desktop shortcut created: " & $sFile & ".lnk", $XG_OK)
	Else
		_Status("Could not create the desktop shortcut.", $XG_ERR)
	EndIf
EndFunc

; Double click boots the game; custom draw colors the Compatibility column
Func _SysColor($i)
	Local $a = DllCall("user32.dll", "int", "GetSysColor", "int", $i)
	Return $a[0]
EndFunc

; Colors (COLORREF = 0xBBGGRR) for a compatibility rating. Returns False for ratings without a color.
Func _StateColors($sState, ByRef $iBg, ByRef $iTx)
	Switch $sState
		Case "Playable"
			$iBg = 0xCEEFC6
			$iTx = 0x006100
		Case "Gameplay"
			$iBg = 0xBEF1EB
			$iTx = 0x006446
		Case "Loads"
			$iBg = 0x9CEBFF
			$iTx = 0x00579C
		Case "Unplayable"
			$iBg = 0xCEC7FF
			$iTx = 0x06009C
		Case "Unknown"
			$iBg = 0xE6E6E6
			$iTx = 0x5A5A5A
		Case Else
			$iBg = 0xE6E6E6 ; any other rating text: neutral gray
			$iTx = 0x5A5A5A
			Return False
	EndSwitch
	Return True
EndFunc

Func _DrawLine($hDC, $iL, $iT, $iR, $iB, $sText, $iColor)
	Local $tR = DllStructCreate("long;long;long;long")
	DllStructSetData($tR, 1, $iL)
	DllStructSetData($tR, 2, $iT)
	DllStructSetData($tR, 3, $iR)
	DllStructSetData($tR, 4, $iB)
	DllCall("gdi32.dll", "int", "SetTextColor", "handle", $hDC, "int", $iColor)
	; DT_SINGLELINE | DT_VCENTER | DT_NOPREFIX | DT_END_ELLIPSIS
	DllCall("user32.dll", "int", "DrawTextW", "handle", $hDC, "wstr", $sText, "int", -1, "struct*", $tR, "uint", 0x8824)
EndFunc

; Draws the Name cell (name + file name) or the Compatibility cell (rating + last check date) as two lines
Func _DrawCell($hDC, $iRow, $iSub)
	If $iRow < 0 Or $iRow + 1 > $g_aRowMap[0] Or $iRow + 1 >= UBound($g_aRowName) Then Return ; row not in the arrays (yet)
	Local $aR = _GUICtrlListView_GetSubItemRect($idList, $iRow, $iSub)
	If Not IsArray($aR) Then Return
	Local $iL = $aR[0], $iT = $aR[1], $iRt = $aR[2] - 1, $iB = $aR[3] - 1 ; leave the grid lines alone
	Local $sLine1, $sLine2, $iBg, $iTx1, $iTx2

	If $iSub = 4 Then
		_StateColors($g_aRowState[$iRow + 1], $iBg, $iTx1)
		$iTx2 = $iTx1
		$sLine1 = $g_aRowState[$iRow + 1]
		$sLine2 = $g_aRowDate[$iRow + 1]
	Else
		$sLine1 = $g_aRowName[$iRow + 1]
		$sLine2 = $g_aRowFile[$iRow + 1]
		Local $aFocus = DllCall("user32.dll", "hwnd", "GetFocus")
		If _GUICtrlListView_GetItemSelected($idList, $iRow) Then
			If $aFocus[0] = GUICtrlGetHandle($idList) Then
				$iBg = _SysColor(13) ; COLOR_HIGHLIGHT
				$iTx1 = _SysColor(14)
				$iTx2 = $iTx1
			Else
				$iBg = _SysColor(15) ; COLOR_BTNFACE for a list without focus
				$iTx1 = _SysColor(8)
				$iTx2 = 0x606060
			EndIf
		Else
			$iBg = _SysColor(5) ; COLOR_WINDOW
			$iTx1 = _SysColor(8)
			$iTx2 = 0x808080
		EndIf
	EndIf

	Local $tR = DllStructCreate("long;long;long;long")
	DllStructSetData($tR, 1, $iL)
	DllStructSetData($tR, 2, $iT)
	DllStructSetData($tR, 3, $iRt)
	DllStructSetData($tR, 4, $iB)
	Local $aBr = DllCall("gdi32.dll", "handle", "CreateSolidBrush", "int", $iBg)
	DllCall("user32.dll", "int", "FillRect", "handle", $hDC, "struct*", $tR, "handle", $aBr[0])
	DllCall("gdi32.dll", "bool", "DeleteObject", "handle", $aBr[0])

	Local $tS = DllStructCreate("long;long")
	DllCall("gdi32.dll", "bool", "GetTextExtentPoint32W", "handle", $hDC, "wstr", "Ag", "int", 2, "struct*", $tS)
	Local $iLH = DllStructGetData($tS, 2)
	Local $aOld = DllCall("gdi32.dll", "int", "SetBkMode", "handle", $hDC, "int", 1) ; TRANSPARENT
	Local $aOldC = DllCall("gdi32.dll", "int", "GetTextColor", "handle", $hDC)
	Local $iPad = ($iSub = 4) ? 12 : 8
	If $sLine2 = "" Then
		_DrawLine($hDC, $iL + $iPad, $iT, $iRt - 4, $iB, $sLine1, $iTx1)
	Else
		Local $iY = $iT + Int((($iB - $iT) - (2 * $iLH + 2)) / 2)
		_DrawLine($hDC, $iL + $iPad, $iY, $iRt - 4, $iY + $iLH, $sLine1, $iTx1)
		_DrawLine($hDC, $iL + $iPad, $iY + $iLH + 2, $iRt - 4, $iY + 2 * $iLH + 2, $sLine2, $iTx2)
	EndIf
	DllCall("gdi32.dll", "int", "SetTextColor", "handle", $hDC, "int", $aOldC[0])
	DllCall("gdi32.dll", "int", "SetBkMode", "handle", $hDC, "int", $aOld[0])
EndFunc

Func _OnNotify($hWnd, $iMsg, $wParam, $lParam)
	#forceref $hWnd, $iMsg, $wParam
	Local $tNMHDR = DllStructCreate($tagNMHDR, $lParam)
	If DllStructGetData($tNMHDR, "hWndFrom") <> GUICtrlGetHandle($idList) Then Return $GUI_RUNDEFMSG
	Local $iCode = DllStructGetData($tNMHDR, "Code")
	If $iCode = $NM_DBLCLK Then
		$g_bPlayReq = True
		Return $GUI_RUNDEFMSG
	EndIf
	If $iCode <> -12 Then Return $GUI_RUNDEFMSG ; -12 = NM_CUSTOMDRAW

	Local $tCD = DllStructCreate($XG_tagLVCD, $lParam)
	Switch DllStructGetData($tCD, "Stage")
		Case 0x1 ; CDDS_PREPAINT
			Return 0x20 ; CDRF_NOTIFYITEMDRAW
		Case 0x10001 ; CDDS_ITEMPREPAINT
			Return 0x20 ; CDRF_NOTIFYSUBITEMDRAW
		Case 0x30001 ; CDDS_ITEMPREPAINT | CDDS_SUBITEM
			Local $iSub = DllStructGetData($tCD, "SubItem")
			If $iSub <> 1 And $iSub <> 4 Then Return 0
			Local $iRow = DllStructGetData($tCD, "ItemSpec")
			If $iRow < 0 Or $iRow >= $g_aRowMap[0] Or $iRow + 1 >= UBound($g_aRowState) Or $iRow + 1 >= UBound($g_aRowName) Then Return 0
			If $iSub = 4 And $g_aRowState[$iRow + 1] = "" Then Return 0 ; no rating known: normal cell
			_DrawCell(DllStructGetData($tCD, "hdc"), $iRow, $iSub)
			Return 0x4 ; CDRF_SKIPDEFAULT - the cell was drawn here
	EndSwitch
	Return 0
EndFunc

; ===== Global config (settings editor) =====
; Columns: 0 = key, 1 = value, 2 = description, 3 = owning section
Global $aSpreadsheet[1][4]
$aSpreadsheet[0][0] = 0
$aSpreadsheet[0][1] = 0
$aSpreadsheet[0][2] = 0
Global $iSearchHit = 0, $sLastSearch = ""
Global $aControlHandles[1][3] ; 0 = tab "#id" or name box ID, 1 = value box ID, 2 = value box hwnd (combos)
$aControlHandles[0][0] = 0
$aControlHandles[0][1] = 0
$aControlHandles[0][2] = 0
Global $SearchInput = 0, $hSearchInput = 0
Global $DescBox
Global Const $sDescHint = "Point your mouse at an option to display a description in here."
Global Const $CFG_KEYBG = 0xEEF0F4, $CFG_HIT = 0xFFE08A ; setting-name box colour / search highlight colour
Global $g_idCfgStatus = 0

Func _ParseSettingFileIntoArray()
	Local $aLines = StringSplit(_ReadSettings(), @LF, 2)
	Local $iMax = UBound($aLines), $iRows = 0
	Local $sLine, $sSection = "", $aTemp

	ReDim $aSpreadsheet[$iMax + 1][4] ; preallocate once instead of _ArrayAdd per row

	For $n = 0 To $iMax - 1
		$sLine = $aLines[$n]
		If StringRight($sLine, 1) = @CR Then $sLine = StringTrimRight($sLine, 1)

		If StringLeft($sLine, 1) = "[" And StringRight($sLine, 1) = "]" Then ;=========Section Titles
			$sSection = StringTrimRight(StringTrimLeft($sLine, 1), 1)
			$iRows += 1
			$aSpreadsheet[$iRows][0] = $sSection
			$aSpreadsheet[$iRows][1] = "-"
			$aSpreadsheet[$iRows][2] = "-"
			$aSpreadsheet[$iRows][3] = $sSection
		EndIf

		If StringInStr($sLine, " = ") And StringInStr($sLine, "# ") Then ;==============Entries, Values, Explanations
			$aTemp = StringRegExp($sLine, "^(.*) = (\S*)\s*# (.*)$", 1)
			If Not @error Then
				$iRows += 1
				$aSpreadsheet[$iRows][0] = $aTemp[0]
				$aSpreadsheet[$iRows][1] = $aTemp[1]
				$aSpreadsheet[$iRows][2] = $aTemp[2]
				$aSpreadsheet[$iRows][3] = $sSection
			EndIf
		EndIf

		If StringInStr($sLine, "#") Then ;==============================================Additional Explanations
			$aTemp = StringRegExp($sLine, "^\s*# (.*)$", 1)
			If Not @error And $iRows > 0 Then
				If $aSpreadsheet[$iRows][2] <> "-" Then $aSpreadsheet[$iRows][2] &= " " & $aTemp[0]
			EndIf
		EndIf
	Next

	ReDim $aSpreadsheet[$iRows + 1][4]
EndFunc   ;==>_ParseSettingFileIntoArray


; Opens the settings editor as a modal window on top of the main window
Func _GlobalConfig()
	If Not FileExists(@ScriptDir & "\xenia-canary.config.toml") Then
		_Status("Global Config: xenia-canary.config.toml was not found. Run Xenia once so it creates the file, then try again.", $XG_ERR)
		Return
	EndIf

	; start from a clean state every time the editor opens
	ReDim $aSpreadsheet[1][4]
	$aSpreadsheet[0][0] = 0
	ReDim $aControlHandles[1][3]
	$iSearchHit = 0
	$sLastSearch = ""
	_ParseSettingFileIntoArray()
	If UBound($aSpreadsheet) < 2 Or $aSpreadsheet[1][2] <> "-" Then
		_Status("Global Config: no settings could be read from xenia-canary.config.toml.", $XG_ERR)
		Return
	EndIf

	Local $XeniaSettingsEditor, $NextButton, $SaveButton, $LoadLabel, $TabView, $nMsg, $sSearch
	GUISetState(@SW_DISABLE, $hGUI)
	$XeniaSettingsEditor = GUICreate("Xenia Global Settings", 1240, 776, -1, -1, -1, -1, $hGUI)
	GUISetFont(9, 400, 0, "Segoe UI")
	GUISetBkColor(0xF4F5F7)
	_CenterOnParent($XeniaSettingsEditor, $hGUI)

	; header band (same look as the main window); pieces leave the search area free
	GUICtrlCreateLabel("", 0, 0, 830, 64)
	GUICtrlSetBkColor(-1, 0xFFFFFF)
	GUICtrlCreateLabel("", 830, 0, 410, 19)
	GUICtrlSetBkColor(-1, 0xFFFFFF)
	GUICtrlCreateLabel("", 830, 45, 410, 19)
	GUICtrlSetBkColor(-1, 0xFFFFFF)
	GUICtrlCreateLabel("", 1220, 19, 20, 26)
	GUICtrlSetBkColor(-1, 0xFFFFFF)
	Local $idTitle = GUICtrlCreateLabel("Xenia Global Settings", 20, 8, 500, 30)
	GUICtrlSetFont($idTitle, 17, 600, 0, "Segoe UI")
	GUICtrlSetBkColor($idTitle, $GUI_BKCOLOR_TRANSPARENT)
	Local $idSub = GUICtrlCreateLabel("Editing xenia-canary.config.toml - hover a setting for its description", 20, 40, 660, 18)
	GUICtrlSetColor($idSub, 0x707070)
	GUICtrlSetBkColor($idSub, $GUI_BKCOLOR_TRANSPARENT)
	$SearchInput = GUICtrlCreateInput("", 830, 19, 290, 26)
	GUICtrlSetFont($SearchInput, 10, 400, 0, "Segoe UI")
	_GUICtrlEdit_SetCueBanner(GUICtrlGetHandle($SearchInput), "Search setting names...", True)
	DllCall("user32.dll", "bool", "SetWindowPos", "hwnd", GUICtrlGetHandle($SearchInput), "hwnd", 0, "int", 0, "int", 0, "int", 0, "int", 0, "uint", 0x13)
	$NextButton = GUICtrlCreateButton("Next", 1128, 19, 92, 26)
	$hSearchInput = GUICtrlGetHandle($SearchInput)
	GUICtrlCreateLabel("", 0, 64, 1240, 1)
	GUICtrlSetBkColor(-1, 0xD8D8D8)

	; description panel + footer
	$DescBox = GUICtrlCreateEdit($sDescHint, 20, 596, 1200, 130, BitOR($ES_READONLY, $ES_AUTOVSCROLL))
	GUICtrlSetBkColor($DescBox, 0xFFFFFF)
	GUICtrlSetColor($DescBox, 0x404040)
	$g_idCfgStatus = GUICtrlCreateLabel("", 20, 744, 1070, 20)
	GUICtrlSetColor($g_idCfgStatus, $XG_INFO)
	$SaveButton = GUICtrlCreateButton("Save Settings", 1100, 736, 120, 30)
	$LoadLabel = GUICtrlCreateLabel("Loading...", 20, 300, 1200, 50, 1) ; 1 = $SS_CENTER
	GUICtrlSetFont(-1, 28, 300, 0, "Segoe UI")
	GUICtrlSetColor(-1, 0x909090)
	GUICtrlSetBkColor(-1, $GUI_BKCOLOR_TRANSPARENT)
	GUISetState(@SW_SHOW)
	$TabView = GUICtrlCreateTab(20, 76, 1200, 510)
	GUICtrlSetState($TabView, $GUI_HIDE)

	ReDim $aControlHandles[UBound($aSpreadsheet)][3] ; preallocate once

	Local $Line = 0, $Column = 0
	Local $sVal, $sQ, $sList, $aOpts

	For $n = 1 To UBound($aSpreadsheet) - 1
		If $aSpreadsheet[$n][2] = "-" Then
			$aControlHandles[$n][0] = "#" & GUICtrlCreateTabItem($aSpreadsheet[$n][0])
			$Line = 0
			$Column = 0
		Else
			$aControlHandles[$n][0] = GUICtrlCreateInput($aSpreadsheet[$n][0], 32 + $Column * 400, 112 + $Line * 23, 185, 21, BitOR($GUI_SS_DEFAULT_INPUT, $ES_RIGHT, $ES_READONLY))
			GUICtrlSetBkColor(-1, $CFG_KEYBG)
			GUICtrlSetColor(-1, 0x303030)

			If $aSpreadsheet[$n][1] = "true" Or $aSpreadsheet[$n][1] = "false" Then
				$aControlHandles[$n][1] = GUICtrlCreateCombo($aSpreadsheet[$n][1], 222 + $Column * 400, 112 + $Line * 23, 175, 21, $CBS_DROPDOWNLIST)
				GUICtrlSetData(-1, ($aSpreadsheet[$n][1] = "true" ? "false" : "true"))
			Else
				$aOpts = _ParseOptions($aSpreadsheet[$n][2])
				If IsArray($aOpts) Then
					$sVal = $aSpreadsheet[$n][1]
					$sQ = (StringLeft($sVal, 1) = '"') ? '"' : ''
					$sList = ""
					For $o = 1 To $aOpts[0]
						$sList &= $sQ & $aOpts[$o] & $sQ & "|"
					Next
					If $sVal <> "" And Not StringInStr("|" & $sList, "|" & $sVal & "|") Then $sList &= $sVal & "|"
					$aControlHandles[$n][1] = GUICtrlCreateCombo("", 222 + $Column * 400, 112 + $Line * 23, 175, 21, $CBS_DROPDOWN)
					GUICtrlSetData(-1, StringTrimRight($sList, 1), $sVal)
					$aControlHandles[$n][2] = GUICtrlGetHandle($aControlHandles[$n][1]) ; used for hover lookup
				Else
					$aControlHandles[$n][1] = GUICtrlCreateInput($aSpreadsheet[$n][1], 222 + $Column * 400, 112 + $Line * 23, 175, 21)
				EndIf
			EndIf

			$Line += 1
			If $Line >= 20 Then
				$Column += 1
				$Line = 0
			EndIf
		EndIf
	Next

	GUICtrlCreateTabItem("")
	GUICtrlCreateGroup("", -99, -99, 1, 1)
	GUICtrlSetState($LoadLabel, $GUI_HIDE)
	GUICtrlSetState(StringTrimLeft($aControlHandles[1][0], 1), $GUI_SHOW)
	GUICtrlSetState($TabView, $GUI_SHOW)

	Local $NXR = 0, $OXR, $hProcTimer = 0
	Local $iHoverID = 0, $iNewHover, $iRow, $aCursor, $iComboID
	Local $bEnterWasDown = False, $iSaved = 0

	While 1
		; Poll for Xenia about once per second instead of every loop
		If $hProcTimer = 0 Or TimerDiff($hProcTimer) >= 1000 Then
			$hProcTimer = TimerInit()
			$OXR = $NXR
			$NXR = _XeniaRunning()
			If $NXR <> $OXR Then
				If $NXR Then
					GUICtrlSetState($SaveButton, $GUI_DISABLE)
					GUICtrlSetData($SaveButton, "Xenia Running!")
					_CfgStatus("Xenia is running - close it to save changes.", $XG_WARN)
				Else
					GUICtrlSetState($SaveButton, $GUI_ENABLE)
					GUICtrlSetData($SaveButton, "Save Settings")
					_CfgStatus("", $XG_INFO)
				EndIf
			EndIf
		EndIf

		; Show the description of the setting under the mouse
		$aCursor = GUIGetCursorInfo($XeniaSettingsEditor)
		$iNewHover = IsArray($aCursor) ? $aCursor[4] : 0 ; mouse outside the window counts as "nothing"
		If IsArray($aCursor) Then ; the edit part of an editable combo is a child window with no ID of its own
			$iComboID = _ComboIDUnderMouse($XeniaSettingsEditor)
			If $iComboID Then $iNewHover = $iComboID
		EndIf
		If $iNewHover <> $iHoverID Then
			$iHoverID = $iNewHover
			If $iHoverID <> $DescBox Then ; leave the text alone while the mouse is over the box itself
				$iRow = _FindRowByControl($iHoverID)
				If $iRow Then
					GUICtrlSetData($DescBox, $aSpreadsheet[$iRow][2])
				Else
					GUICtrlSetData($DescBox, $sDescHint)
				EndIf
			EndIf
		EndIf

		$sSearch = GUICtrlRead($SearchInput)
		If $sSearch <> $sLastSearch Then
			$sLastSearch = $sSearch
			_Search($sSearch, 1)
		EndIf

		; Debounced Enter key advance when search input has focus
		Local $bEnterDown = _IsPressed("0D")
		If _FocusOn($hSearchInput) And $bEnterDown And Not $bEnterWasDown Then
			_Search($sLastSearch, $iSearchHit + 1)
		EndIf
		$bEnterWasDown = $bEnterDown

		$nMsg = GUIGetMsg()
		Switch $nMsg
			Case $GUI_EVENT_CLOSE
				ExitLoop
			Case $NextButton
				_Search($sLastSearch, $iSearchHit + 1)
			Case $SaveButton
				$iSaved = _CfgSave()
				If $iSaved < 0 Then
					_CfgStatus("Could not write xenia-canary.config.toml. Is the file read-only?", $XG_ERR)
				ElseIf $iSaved > 0 Then
					_CfgStatus("Saved " & $iSaved & " changed setting" & (($iSaved = 1) ? "" : "s") & " to xenia-canary.config.toml.", $XG_OK)
				Else
					_CfgStatus("Nothing to save - no setting was changed.", $XG_INFO)
				EndIf
		EndSwitch
		Sleep(10)
	WEnd

	GUISetState(@SW_ENABLE, $hGUI)
	GUIDelete($XeniaSettingsEditor)
	GUISwitch($hGUI)
EndFunc   ;==>_GlobalConfig


; Footer status line of the settings editor
Func _CfgStatus($sText, $iColor = $XG_INFO)
	GUICtrlSetColor($g_idCfgStatus, $iColor)
	GUICtrlSetData($g_idCfgStatus, $sText)
EndFunc   ;==>_CfgStatus


; Maps a control ID (name box or value box) back to its row in $aSpreadsheet; 0 if none.
Func _FindRowByControl($iID)
	If $iID <= 0 Then Return 0
	For $n = 1 To UBound($aControlHandles) - 1
		If $aControlHandles[$n][0] = $iID Or $aControlHandles[$n][1] = $iID Then Return $n
	Next
	Return 0
EndFunc   ;==>_FindRowByControl


; Writes only the values that were changed in the GUI, in a single pass over the file.
Func _CfgSave()
	Local $oChanged = ObjCreate("Scripting.Dictionary")
	Local $sNew, $aNewVals[UBound($aSpreadsheet)]

	For $n = 1 To UBound($aSpreadsheet) - 1
		If StringLeft($aControlHandles[$n][0], 1) = "#" Then ContinueLoop
		$sNew = GUICtrlRead($aControlHandles[$n][1])
		If $sNew = "" Then ContinueLoop ; an empty value would make the config file invalid
		If Not ($sNew == $aSpreadsheet[$n][1]) Then
			$oChanged.Item($aSpreadsheet[$n][3] & "|" & $aSpreadsheet[$n][0]) = $sNew
			$aNewVals[$n] = $sNew
		EndIf
	Next
	If $oChanged.Count = 0 Then Return 0

	Local $aLines = StringSplit(_ReadSettings(), @LF, 2) ; re-read: file may have changed on disk
	Local $sSection = "", $sLine, $sKey, $aTemp, $bDirty = False

	For $i = 0 To UBound($aLines) - 1
		$sLine = StringStripCR($aLines[$i])
		If StringLeft($sLine, 1) = "[" And StringRight($sLine, 1) = "]" Then
			$sSection = StringTrimRight(StringTrimLeft($sLine, 1), 1)
		ElseIf StringInStr($sLine, " = ") And StringInStr($sLine, "# ") Then
			$aTemp = StringRegExp($aLines[$i], "^(.*) = \S*(\s*# .*)$", 1) ; raw line keeps its own CR
			If Not @error Then
				$sKey = $sSection & "|" & $aTemp[0]
				If $oChanged.Exists($sKey) Then
					$aLines[$i] = $aTemp[0] & " = " & $oChanged.Item($sKey) & $aTemp[1]
					$bDirty = True
				EndIf
			EndIf
		EndIf
	Next

	If Not $bDirty Then Return 0
	If Not _WriteSettings(_ArrayToString($aLines, @LF)) Then Return -1 ; nothing is remembered as saved, so Save can be retried
	For $n = 1 To UBound($aNewVals) - 1
		If $aNewVals[$n] <> "" Then $aSpreadsheet[$n][1] = $aNewVals[$n]
	Next
	Return $oChanged.Count
EndFunc   ;==>_CfgSave


Func _ParseOptions($sDesc)
	If Not StringInStr($sDesc, "[") Then Return 0
	Local $a = StringRegExp($sDesc, "\[([^\[\]]+,[^\[\]]+)\]", 1)
	If @error Then Return 0
	Local $aItems = StringSplit($a[0], ",", 2)
	Local $aOut[UBound($aItems) + 1], $c = 0, $sItem
	For $i = 0 To UBound($aItems) - 1
		$sItem = StringRegExpReplace($aItems[$i], "\s*=.*$", "") ; "0=error" -> "0"
		$sItem = StringStripWS(StringReplace($sItem, '"', ""), 3)
		If $sItem <> "" Then
			$c += 1
			$aOut[$c] = $sItem
		EndIf
	Next
	If $c < 2 Then Return 0
	$aOut[0] = $c
	Return $aOut
EndFunc   ;==>_ParseOptions

; Removes spaces and underscores so "render target path" matches "render_target_path_d3d12".
Func _NormalizeForSearch($s)
	Return StringReplace(StringReplace($s, "_", ""), " ", "")
EndFunc   ;==>_NormalizeForSearch

; Searches key names only (case-insensitive, matches anywhere inside the key, ignores spaces and underscores).
Func _Search($sText, $iStart)
	Local $n
	Local $bHadFocus = _FocusOn($hSearchInput)
	If $iSearchHit Then GUICtrlSetBkColor($aControlHandles[$iSearchHit][0], $CFG_KEYBG)
	$iSearchHit = 0
	Local $sNeedle = _NormalizeForSearch($sText)
	If $sNeedle = "" Then Return
	Local $iCount = UBound($aSpreadsheet) - 1
	For $i = 0 To $iCount - 1
		$n = Mod($iStart - 1 + $i, $iCount) + 1
		If $aSpreadsheet[$n][2] = "-" Then ContinueLoop
		If StringInStr(_NormalizeForSearch($aSpreadsheet[$n][0]), $sNeedle) Then
			For $t = $n To 1 Step -1 ; switch to the owning tab
				If StringLeft($aControlHandles[$t][0], 1) = "#" Then
					GUICtrlSetState(StringTrimLeft($aControlHandles[$t][0], 1), $GUI_SHOW)
					ExitLoop
				EndIf
			Next
			If $bHadFocus And Not _FocusOn($hSearchInput) Then ; switching tabs can steal focus; give it back
				GUICtrlSetState($SearchInput, $GUI_FOCUS)
				GUICtrlSendMsg($SearchInput, $EM_SETSEL, StringLen($sText), StringLen($sText)) ; caret at end, nothing selected
			EndIf
			GUICtrlSetBkColor($aControlHandles[$n][0], $CFG_HIT)
			GUICtrlSetData($DescBox, $aSpreadsheet[$n][2])
			$iSearchHit = $n
			Return
		EndIf
	Next
EndFunc   ;==>_Search

; True if the focused window is $h1 or $h2.
Func _FocusOn($h1, $h2 = 0)
	Local $a = DllCall("user32.dll", "hwnd", "GetFocus")
	If @error Or Not IsArray($a) Or Not $a[0] Then Return False
	If $a[0] = $h1 Then Return True
	If $h2 <> 0 And $a[0] = $h2 Then Return True
	Return False
EndFunc   ;==>_FocusOn

; GUIGetCursorInfo reports ID 0 over the edit part of an editable combo. Finds the owning combo's control ID
; from the window under the cursor instead; returns 0 when the mouse is not over such an edit.
Func _ComboIDUnderMouse($hWin)
	Static $hLastParent = 0, $iLastID = 0
	Local $tPt = DllStructCreate("long x;long y")
	DllCall("user32.dll", "bool", "GetCursorPos", "struct*", $tPt)
	Local $aWnd = DllCall("user32.dll", "hwnd", "WindowFromPoint", "struct", $tPt)
	If @error Or Not IsArray($aWnd) Or Not $aWnd[0] Then Return 0
	Local $aPar = DllCall("user32.dll", "hwnd", "GetParent", "hwnd", $aWnd[0])
	If @error Or Not IsArray($aPar) Or Not $aPar[0] Or $aPar[0] = $hWin Then Return 0
	If $aPar[0] <> $hLastParent Then ; only rescan when the window under the mouse changes
		$hLastParent = $aPar[0]
		$iLastID = 0
		For $n = 1 To UBound($aControlHandles) - 1
			If $aControlHandles[$n][2] <> 0 And $aControlHandles[$n][2] = $aPar[0] Then
				$iLastID = $aControlHandles[$n][1]
				ExitLoop
			EndIf
		Next
	EndIf
	Return $iLastID
EndFunc   ;==>_ComboIDUnderMouse

Func _ReadSettings()
	Local $hFile = FileOpen(@ScriptDir & "\xenia-canary.config.toml", BitOR($FO_READ, $FO_UTF8_NOBOM))
	If $hFile = -1 Then Return ""
	Local $sBuffer = FileRead($hFile)
	FileClose($hFile)
	Return $sBuffer
EndFunc   ;==>_ReadSettings

; Writes through a temporary file, so a failed write can never leave a half-written config behind
Func _WriteSettings($sBuffer)
	Local $sFile = @ScriptDir & "\xenia-canary.config.toml", $sTmp = $sFile & ".tmp"
	Local $hFile = FileOpen($sTmp, BitOR($FO_OVERWRITE, $FO_UTF8_NOBOM))
	If $hFile = -1 Then Return False
	Local $bOk = FileWrite($hFile, $sBuffer)
	FileClose($hFile)
	If Not $bOk Or Not FileMove($sTmp, $sFile, $FC_OVERWRITE) Then
		FileDelete($sTmp)
		Return False
	EndIf
	Return True
EndFunc   ;==>_WriteSettings

Func _XeniaRunning()
	If ProcessExists("xenia.exe") Or ProcessExists("xenia_canary.exe") Then
		Return 1
	Else
		Return 0
	EndIf
EndFunc   ;==>_XeniaRunning

; ===== Updates window =====
Global $g_hUpd = 0, $g_idUpdProg = 0, $g_idUpdStatus = 0, $g_idUpdClose = 0, $g_bUpdQuit = False
Global $g_aUpdInfo[3], $g_aUpdAge[3]
Global Const $g_sUrlCompat = "https://github.com/xenia-canary/game-compatibility/releases/download/game-compatibility/compatibility_data.json"
Global Const $g_sUrlPatches = "https://codeload.github.com/xenia-canary/game-patches/zip/refs/heads/main"
Global Const $g_sUrlCanary = "https://github.com/xenia-canary/xenia-canary-releases/releases/latest/download/"

Func _Stamp()
	Return @YEAR & "-" & @MON & "-" & @MDAY & " " & @HOUR & ":" & @MIN
EndFunc

Func _UpdSetStatus($sText)
	GUICtrlSetData($g_idUpdStatus, $sText)
EndFunc

; Whole days since a "YYYY-MM-DD[ HH:MM]" stamp, or -1 if it can't be read.
Func _DaysSince($sStamp)
	If Not StringRegExp($sStamp, "^\d{4}-\d{2}-\d{2}") Then Return -1
	Local $sD = StringReplace(StringLeft($sStamp, 10), "-", "/") & " 00:00:00"
	Local $iDays = _DateDiff("D", $sD, _NowCalc())
	If @error Or $iDays < 0 Then Return -1
	Return $iDays
EndFunc

Func _AgeText($iDays, $sPrefix, $sSuffix)
	If $iDays = 0 Then Return $sPrefix & " today"
	If $iDays = 1 Then Return $sPrefix & " 1 day " & $sSuffix
	Return $sPrefix & " " & $iDays & " days " & $sSuffix
EndFunc

Func _UpdSetAge($i, $iDays, $sText)
	GUICtrlSetData($g_aUpdAge[$i], $sText)
	Local $iCol = $XG_OK
	If $iDays < 0 Then
		$iCol = $XG_INFO
	ElseIf $iDays > 30 Then
		$iCol = $XG_WARN
	EndIf
	GUICtrlSetColor($g_aUpdAge[$i], $iCol)
EndFunc

Func _UpdRefreshInfo()
	GUICtrlSetData($g_aUpdInfo[0], "Ratings and official game names.")
	GUICtrlSetData($g_aUpdInfo[1], "Installs the newest patch files. Your choices are kept.")
	GUICtrlSetData($g_aUpdInfo[2], "Replaces xenia_canary.exe. The old one is backed up.")
	Local $iD
	$iD = _DaysSince(IniRead($sIni, "Updates", "Compat", ""))
	_UpdSetAge(0, $iD, ($iD < 0) ? "Never updated" : _AgeText($iD, "Updated", "ago"))
	$iD = _DaysSince(IniRead($sIni, "Updates", "Patches", ""))
	_UpdSetAge(1, $iD, ($iD < 0) ? "Never updated" : _AgeText($iD, "Updated", "ago"))
	$iD = _DaysSince(IniRead($sIni, "Updates", "Canary", ""))
	If $iD < 0 And Not FileExists($g_Xenia) Then
		_UpdSetAge(2, -1, "xenia_canary.exe not found")
	Else
		_UpdSetAge(2, $iD, ($iD < 0) ? "Never updated" : _AgeText($iD, "Updated", "ago"))
	EndIf
EndFunc

; Downloads the first working URL in $aUrls to $sDest (via a .part file). False on failure or if the window is closed.
Func _DownloadFile($aUrls, $sDest)
	Local $sPart = $sDest & ".part"
	Local $h, $m, $iRead, $iSize
	For $u = 0 To UBound($aUrls) - 1
		FileDelete($sPart)
		$h = InetGet($aUrls[$u], $sPart, $INET_FORCERELOAD, $INET_DOWNLOADBACKGROUND)
		If Not $h Then ContinueLoop ; could not even start: try the next address
		Do
			Sleep(40)
			$m = GUIGetMsg()
			If $m = $GUI_EVENT_CLOSE Or $m = $g_idUpdClose Then
				InetClose($h)
				FileDelete($sPart)
				$g_bUpdQuit = True
				Return False
			EndIf
			$iRead = InetGetInfo($h, $INET_DOWNLOADREAD)
			$iSize = InetGetInfo($h, $INET_DOWNLOADSIZE)
			If $iSize > 0 Then GUICtrlSetData($g_idUpdProg, Int($iRead * 100 / $iSize))
			_UpdSetStatus("Downloading... " & Round($iRead / 1048576, 1) & " MB")
		Until InetGetInfo($h, $INET_DOWNLOADCOMPLETE) Or @error
		Local $bOk = InetGetInfo($h, $INET_DOWNLOADSUCCESS)
		InetClose($h)
		If $bOk And FileGetSize($sPart) > 0 Then
			FileMove($sPart, $sDest, $FC_OVERWRITE)
			Return True
		EndIf
		FileDelete($sPart)
	Next
	Return False
EndFunc

; Extracts a zip. Windows' built-in tar is much faster than PowerShell's Expand-Archive, which stays as the fallback.
Func _Unzip($sZip, $sDest)
	DirRemove($sDest, 1)
	DirCreate($sDest)
	Local $iRet = RunWait('tar -xf "' & $sZip & '" -C "' & $sDest & '"', @ScriptDir, @SW_HIDE)
	If Not @error And $iRet = 0 Then Return True
	DirRemove($sDest, 1)
	DirCreate($sDest)
	$iRet = RunWait('powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -LiteralPath ''' & $sZip & ''' -DestinationPath ''' & $sDest & ''' -Force"', @ScriptDir, @SW_HIDE)
	Return (Not @error And $iRet = 0)
EndFunc

Func _FirstSubDir($sDir)
	Local $h = FileFindFirstFile($sDir & "\*")
	If $h = -1 Then Return ""
	Local $sName, $sFound = ""
	While 1
		$sName = FileFindNextFile($h)
		If @error Then ExitLoop
		If @extended Then
			$sFound = $sDir & "\" & $sName
			ExitLoop
		EndIf
	WEnd
	FileClose($h)
	Return $sFound
EndFunc

Func _UpdateCompat()
	_UpdSetStatus("Connecting...")
	Local $aUrl[1] = [$g_sUrlCompat]
	If Not _DownloadFile($aUrl, $g_CacheDir & "\compatibility_data.json") Then
		If Not $g_bUpdQuit Then _UpdSetStatus("Download failed. Check your connection.")
		Return False
	EndIf
	If Not _LoadCompat() Then
		_UpdSetStatus("The downloaded file could not be read.")
		Return False
	EndIf
	_FillList(GUICtrlRead($idSearch))
	_UpdSetStatus("Compatibility database updated (" & $g_oCompat.Count & " games).")
	IniWrite($sIni, "Updates", "Compat", _Stamp())
	Return True
EndFunc

Func _UpdatePatches()
	_UpdSetStatus("Connecting...")
	Local $sZip = $g_CacheDir & "\game-patches.zip"
	Local $aUrl[1] = [$g_sUrlPatches]
	If Not _DownloadFile($aUrl, $sZip) Then
		If Not $g_bUpdQuit Then _UpdSetStatus("Download failed. Check your connection.")
		Return False
	EndIf
	_UpdSetStatus("Extracting...")
	GUICtrlSetData($g_idUpdProg, 0)
	Local $sEx = $g_CacheDir & "\game-patches"
	If Not _Unzip($sZip, $sEx) Then
		_UpdSetStatus("Could not extract the download.")
		Return False
	EndIf
	Local $sSub = _FirstSubDir($sEx)
	Local $sSrc = $sSub & "\patches"
	If $sSub = "" Or Not FileExists($sSrc) Then
		_UpdSetStatus("No patch files found in the download.")
		Return False
	EndIf
	; one bulk copy over the whole patches folder, then only the games with saved choices are touched
	_UpdSetStatus("Installing patches...")
	DirCreate($sPatchesDir)
	If Not DirCopy($sSrc, $sPatchesDir, 1) Then
		_UpdSetStatus("Could not copy the patches into " & $sPatchesDir)
		Return False
	EndIf
	DirRemove($sEx, 1)
	_UpdSetStatus("Re-applying your patch choices...")
	Local $iFixed = _ReapplyAllPatchChoices()
	Local $aFiles = _FileListToArray($sPatchesDir, "*.patch.toml", 1)
	Local $iTotal = IsArray($aFiles) ? $aFiles[0] : 0
	_UpdSetStatus("Game patches updated (" & $iTotal & " files, " & $iFixed & " restored to your choices).")
	IniWrite($sIni, "Updates", "Patches", _Stamp())
	Return True
EndFunc

Func _UpdateCanary()
	If ProcessExists("xenia_canary.exe") Or ProcessExists($g_PID) Then
		_UpdSetStatus("Xenia is running. Close it first, then try again.")
		Return False
	EndIf
	_UpdSetStatus("Connecting...")
	Local $sZip = $g_CacheDir & "\xenia_canary_windows.zip"
	Local $aUrl[2] = [$g_sUrlCanary & "xenia_canary_windows_.zip", $g_sUrlCanary & "xenia_canary_windows.zip"]
	If Not _DownloadFile($aUrl, $sZip) Then
		If Not $g_bUpdQuit Then _UpdSetStatus("Download failed. Check your connection.")
		Return False
	EndIf
	_UpdSetStatus("Extracting...")
	GUICtrlSetData($g_idUpdProg, 0)
	Local $sEx = $g_CacheDir & "\xenia_canary"
	If Not _Unzip($sZip, $sEx) Or Not FileExists($sEx & "\xenia_canary.exe") Then
		_UpdSetStatus("Could not extract xenia_canary.exe from the download.")
		Return False
	EndIf
	Local $sBak = $g_CacheDir & "\xenia_canary.exe.bak"
	If FileExists($g_Xenia) Then FileCopy($g_Xenia, $sBak, $FC_OVERWRITE)
	If Not FileCopy($sEx & "\xenia_canary.exe", $g_Xenia, $FC_OVERWRITE) Then
		If FileExists($sBak) Then FileCopy($sBak, $g_Xenia, $FC_OVERWRITE)
		_UpdSetStatus("Could not replace xenia_canary.exe. The old one was restored.")
		Return False
	EndIf
	_UpdSetStatus("Xenia Canary updated. Previous exe saved in the Cache folder.")
	IniWrite($sIni, "Updates", "Canary", _Stamp())
	Return True
EndFunc

Func _Updates()
	Local $aTitles[3] = ["Compatibility database", "Game patches", "Xenia Canary"]
	Local $aBtn[3], $m, $bOk
	GUISetState(@SW_DISABLE, $hGUI)
	$g_hUpd = GUICreate("Updates", 560, 420, -1, -1, -1, -1, $hGUI)
	_CenterOnParent($g_hUpd, $hGUI)
	GUISetFont(9, 400, 0, "Segoe UI", $g_hUpd)
	GUISetBkColor(0xF4F5F7, $g_hUpd)

	; header band
	GUICtrlCreateLabel("", 0, 0, 560, 64)
	GUICtrlSetBkColor(-1, 0xFFFFFF)
	Local $idTitle = GUICtrlCreateLabel("Updates", 20, 10, 520, 28)
	GUICtrlSetFont($idTitle, 14, 600, 0, "Segoe UI")
	GUICtrlSetBkColor($idTitle, $GUI_BKCOLOR_TRANSPARENT)
	Local $idSub = GUICtrlCreateLabel("Downloads are saved to " & $g_CacheDir, 20, 40, 520, 18)
	GUICtrlSetColor($idSub, 0x707070)
	GUICtrlSetBkColor($idSub, $GUI_BKCOLOR_TRANSPARENT)
	GUICtrlCreateLabel("", 0, 64, 560, 1)
	GUICtrlSetBkColor(-1, 0xD8D8D8)

	Local $iY, $idCardTitle
	; each card is built from pieces that leave the button area free, so nothing can sit on top of the button
	For $i = 0 To 2
		$iY = 80 + $i * 84
		GUICtrlCreateLabel("", 20, $iY, 398, 74)
		GUICtrlSetBkColor(-1, 0xFFFFFF)
		GUICtrlCreateLabel("", 418, $iY, 122, 22)
		GUICtrlSetBkColor(-1, 0xFFFFFF)
		GUICtrlCreateLabel("", 418, $iY + 52, 122, 22)
		GUICtrlSetBkColor(-1, 0xFFFFFF)
		GUICtrlCreateLabel("", 524, $iY + 22, 16, 30)
		GUICtrlSetBkColor(-1, 0xFFFFFF)
	Next
	For $i = 0 To 2
		$iY = 80 + $i * 84
		$idCardTitle = GUICtrlCreateLabel($aTitles[$i], 36, $iY + 8, 360, 20)
		GUICtrlSetFont($idCardTitle, 10, 600, 0, "Segoe UI")
		GUICtrlSetBkColor($idCardTitle, $GUI_BKCOLOR_TRANSPARENT)
		$g_aUpdInfo[$i] = GUICtrlCreateLabel("", 36, $iY + 30, 360, 18)
		GUICtrlSetColor($g_aUpdInfo[$i], 0x707070)
		GUICtrlSetBkColor($g_aUpdInfo[$i], $GUI_BKCOLOR_TRANSPARENT)
		$g_aUpdAge[$i] = GUICtrlCreateLabel("", 36, $iY + 49, 360, 18)
		GUICtrlSetFont($g_aUpdAge[$i], 9, 600, 0, "Segoe UI")
		GUICtrlSetBkColor($g_aUpdAge[$i], $GUI_BKCOLOR_TRANSPARENT)
	Next
	For $i = 0 To 2
		$aBtn[$i] = GUICtrlCreateButton("Update", 418, 80 + $i * 84 + 22, 106, 30)
		DllCall("user32.dll", "bool", "SetWindowPos", "hwnd", GUICtrlGetHandle($aBtn[$i]), "hwnd", 0, "int", 0, "int", 0, "int", 0, "int", 0, "uint", 0x13) ; HWND_TOP
	Next

	; footer
	$g_idUpdProg = GUICtrlCreateProgress(20, 342, 520, 10)
	$g_idUpdStatus = GUICtrlCreateLabel("Ready.", 20, 364, 430, 36)
	GUICtrlSetColor($g_idUpdStatus, 0x707070)
	$g_idUpdClose = GUICtrlCreateButton("Close", 460, 362, 80, 30)
	_UpdRefreshInfo()
	GUISetState(@SW_SHOW, $g_hUpd)

	$g_bUpdQuit = False
	While Not $g_bUpdQuit
		$m = GUIGetMsg()
		Switch $m
			Case $GUI_EVENT_CLOSE, $g_idUpdClose
				ExitLoop
			Case $aBtn[0], $aBtn[1], $aBtn[2]
				For $i = 0 To 2
					GUICtrlSetState($aBtn[$i], $GUI_DISABLE)
				Next
				GUICtrlSetData($g_idUpdProg, 0)
				$bOk = False
				Switch $m
					Case $aBtn[0]
						$bOk = _UpdateCompat()
					Case $aBtn[1]
						$bOk = _UpdatePatches()
					Case $aBtn[2]
						$bOk = _UpdateCanary()
				EndSwitch
				If $bOk Then GUICtrlSetData($g_idUpdProg, 100)
				_UpdRefreshInfo()
				For $i = 0 To 2
					GUICtrlSetState($aBtn[$i], $GUI_ENABLE)
				Next
		EndSwitch
	WEnd

	GUISetState(@SW_ENABLE, $hGUI)
	GUIDelete($g_hUpd)
	GUISwitch($hGUI)
EndFunc

_LoadSettings()
_EnsureDirs()
_LoadCompat()
_BuildGUI()
_ScanGames()
_MigratePatchChoices()
Local $sLast = "", $sNow, $bRunning = True, $bNow ; $bRunning starts True so the first pass sets the Boot/Stop buttons
While 1
	Switch GUIGetMsg()
		Case $GUI_EVENT_CLOSE
			ExitLoop
		Case $idOpen
			Local $s = FileSelectFolder("Select parent folder for games", "", 0, $g_GameDir, $hGUI)
			If $s <> "" Then
				$g_GameDir = $s
				_SaveSettings()
				_ScanGames()
			EndIf
		Case $idRefresh
			FileDelete($g_PosterDir & "\*.none") ; retry posters that were missing
			$g_oQueued.RemoveAll()
			_ScanGames(False)
			If _IsPressed("10") Then ; Shift held: forget what is known and identify every game again
				_ReIdentifyAll()
			Else ; otherwise only new games (and earlier failures) are identified
				_FillList(GUICtrlRead($idSearch))
			EndIf
		Case $idPlay
			_Play()
		Case $idStop
			_Stop()
		Case $idConfig
			_GlobalConfig()
		Case $idUpdates
			_Updates()
		Case $idBootCustom
			_BootCustom()
		Case $idBootGlobal
			_BootGlobal()
		Case $idManagePatches
			_ManagePatches()
		Case $idCustomConfig
			_CustomConfig()
		Case $idShortcut
			_CreateShortcut()
	EndSwitch
	If $g_bPlayReq Then
		$g_bPlayReq = False
		_Play()
	EndIf
	$sNow = GUICtrlRead($idSearch)
	If $sNow <> $sLast Then
		$sLast = $sNow
		_FillList($sNow)
	EndIf
	_PosterTick()
	_StatusTick()
	$bNow = (ProcessExists($g_PID) <> 0)
	If $bNow <> $bRunning Then
		$bRunning = $bNow
		GUICtrlSetState($idPlay, $bRunning ? $GUI_DISABLE : $GUI_ENABLE)
		GUICtrlSetState($idStop, $bRunning ? $GUI_ENABLE : $GUI_DISABLE)
	EndIf
WEnd
