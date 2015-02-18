--	LibAddonMenu-2.0 & its files © Ryan Lakanen (Seerah)		--
--	Distributed under The Artistic License 2.0 (see LICENSE)	--
------------------------------------------------------------------


--Register LAM with LibStub
local MAJOR, MINOR = "LibAddonMenu-2.0", VERSION_NUMBER
local lam, oldminor = LibStub:NewLibrary(MAJOR, MINOR)
if not lam then return end	--the same or newer version of this lib is already loaded into memory


--UPVALUES--
local wm = WINDOW_MANAGER
local cm = CALLBACK_MANAGER
local tconcat = table.concat
local tinsert = table.insert

local addonsForList = {}
local addonToOptionsMap = {}
local optionsCreated = {}
lam.widgets = lam.widgets or {}
local widgets = lam.widgets

local ADDON_DATA_TYPE = 1
local RESELECTING_DURING_REBUILD = true
local USER_REQUESTED_OPEN = true


--INTERNAL FUNCTION
--splits the text contained in `searchEdit` into whitespace-separated
--terms (words if you will, but they may actually be search patterns)
--	if there is at least one term, returns a filter function
--	otherwise returns nil
--filter function takes a `data` table argument, and returns true
--	iff `data.filterText` (which must be a string) matches every term
local function GetSearchFilterFunc(searchEdit)
	local searchText = searchEdit:GetText()
	local strfind = string.find

	if not strfind(searchText, "%S") then -- nothing but whitespace
		return nil
	end

	local searchTerms = {}
	local numTerms = 0

	for t in searchText:lower():gmatch("%S+") do -- split "words"
		numTerms = numTerms + 1
		searchTerms[numTerms] = t
	end

	return function(data)
		local filterText = data.filterText
		for i = 1, numTerms do
			if not strfind(filterText, searchTerms[i]) then
				return false
			end
		end
		return true
	end
end


--INTERNAL FUNCTION
--populates `addonList` with entries from `addonsForList`
--	addonList = ZO_ScrollList control
--	filter = [optional] function(data)
local function PopulateAddonList(addonList, filter)
	local entryList = ZO_ScrollList_GetDataList(addonList)
	local selectedData = nil

	ZO_ScrollList_Clear(addonList)

	for i, data in ipairs(addonsForList) do
		if not filter or filter(data) then
			tinsert(entryList, ZO_ScrollList_CreateDataEntry(ADDON_DATA_TYPE, data))
			-- select the first panel passing the filter, or the currently
			-- shown panel, but only if it passes the filter as well
			if selectedData == nil or data.panel == lam.currentAddonPanel then
				selectedData = data
			end
		end
	end

	ZO_ScrollList_Commit(addonList)

	if selectedData then
		if selectedData.panel == lam.currentAddonPanel then
			ZO_ScrollList_SelectData(addonList, selectedData, nil, RESELECTING_DURING_REBUILD)
		else
			ZO_ScrollList_SelectData(addonList, selectedData, nil)
		end
	end

	if addonList.selectedDataIndex then
		ZO_ScrollList_ScrollDataIntoView(addonList, addonList.selectedDataIndex)
	end
end


--METHOD: REGISTER WIDGET--
--each widget has its version checked before loading,
--so we only have the most recent one in memory
--Usage:
--	widgetType = "string"; the type of widget being registered
--	widgetVersion = integer; the widget's version number
LAMCreateControl = LAMCreateControl or {}
local lamcc = LAMCreateControl

function lam:RegisterWidget(widgetType, widgetVersion)
	if widgets[widgetType] and widgets[widgetType] >= widgetVersion then
		return false
	else
		widgets[widgetType] = widgetVersion
		return true
	end
end


--METHOD: OPEN TO ADDON PANEL--
--opens to a specific addon's option panel
--Usage:
--	panel = userdata; the panel returned by the :RegisterOptionsPanel method
local locSettings = GetString(SI_GAME_MENU_SETTINGS)
function lam:OpenToPanel(panel)

	local function openMenuAndSelectAddon()
		local gameMenu = ZO_GameMenu_InGame.gameMenu
		local settingsMenu = gameMenu.headerControls[locSettings]

		if settingsMenu then -- an instance of ZO_TreeNode
			local children = settingsMenu:GetChildren()
			for i = 1, (children and #children or 0) do
				local childNode = children[i]
				local data = childNode:GetData()
				if data and data.id == lam.panelId then
					-- found LAM "Addon Settings" node, yay!
					childNode:GetTree():SelectNode(childNode)
					break
				end
			end
		end

		local addonList = lam.addonList
		local selectedData = nil

		for _, addonData in ipairs(addonsForList) do
			if addonData.panel == panel then
				selectedData = addonData
				break
			end
		end

		ZO_ScrollList_SelectData(addonList, selectedData, nil)
		-- if the requested addon doesn't pass search filter, it
		-- won't appear in the list and thus can't be scrolled to,
		-- but its panel will still be shown

		if addonList.selectedDataIndex then
			ZO_ScrollList_ScrollDataIntoView(addonList, addonList.selectedDataIndex)
		end
	end

	if SCENE_MANAGER:GetScene("gameMenuInGame"):GetState() == SCENE_SHOWN then
		openMenuAndSelectAddon()
	else
		SCENE_MANAGER:CallWhen("gameMenuInGame", SCENE_SHOWN, openMenuAndSelectAddon)
		SCENE_MANAGER:Show("gameMenuInGame")
	end
end


--INTERNAL FUNCTION
--creates a simpe row control to hold two half-width widgets;
--the control will kidnap the twins and auto-resize itself, so that
--other controls anchored to its bottom are always below both twins,
--even if they're not the same height
local function CreateTwinOptionsRow(parent, leftWidget, rightWidget)
	local rowParent = parent.scroll or parent
	local panel = parent.panel or parent
	local index = (panel.twinrowCounter or 0) + 1
	panel.twinrowCounter = index
	local row = wm:CreateControl("$(parent)TwinRow" .. index, rowParent, CT_CONTROL)
	row:SetWidth(rowParent:GetWidth())
	row:SetResizeToFitDescendents(true) -- mainly for height
	-- copy anchor from the left widget to the row,
	-- and then anchor the left widget to the row
	row:SetAnchor(select(2, leftWidget:GetAnchor(0)))
	leftWidget:ClearAnchors()
	leftWidget:SetAnchor(TOPLEFT, row, TOPLEFT)
	-- "kidnap the twins"
	leftWidget:SetParent(row)
	rightWidget:SetParent(row)
	-- not sure these are required
	row.data = {type = "twinrow"} -- hope this cheat doesn't break anything
	row.panel = panel
	return row
end


--INTERNAL FUNCTION
--creates controls when options panel is first shown
--controls anchoring of these controls in the panel
local function CreateOptionsControlsRecursively(parent, optionsTable, maxDepth)
	if not optionsTable or maxDepth < 0 then
		return
	end

	local lastAddedControl, lacAtHalfRow

	for optionIndex = 1, #optionsTable do
		local widgetData = optionsTable[optionIndex]
		local widgetType = widgetData.type
		local widget = lamcc[widgetType](parent, widgetData)
		local isHalf = false

		if widgetType == "submenu" then
			CreateOptionsControlsRecursively(widget, widgetData.controls, maxDepth - 1)
		else
			isHalf = (widgetData.width == "half")
		end

		if lastAddedControl then
			if lacAtHalfRow and isHalf then
				widget:SetAnchor(TOPLEFT, lastAddedControl, TOPRIGHT, 10, 0)
				lacAtHalfRow = false
				lastAddedControl = CreateTwinOptionsRow(parent, lastAddedControl, widget)
			else
				widget:SetAnchor(TOPLEFT, lastAddedControl, BOTTOMLEFT, 0, 15)
				lacAtHalfRow = isHalf
				lastAddedControl = widget
			end
		else
			widget:SetAnchor(TOPLEFT)
			lacAtHalfRow = isHalf
			lastAddedControl = widget
		end
	end
end


--INTERNAL FUNCTION
--handles switching between panels
local function ToggleAddonPanels(panel)	--called in OnShow of newly shown panel
	local currentlySelected = lam.currentAddonPanel
	if currentlySelected and currentlySelected ~= panel then
		currentlySelected:SetHidden(true)
	end
	lam.currentAddonPanel = panel

	-- refresh visible rows to reflect panel IsHidden status
	ZO_ScrollList_RefreshVisible(lam.addonList)

	local addonID = panel:GetName()
	if not optionsCreated[addonID] then
		--if this is the first time opening this panel, create these options
		local optionsTable = addonToOptionsMap[addonID]

		CreateOptionsControlsRecursively(panel, optionsTable, 1)

		optionsCreated[addonID] = true
		cm:FireCallbacks("LAM-PanelControlsCreated", panel)
	end

	cm:FireCallbacks("LAM-RefreshPanel", panel)
end


--METHOD: REGISTER ADDON PANEL
--registers your addon with LibAddonMenu and creates a panel
--Usage:
--	addonID = "string"; unique ID which will be the global name of your panel
--	panelData = table; data object for your panel - see controls\panel.lua
function lam:RegisterAddonPanel(addonID, panelData)
	local container = lam:GetAddonPanelContainer()
	local panel = lamcc.panel(container, panelData, addonID)	--addonID==global name of panel
	panel:SetHidden(true)
	panel:SetAnchorFill(container)
	panel:SetHandler("OnShow", ToggleAddonPanels)

	local function stripMarkup(str)
		return str:gsub("|[Cc]%x%x%x%x%x%x", ""):gsub("|[Rr]", "")
	end

	local filterParts = {panelData.name, nil, nil}
	-- append keywords and author separately, the may be nil
	filterParts[#filterParts + 1] = panelData.keywords
	filterParts[#filterParts + 1] = panelData.author

	local addonData = {
		panel = panel,
		name = stripMarkup(panelData.name),
		filterText = stripMarkup(tconcat(filterParts, "\t")):lower(),
	}

	tinsert(addonsForList, addonData)

	if panelData.slashCommand then
		SLASH_COMMANDS[panelData.slashCommand] = function()
			lam:OpenToPanel(panel)
		end
	end

	return panel	--return for authors creating options manually
end


--METHOD: REGISTER OPTION CONTROLS
--registers the options you want shown for your addon
--these are stored in a table where each key-value pair is the order
--of the options in the panel and the data for that control, respectively
--see exampleoptions.lua for an example
--see controls\<widget>.lua for each widget type
--Usage:
--	addonID = "string"; the same string passed to :RegisterAddonPanel
--	optionsTable = table; the table containing all of the options controls and their data
function lam:RegisterOptionControls(addonID, optionsTable)	--optionsTable = {sliderData, buttonData, etc}
	addonToOptionsMap[addonID] = optionsTable
end


--INTERNAL FUNCTION
--creates LAM's Addon Settings entry in ZO_GameMenu
local function CreateAddonSettingsMenuEntry()
	--Russian for TERAB1T's RuESO addon, which creates an "ru" locale
	--game font does not support Cyrillic, so they are using custom fonts + extended latin charset
	--Spanish provided by Luisen75 for their translation project
	local controlPanelNames = {
		en = "Addon Settings",
		fr = "Extensions",
		de = "Erweiterungen",
		ru = "Îacòpoéêè äoïoìîeîèé",
		es = "Configura Addons",
	}

	local panelData = {
		id = KEYBOARD_OPTIONS.currentPanelId,
		name = controlPanelNames[GetCVar("Language.2")] or controlPanelNames["en"],
	}

	KEYBOARD_OPTIONS.currentPanelId = panelData.id + 1
	KEYBOARD_OPTIONS.panelNames[panelData.id] = panelData.name

	lam.panelId = panelData.id

	local addonListSorted = false

	function panelData.callback()
		SCENE_MANAGER:AddFragment(lam:GetAddonSettingsFragment())
		KEYBOARD_OPTIONS:ChangePanels(lam.panelId)

		local title = LAMAddonSettingsWindow:GetNamedChild("Title")
		title:SetText(panelData.name)

		if not addonListSorted and #addonsForList > 0 then
			local searchEdit = LAMAddonSettingsWindow:GetNamedChild("SearchEdit")
			--we're about to show our list for the first time - let's sort it
			table.sort(addonsForList, function(a, b) return a.name < b.name end)
			PopulateAddonList(lam.addonList, GetSearchFilterFunc(searchEdit))
			addonListSorted = true
		end
	end

	function panelData.unselectedCallback()
		SCENE_MANAGER:RemoveFragment(lam:GetAddonSettingsFragment())
		if SetCameraOptionsPreviewModeEnabled then -- available since API version 100011
			SetCameraOptionsPreviewModeEnabled(false)
		end
	end

	ZO_GameMenu_AddSettingPanel(panelData)
end


--INTERNAL FUNCTION
--creates the left-hand menu in LAM's window
local function CreateAddonList(name, parent)
	local addonList = wm:CreateControlFromVirtual(name, parent, "ZO_ScrollList")

	local function addonListRow_OnMouseDown(control, button)
		if button == 1 then
			local data = ZO_ScrollList_GetData(control)
			ZO_ScrollList_SelectData(addonList, data, control)
		end
	end

	local function addonListRow_OnMouseEnter(control)
		ZO_ScrollList_MouseEnter(addonList, control)
	end

	local function addonListRow_OnMouseExit(control)
		ZO_ScrollList_MouseExit(addonList, control)
	end

	local function addonListRow_Select(previouslySelectedData, selectedData, reselectingDuringRebuild)
		if not reselectingDuringRebuild then
			if previouslySelectedData then
				previouslySelectedData.panel:SetHidden(true)
			end
			if selectedData then
				selectedData.panel:SetHidden(false)
				PlaySound(SOUNDS.MENU_SUBCATEGORY_SELECTION)
			end
		end
	end

	local function addonListRow_Setup(control, data)
		control:SetText(data.name)
		control:SetSelected(not data.panel:IsHidden())
	end

	ZO_ScrollList_AddDataType(addonList, ADDON_DATA_TYPE, "ZO_SelectableLabel", 28, addonListRow_Setup)
	-- I don't know how to make highlights clear properly; they often
	-- get stuck and after a while the list is full of highlighted rows
	--ZO_ScrollList_EnableHighlight(addonList, "ZO_ThinListHighlight")
	ZO_ScrollList_EnableSelection(addonList, "ZO_ThinListHighlight", addonListRow_Select)

	local addonDataType = ZO_ScrollList_GetDataTypeTable(addonList, ADDON_DATA_TYPE)
	local addonListRow_CreateRaw = addonDataType.pool.m_Factory

	local function addonListRow_Create(pool)
		local control = addonListRow_CreateRaw(pool)
		control:SetHandler("OnMouseDown", addonListRow_OnMouseDown)
		--control:SetHandler("OnMouseEnter", addonListRow_OnMouseEnter)
		--control:SetHandler("OnMouseExit", addonListRow_OnMouseExit)
		control:SetHeight(28)
		control:SetFont("ZoFontHeader")
		control:SetHorizontalAlignment(TEXT_ALIGN_LEFT)
		control:SetVerticalAlignment(TEXT_ALIGN_CENTER)
		control:SetWrapMode(TEXT_WRAP_MODE_ELLIPSIS)
		return control
	end

	addonDataType.pool.m_Factory = addonListRow_Create

	return addonList
end


--INTERNAL FUNCTION
--creates LAM's Addon Settings top-level window
local function CreateAddonSettingsWindow()
	local tlw = wm:CreateTopLevelWindow("LAMAddonSettingsWindow")
	tlw:SetHidden(true)
	tlw:SetDimensions(1010, 914) -- same height as ZO_OptionsWindow

	ZO_ReanchorControlForLeftSidePanel(tlw)

	-- create black background for the window (mimic ZO_RightFootPrintBackground)

	local bgLeft = wm:CreateControl("$(parent)BackgroundLeft", tlw, CT_TEXTURE)
	bgLeft:SetTexture("EsoUI/Art/Miscellaneous/centerscreen_left.dds")
	bgLeft:SetDimensions(1024, 1024)
	bgLeft:SetAnchor(TOPLEFT, nil, TOPLEFT)
	bgLeft:SetDrawLayer(DL_BACKGROUND)
	bgLeft:SetExcludeFromResizeToFitExtents(true)

	local bgRight = wm:CreateControl("$(parent)BackgroundRight", tlw, CT_TEXTURE)
	bgRight:SetTexture("EsoUI/Art/Miscellaneous/centerscreen_right.dds")
	bgRight:SetDimensions(64, 1024)
	bgRight:SetAnchor(TOPLEFT, bgLeft, TOPRIGHT)
	bgRight:SetDrawLayer(DL_BACKGROUND)
	bgRight:SetExcludeFromResizeToFitExtents(true)

	-- create gray background for addon list (mimic ZO_TreeUnderlay)

	local underlayLeft = wm:CreateControl("$(parent)UnderlayLeft", tlw, CT_TEXTURE)
	underlayLeft:SetTexture("EsoUI/Art/Miscellaneous/centerscreen_indexArea_left.dds")
	underlayLeft:SetDimensions(256, 1024)
	underlayLeft:SetAnchor(TOPLEFT, bgLeft, TOPLEFT)
	underlayLeft:SetDrawLayer(DL_BACKGROUND)
	underlayLeft:SetExcludeFromResizeToFitExtents(true)

	local underlayRight = wm:CreateControl("$(parent)UnderlayRight", tlw, CT_TEXTURE)
	underlayRight:SetTexture("EsoUI/Art/Miscellaneous/centerscreen_indexArea_right.dds")
	underlayRight:SetDimensions(128, 1024)
	underlayRight:SetAnchor(TOPLEFT, underlayLeft, TOPRIGHT)
	underlayRight:SetDrawLayer(DL_BACKGROUND)
	underlayRight:SetExcludeFromResizeToFitExtents(true)

	-- create title bar (mimic ZO_OptionsWindow)

	local title = wm:CreateControl("$(parent)Title", tlw, CT_LABEL)
	title:SetAnchor(TOPLEFT, nil, TOPLEFT, 65, 70)
	title:SetFont("ZoFontWinH1")
	title:SetModifyTextType(MODIFY_TEXT_TYPE_UPPERCASE)

	local divider = wm:CreateControlFromVirtual("$(parent)Divider", tlw, "ZO_Options_Divider")
	divider:SetAnchor(TOPLEFT, nil, TOPLEFT, 65, 108)

	-- create scrollable addon list

	local addonList = CreateAddonList("$(parent)AddonList", tlw)
	addonList:SetAnchor(TOPLEFT, nil, TOPLEFT, 65, 120)
	addonList:SetDimensions(285, 675)

	lam.addonList = addonList -- for easy access from elsewhere

	-- create search filter box

	local searchIcon = wm:CreateControl("$(parent)SearchIcon", tlw, CT_TEXTURE)
	searchIcon:SetTexture("EsoUI/Art/Miscellaneous/search_icon.dds")
	searchIcon:SetDimensions(32, 32)
	searchIcon:SetAnchor(TOPLEFT, addonList, BOTTOMLEFT, -7, 0)
	searchIcon:SetDrawLayer(DL_CONTROLS)
	searchIcon:SetMouseEnabled(true)

	local searchEdit = wm:CreateControlFromVirtual("$(parent)SearchEdit", tlw, "ZO_DefaultEdit")
	if wm.ApplyTemplateToControl then -- available since API version 100011
		wm:ApplyTemplateToControl(searchEdit, "ZO_EditDefaultText")
		ZO_EditDefaultText_Initialize(searchEdit, GetString(SI_ITEM_FILTER_BY_TEXT))
	end
	searchEdit:SetAnchor(TOPLEFT, addonList, BOTTOMLEFT, 30, 5)
	searchEdit:SetAnchor(TOPRIGHT, addonList, BOTTOMRIGHT, -20, 5)

	local searchBg = wm:CreateControlFromVirtual("$(parent)Background", searchEdit, "ZO_EditBackdrop")
	searchBg:SetAnchor(TOPLEFT, searchEdit, TOPLEFT, -4, -2)
	searchBg:SetAnchor(BOTTOMRIGHT, searchEdit, BOTTOMRIGHT, 4, 0)

	searchEdit:SetHandler("OnEscape", function(self)
		self:SetText("")
		self:LoseFocus()
	end)

	searchEdit:SetHandler("OnTextChanged", function(self)
		if wm.ApplyTemplateToControl then -- available since API version 100011
			ZO_EditDefaultText_OnTextChanged(self)
		end
		PopulateAddonList(addonList, GetSearchFilterFunc(self))
		PlaySound(SOUNDS.SPINNER_DOWN)
	end)

	-- create container for option panels

	local panelContainer = wm:CreateControl("$(parent)PanelContainer", tlw, CT_CONTROL)
	panelContainer:SetAnchor(TOPLEFT, addonList, TOPRIGHT, 15, 0)
	panelContainer:SetDimensions(645, 675)

	return tlw
end


--TODO documentation
function lam:GetAddonPanelContainer()
	local fragment = lam:GetAddonSettingsFragment()
	local window = fragment:GetControl()
	return window:GetNamedChild("PanelContainer")
end


--TODO documentation
function lam:GetAddonSettingsFragment()
	if not LAMAddonSettingsFragment then
		local window = CreateAddonSettingsWindow()
		LAMAddonSettingsFragment = ZO_FadeSceneFragment:New(window)
		CreateAddonSettingsMenuEntry()
	end
	return LAMAddonSettingsFragment
end


-- vi: noexpandtab
