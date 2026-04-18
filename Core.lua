---@diagnostic disable: undefined-global, redundant-parameter, missing-parameter
CraftersMark = LibStub("AceAddon-3.0"):NewAddon("CraftersMark", "AceComm-3.0", "AceHook-3.0")

local Serializer = LibStub("LibSerialize")
local Compressor = LibStub("LibDeflate")
local COMM_PREFIX = "CM_CrafterQuery"
local CHANNEL_NAME = "CrafterNetwork"

local addon = CraftersMark
addon.settings = {delay = 30}
addon.unlockAllEnabled = false

function addon:OnInitialize()
    if self.ready then return end
    self.ready = true
    self:RegisterComm(COMM_PREFIX)
    self.resultsProvider = CreateDataProvider()

    C_AddOns.LoadAddOn("Blizzard_ProfessionsCustomerOrders")
    C_AddOns.LoadAddOn("Blizzard_Professions")
    C_AddOns.LoadAddOn("Blizzard_AuctionHouseUI")

    C_Timer.After(tonumber(self.settings.delay) or 30, function()
        self:SetupChannel()
    end)

    self.orderForm = ProfessionsCustomerOrdersFrame.Form

    self:SecureHookScript(self.orderForm, "OnShow")
    self:SecureHookScript(self.orderForm, "OnHide")
    self:SecureHookScript(self.orderForm.OrderRecipientTarget, "OnEditFocusLost", "UpdateTargetCrafter")
    self:SecureHookScript(self.orderForm.OrderRecipientTarget, "OnShow", "UpdateTargetCrafter")
    self:SecureHookScript(self.orderForm.OrderRecipientTarget, "OnHide", "RefreshQualityDisplay")
    self:SecureHookScript(self.orderForm.ReagentContainer.Reagents, "OnShow", "SetupReagentToggle")
    self:SecureHookScript(self.orderForm.ReagentContainer.Reagents, "OnHide", "SetupReagentToggle")

    self:SecureHookScript(ProfessionsFrame, "OnShow", "CreateOrdersAccess")
    self:SecureHookScript(ProfessionsFrame, "OnHide", "OnProfessionsFrameHide")
    self:SecureHookScript(AuctionHouseFrame.TitleContainer, "OnShow", "CreateOrdersAccess")

    local cf = ProfessionsFrame.CraftingPage.SchematicForm
    local of = ProfessionsFrame.OrdersPage.OrderView.OrderDetails.SchematicForm
    self:SecureHookScript(cf.Reagents, "OnShow", "SetupReagentToggle")
    self:SecureHookScript(cf.Reagents, "OnHide", "SetupReagentToggle")
    self:SecureHookScript(cf.FinishingReagents, "OnShow", "SetupReagentToggle")
    self:SecureHookScript(cf.FinishingReagents, "OnHide", "SetupReagentToggle")
    self:SecureHookScript(of.Reagents, "OnShow", "SetupReagentToggle")
    self:SecureHookScript(of.Reagents, "OnHide", "SetupReagentToggle")
    self:SecureHookScript(of.FinishingReagents, "OnShow", "SetupReagentToggle")
    self:SecureHookScript(of.FinishingReagents, "OnHide", "SetupReagentToggle")
    self:SecureHookScript(cf.Details, "OnUpdate", "ShowSkillDetails")
    self:SecureHookScript(of.Details, "OnUpdate", "ShowSkillDetails")
end

function addon:SetupChannel()
    self.channelIndex = GetChannelName(CHANNEL_NAME)
    if self.channelIndex == 0 then
        JoinPermanentChannel(CHANNEL_NAME, nil, nil, false)
        self.channelIndex = GetChannelName(CHANNEL_NAME)
    end
end

function addon:OnShow()
    self.resultsProvider = CreateDataProvider()
    self.chosenCrafter = nil
    self.lastAllocation = nil
    self.allocationTimer = nil

    self:BuildSearchButton()
    self:SetupReagentToggle(self.orderForm.ReagentContainer)
    self:RefreshQualityDisplay()

    EventRegistry:RegisterCallback("Professions.AllocationUpdated", function(...) self:OnAllocationChange(...) end, self)
end

function addon:OnHide()
    EventRegistry:UnregisterCallback("Professions.AllocationUpdated", self)
end

function addon:OnProfessionsFrameHide()
    self:UnhookAll()
    self:SetFlyoutWatcher(false)
    self._reagentCache = nil
end

function addon:UnhookAll()
    addon.unlockAllEnabled = false
    if self:IsHooked(ItemUtil, "GetCraftingReagentCount") then self:Unhook(ItemUtil, "GetCraftingReagentCount") end
    if ProfessionsUtil and self:IsHooked(ProfessionsUtil, "GetReagentQuantityInPossession") then self:Unhook(ProfessionsUtil, "GetReagentQuantityInPossession") end
    if self:IsHooked(C_Item, "GetItemCount") then self:Unhook(C_Item, "GetItemCount") end
    if self:IsHooked(_G, "GetItemCount") then self:Unhook(_G, "GetItemCount") end
    if C_Container and C_Container.GetItemCount and self:IsHooked(C_Container, "GetItemCount") then self:Unhook(C_Container, "GetItemCount") end
    if C_TradeSkillUI and self:IsHooked(C_TradeSkillUI, "GetHideUnownedFlags") then self:Unhook(C_TradeSkillUI, "GetHideUnownedFlags") end
end

function addon:CreateOrdersAccess(parent)
    local frameName = 'CMOrderBtn' .. (parent:GetName() or parent:GetParent():GetName() or "Main")
    local button = _G[frameName] or CreateFrame("Button", frameName, parent, "UIPanelButtonTemplate")
    button:SetFrameLevel(600)
    button:ClearAllPoints()
    button:SetSize(24, 24)
    button:SetText("O")

    if AuctionHouseFrame and parent == AuctionHouseFrame.TitleContainer then
        button:SetPoint("TOPLEFT", 10, 1)
    else
        button:SetPoint("TOPLEFT", 90, 1)
    end

    if not button.ordersFrame then
        local frame = ProfessionsCustomerOrdersFrame
        frame:SetMovable(true)
        frame:SetClampedToScreen(true)
        frame.ignoreFramePositionManager = true
        frame:RegisterForDrag("LeftButton")
        frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
        frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
        button.ordersFrame = frame
    end

    button:SetScript("OnClick", function(self) self.ordersFrame:Show() end)
end

function addon:SetupReagentToggle(container)
    if _G.CMResultsList then _G.CMResultsList:Hide() end
    if not container then return end

    local toggle = container.ReagentUnlocker or self:BuildReagentToggle(container)
    if not toggle then return end

    toggle:ClearAllPoints()
    toggle.active = self.unlockAllEnabled
    toggle:UpdateVisual()

    local simBtn = container.SimButton
    if simBtn then simBtn:ClearAllPoints() end

    if container.Label and container.Label:IsVisible() then
        toggle:SetPoint("LEFT", container.Label, "LEFT", container.Label:GetWrappedWidth(), 0)
        toggle:Show()
        if simBtn then
            simBtn:SetPoint("LEFT", toggle, "RIGHT", 4, 0)
            simBtn:Show()
        end
    else
        toggle:Hide()
        if simBtn then simBtn:Hide() end
    end
end

function addon:OnAllocationChange()
    if not self.orderForm or not self.orderForm.transaction then return end
    local currentAlloc = self.orderForm.transaction:CreateCraftingReagentInfoTbl()
    if not self.lastAllocation then self.lastAllocation = currentAlloc end

    if not self:TableEquals(currentAlloc, self.lastAllocation) then
        self.lastAllocation = currentAlloc
        if self.allocationTimer then self.allocationTimer:Cancel() end
        self.allocationTimer = C_Timer.NewTimer(0.1, function()
            self:UpdateTargetCrafter()
        end)
    end
end

function addon:SendMessage(payload, recipient)
    local encoded = Compressor:EncodeForWoWAddonChannel(
        Compressor:CompressDeflate(Serializer:Serialize(payload)))

    if recipient and string.len(recipient) > 2 then
        self:SendCommMessage(COMM_PREFIX, encoded, "WHISPER", recipient)
    elseif self.channelIndex and payload.query and payload.query.recipeID then
        self:SendCommMessage(COMM_PREFIX, encoded, "CHANNEL", self.channelIndex)
    end
end

function addon:OnCommReceived(prefix, message, channel, sender)
    local decoded = Compressor:DecodeForWoWAddonChannel(message)
    if not decoded then return end
    local decompressed = Compressor:DecompressDeflate(decoded)
    if not decompressed then return end
    local ok, payload = Serializer:Deserialize(decompressed)
    if not ok then return end

    if payload.reply and sender and string.len(sender) > 2 then
        self:StoreResult({crafter = sender, info = payload.reply})
        self:RefreshQualityDisplay()
    end

    if payload.query and payload.query.recipeID then
        local known = C_TradeSkillUI.IsRecipeProfessionLearned(payload.query.recipeID)
        local recipe = C_TradeSkillUI.GetRecipeInfo(payload.query.recipeID)

        if known then
            local crafting
            if payload.query.isRecraft and C_TradeSkillUI.GetCraftingOperationInfoForRecraft then
                crafting = C_TradeSkillUI.GetCraftingOperationInfoForRecraft(
                    payload.query.recipeID, payload.query.reagents or {}, nil)
            end
            if not crafting or crafting.baseSkill == 0 then
                crafting = C_TradeSkillUI.GetCraftingOperationInfo(
                    payload.query.recipeID, payload.query.reagents or {})
            end

            if not crafting or crafting.baseSkill == 0 then return end
            crafting.learned = (not recipe and "notloaded") or (not recipe.learned and "notlearned")
            self:SendMessage({reply = crafting}, sender)
        end
    end
end

function addon:StoreResult(entry)
    if not self.resultsProvider then self.resultsProvider = CreateDataProvider() end
    self.resultsProvider:RemoveByPredicate(function(el)
        return el.crafter and entry.crafter and el.crafter == entry.crafter
    end)
    self.resultsProvider:Insert(entry)
end

function addon:UpdateTargetCrafter()
    local target = self.orderForm.OrderRecipientTarget:GetText()
    if target and string.len(target) > 3 then
        self:RequestCrafterInfo(target)
    end
end

function addon:RequestCrafterInfo(target)
    local trans = self.orderForm.transaction
    if not trans or not trans.recipeID then return end

    local isRecraft = false
    pcall(function() isRecraft = trans:GetRecraftItemGUID() ~= nil end)

    self:SendMessage({
        query = {
            recipeID = trans.recipeID,
            reagents = trans:CreateCraftingReagentInfoTbl() or {},
            isRecraft = isRecraft,
        }
    }, target)
end

function addon:OnSearchClick(button, ...)
    if self.channelIndex == 0 then
        self:SetupChannel()
    else
        self.resultsProvider:Flush()
        self:RequestCrafterInfo()
        self:ShowResultsList(button)
    end
end

function addon:ChooseCrafter(entry)
    self.chosenCrafter = entry
    if self.orderForm and self.orderForm.OrderRecipientTarget then
        self.orderForm.OrderRecipientTarget:SetText(entry.crafter)
        self:RefreshQualityDisplay()
    end
end

function addon:BuildSearchButton()
    local form = self.orderForm
    local button = _G.CMSearchButton or CreateFrame("Button", "CMSearchButton", form.OrderRecipientTarget, "UIPanelButtonTemplate")

    button:SetSize(80, 22)
    button:SetTextToFit("Find")
    button:SetPoint("TOPRIGHT", form.OrderRecipientTarget, "TOPLEFT", -31, 0)
    button:SetScript("OnClick", function(btn, ...) addon:OnSearchClick(btn, ...) end)
    button._nextCheck = 0
    button:SetScript("OnUpdate", function(btn, elapsed)
        btn._nextCheck = btn._nextCheck - elapsed
        if btn._nextCheck > 0 then return end
        btn._nextCheck = 0.5
        addon.channelIndex = GetChannelName(CHANNEL_NAME)
        btn:SetTextToFit(addon.channelIndex == 0 and "Join" or "Find")
    end)
    self.searchButton = button
end

function addon:RefreshQualityDisplay()
    local form = ProfessionsCustomerOrdersFrame.Form
    if not form:IsVisible() or not form.transaction then return end

    local recipeID = form.transaction.recipeID
    local target = form.OrderRecipientTarget
    local name = target and target:GetText()

    if target and target:IsVisible() and name and recipeID and string.len(name) > 2 then
        local function matches(el)
            return el and el.crafter and el.info and name and recipeID
                and el.crafter == name and el.info.recipeID == recipeID
        end

        local _, result = self.resultsProvider:FindByPredicate(matches)

        if matches(result) then
            form:SetMinimumQualityIndex(result.info.craftingQuality)
            form:UpdateMinimumQuality()
            form.MinimumQuality.Dropdown:Hide()

            local label = form.MinimumQuality
            label.Text:ClearAllPoints()
            label.Text:SetPoint("RIGHT", label.Dropdown, "LEFT", -25, 0)

            local display = _G.CMQualityDisplay or CreateFrame("Frame", "CMQualityDisplay", label)
            display:ClearAllPoints()
            display:SetPoint("LEFT", label.Text, "RIGHT", 0, 0)
            display:SetSize(100, 40)
            display:Show()

            local qualityText = _G.CMQualityText or display:CreateFontString("CMQualityText", "ARTWORK", "GameFontNormal")
            qualityText:ClearAllPoints()
            qualityText:SetPoint("TOPLEFT", display, "TOPLEFT", 0, -8)
            qualityText:SetText(self:FormatCrafterInfo(result, true))
            qualityText:Show()

            local skillText = _G.CMSkillText or display:CreateFontString("CMSkillText", "ARTWORK", "GameFontNormal")
            skillText:SetText(format("Skill: %d/%d",
                result.info.baseSkill + result.info.bonusSkill,
                result.info.baseDifficulty + result.info.bonusDifficulty))
            skillText:SetTextColor(GRAY_FONT_COLOR.r, GRAY_FONT_COLOR.g, GRAY_FONT_COLOR.b)
            skillText:ClearAllPoints()
            skillText:SetPoint("TOPLEFT", display, "TOPLEFT", 2, -32)
            skillText:SetScale(0.7)
            skillText:Show()
            return
        end
    end

    form:UpdateMinimumQualityAnchor()
    form:UpdateMinimumQuality()
    form.MinimumQuality.Dropdown:Show()
    if _G.CMQualityDisplay then _G.CMQualityDisplay:Hide() end
end

function addon:ShowResultsList(anchor)
    local list = _G.CMResultsList or CreateFrame("Frame", "CMResultsList", anchor:GetParent(), "TooltipBackdropTemplate")
    local scrollBox = _G.CMResultsScrollBox or CreateFrame("Frame", "$parentScrollBox", list, "WowScrollBoxList")
    local scrollBar = _G.CMResultsScrollBar or CreateFrame("EventFrame", "$parentScrollBar", list, "MinimalScrollBar")

    list:SetFrameStrata("TOOLTIP")
    list:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 5, 0)
    list:SetSize(250, 100)
    list:RegisterEvent("GLOBAL_MOUSE_DOWN")
    list:SetScript("OnEvent", function(self, event, ...)
        if event == "GLOBAL_MOUSE_DOWN" then
            local buttonName = ...
            local isRight = buttonName == "RightButton"
            local mouseFocus = (GetMouseFoci and GetMouseFoci()[1]) or (GetMouseFocus and GetMouseFocus())
            if not isRight and DoesAncestryInclude(self.owner, mouseFocus) then return end
            if isRight or (not DoesAncestryInclude(self, mouseFocus) and mouseFocus ~= self) then
                self:Hide()
            end
        end
    end)

    scrollBox:SetPoint("TOPLEFT", 2, -4)
    scrollBox:SetPoint("BOTTOMRIGHT", 2, 4)
    scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 0, 0)
    scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 0, 0)

    local view = CreateScrollBoxListLinearView(4, 4, 4, 4)
    view:SetElementExtent(20)
    view:SetDataProvider(self.resultsProvider)

    view:SetElementInitializer("Button", function(button, elementData)
        if not button.setup then
            button.setup = true
            button.label = button:CreateFontString(nil, "OVERLAY", "GameTooltipText")
            button.label:SetPoint("LEFT", 4, 0)
            button.label:SetFontObject("GameFontNormal")
            button.label:SetTextColor(1, 1, 1)
            button:SetHighlightTexture("auctionhouse-ui-row-highlight")
            button:GetHighlightTexture():SetBlendMode("ADD")
            button:GetHighlightTexture():SetAllPoints()
            button:SetScript("OnClick", function(btn) list:SelectEntry(btn.elementData) end)
        end
        button.label:SetText(addon:FormatCrafterInfo(elementData))
        button.elementData = elementData
    end)
    ScrollUtil.InitScrollBoxWithScrollBar(scrollBox, scrollBar, view)

    list.addon = self
    list.owner = anchor
    function list:SelectEntry(...)
        self.addon:ChooseCrafter(...)
        self:Hide()
    end

    list:Show()
end

function addon:PatchFlyoutInstance(flyout)
    if not flyout then return end

    if not flyout._cmShowHooked then
        flyout._cmShowHooked = true
        flyout:HookScript("OnShow", function(f) addon:PatchFlyoutInstance(f) end)
    end

    local behavior = flyout.behavior
    if not behavior or behavior._cmPatched then return end
    behavior._cmPatched = true

    local origEnabled = behavior.IsElementEnabled
    behavior.IsElementEnabled = function(b, ed, c)
        if addon.unlockAllEnabled then return true end
        if origEnabled then return origEnabled(b, ed, c) end
        return false
    end

    local origFlags = behavior.GetUnownedFlags
    if type(origFlags) == "function" then
        behavior.GetUnownedFlags = function(b, ...)
            if addon.unlockAllEnabled then
                return {alwaysShowUnavailable = true, cannotModifyHideUnavailable = false}
            end
            return origFlags(b, ...)
        end
    end

    if flyout.ScrollBox and not flyout.ScrollBox._cmUpdateHooked then
        flyout.ScrollBox._cmUpdateHooked = true
        flyout.ScrollBox:HookScript("OnUpdate", function(sb, dt)
            sb._cmElapsed = (sb._cmElapsed or 0) + dt
            if sb._cmElapsed < 0.05 then return end
            sb._cmElapsed = 0
            if addon.unlockAllEnabled then
                pcall(function() addon:EnableFlyoutButtons(flyout) end)
            end
        end)
    end

    pcall(function() addon:EnableFlyoutButtons(flyout) end)
end

function addon:PatchVisibleFlyouts()
    local function scanChildren(parent)
        if not parent then return end
        local ok, n = pcall(function() return parent:GetNumChildren() end)
        if not ok or not n then return end
        for i = 1, n do
            local ok2, child = pcall(function() return select(i, parent:GetChildren()) end)
            if ok2 and child then
                local ok3, hasBehavior = pcall(function() return child.behavior ~= nil end)
                if ok3 and hasBehavior then
                    self:PatchFlyoutInstance(child)
                end
            end
        end
    end

    local pf = ProfessionsFrame
    local cf = pf and pf.CraftingPage and pf.CraftingPage.SchematicForm
    local of = pf and pf.OrdersPage and pf.OrdersPage.OrderView
        and pf.OrdersPage.OrderView.OrderDetails
        and pf.OrdersPage.OrderView.OrderDetails.SchematicForm
    scanChildren(cf)
    scanChildren(of)
end

function addon:EnableFlyoutButtons(flyout)
    if not flyout or not flyout.ScrollBox then return end
    local target = flyout.ScrollBox.ScrollTarget
    if not target then return end
    pcall(function()
        for i = 1, target:GetNumChildren() do
            local child = select(i, target:GetChildren())
            if child then
                if not child._cmFlyoutHooked and child.Disable then
                    child._cmFlyoutHooked = true
                    hooksecurefunc(child, "Disable", function(s)
                        if addon.unlockAllEnabled then
                            s:Enable()
                            s.enabled = true
                            pcall(function()
                                local ed = s.GetElementData and s:GetElementData()
                                if ed and ed.reagent then
                                    if ed.reagent.currencyID then
                                        s.count = 0
                                        if s.Count then s.Count:Hide() end
                                    elseif ed.reagent.itemID then
                                        local recipeID = addon:GetActiveRecipeID()
                                        if recipeID then
                                            local itemMap = addon:GetReagentRequirementMaps(recipeID)
                                            local qty = itemMap[ed.reagent.itemID]
                                            if qty then s.count = qty end
                                        end
                                    end
                                end
                            end)
                            if s.Icon then s.Icon:SetDesaturated(false) end
                            if s.SlotBackground then s.SlotBackground:SetDesaturated(false) end
                        end
                    end)
                end
                if child.Enable then child:Enable() end
                child.enabled = true
                pcall(function()
                    local ed = child.GetElementData and child:GetElementData()
                    if ed and ed.reagent then
                        if ed.reagent.currencyID then
                            child.count = 0
                            if child.Count then child.Count:Hide() end
                        elseif ed.reagent.itemID then
                            local recipeID = addon:GetActiveRecipeID()
                            if recipeID then
                                local itemMap = addon:GetReagentRequirementMaps(recipeID)
                                local qty = itemMap[ed.reagent.itemID]
                                if qty then child.count = qty end
                            end
                        end
                    end
                end)
                if child.Icon then child.Icon:SetDesaturated(false) end
                if child.SlotBackground then child.SlotBackground:SetDesaturated(false) end
            end
        end
    end)
end

function addon:SetFlyoutWatcher(enabled)
    if not self._flyoutWatcher then
        self._flyoutWatcher = CreateFrame("Frame")
        self._flyoutWatcher.elapsed = 0
        self._flyoutWatcher:SetScript("OnUpdate", function(f, dt)
            f.elapsed = f.elapsed + dt
            if f.elapsed < 0.1 then return end
            f.elapsed = 0
            addon:PatchVisibleFlyouts()
            local pf = ProfessionsFrame
            local cf = pf and pf.CraftingPage and pf.CraftingPage.SchematicForm
            local of = pf and pf.OrdersPage and pf.OrdersPage.OrderView
                and pf.OrdersPage.OrderView.OrderDetails
                and pf.OrdersPage.OrderView.OrderDetails.SchematicForm
            local function enableInForm(form)
                if not form then return end
                pcall(function()
                    for i = 1, form:GetNumChildren() do
                        local child = select(i, form:GetChildren())
                        local ok, hasBeh = pcall(function() return child.behavior ~= nil end)
                        if ok and hasBeh then addon:EnableFlyoutButtons(child) end
                    end
                end)
            end
            enableInForm(cf)
            enableInForm(of)
        end)
    end
    if enabled then
        self._flyoutWatcher:Show()
    else
        self._flyoutWatcher:Hide()
    end
end

function addon:ClearReagentSlotColors()
    local function clearSlot(slot)
        if not slot then return end
        if slot.overrideNameColor ~= nil then
            slot.overrideNameColor = nil
            if slot.Update and not slot._cmUpdating then
                slot._cmUpdating = true
                pcall(function() slot:Update() end)
                slot._cmUpdating = nil
            end
        end
    end

    local function clearContainer(container)
        if not container then return end
        for i = 1, container:GetNumChildren() do
            local child = select(i, container:GetChildren())
            clearSlot(child)
            if child and child.GetNumChildren then
                for j = 1, child:GetNumChildren() do
                    clearSlot(select(j, child:GetChildren()))
                end
            end
        end
    end

    local pf = ProfessionsFrame
    local cf = pf and pf.CraftingPage and pf.CraftingPage.SchematicForm
    local of = pf and pf.OrdersPage and pf.OrdersPage.OrderView
        and pf.OrdersPage.OrderView.OrderDetails and pf.OrdersPage.OrderView.OrderDetails.SchematicForm
    if cf then
        clearContainer(cf.Reagents)
        clearContainer(cf.OptionalReagents)
        clearContainer(cf.FinishingReagents)
    end
    if of then
        clearContainer(of.Reagents)
        clearContainer(of.OptionalReagents)
        clearContainer(of.FinishingReagents)
    end
    local form = ProfessionsCustomerOrdersFrame and ProfessionsCustomerOrdersFrame.Form
    if form then
        clearContainer(form.ReagentContainer and form.ReagentContainer.Reagents)
        clearContainer(form.OptionalReagents)
        clearContainer(form.FinishingReagents)
    end
end

function addon:RefreshReagentSlots()
    local function processSlot(slot)
        if not slot then return end
        local btn = slot.Button or slot
        if not btn then return end
        if not btn._cmHooked and btn.Disable and btn.Enable then
            btn._cmHooked = true
            hooksecurefunc(btn, "Disable", function(s)
                if addon.unlockAllEnabled then
                    s:Enable()
                    if s.Icon then s.Icon:SetDesaturated(false) end
                    if s.SlotBackground then s.SlotBackground:SetDesaturated(false) end
                end
            end)
        end
        if slot ~= btn and slot.SetOverrideNameColor and slot.Update and not slot._cmNameHooked then
            slot._cmNameHooked = true
            hooksecurefunc(slot, "Update", function(s)
                if addon.unlockAllEnabled and s.SetOverrideNameColor and not s._cmUpdating then
                    s._cmUpdating = true
                    s:SetOverrideNameColor(WHITE_FONT_COLOR)
                    s._cmUpdating = nil
                end
            end)
        end
        if addon.unlockAllEnabled then
            if btn.Enable then btn:Enable() end
            if btn.Icon then btn.Icon:SetDesaturated(false) end
            if btn.SlotBackground then btn.SlotBackground:SetDesaturated(false) end
            if slot ~= btn and slot.SetOverrideNameColor then
                slot:SetOverrideNameColor(WHITE_FONT_COLOR)
            end
        end
    end

    local function refreshContainer(container)
        if not container or not container:IsVisible() then return end
        for i = 1, container:GetNumChildren() do
            local child = select(i, container:GetChildren())
            processSlot(child)
            if child and child.GetNumChildren then
                for j = 1, child:GetNumChildren() do
                    processSlot(select(j, child:GetChildren()))
                end
            end
        end
    end

    local pf = ProfessionsFrame
    local cf = pf and pf.CraftingPage and pf.CraftingPage.SchematicForm
    local of = pf and pf.OrdersPage and pf.OrdersPage.OrderView
        and pf.OrdersPage.OrderView.OrderDetails and pf.OrdersPage.OrderView.OrderDetails.SchematicForm
    if cf then
        refreshContainer(cf.Reagents)
        refreshContainer(cf.OptionalReagents)
        refreshContainer(cf.FinishingReagents)
    end
    if of then
        refreshContainer(of.Reagents)
        refreshContainer(of.OptionalReagents)
        refreshContainer(of.FinishingReagents)
    end
end

function addon:ApplyFlyoutOverrides()
    if not self:IsHooked(ItemUtil, "GetCraftingReagentCount") then
        self:RawHook(ItemUtil, "GetCraftingReagentCount", "FakeReagentCount", true)
    end
    if ProfessionsUtil and ProfessionsUtil.GetReagentQuantityInPossession
        and not self:IsHooked(ProfessionsUtil, "GetReagentQuantityInPossession") then
        self:RawHook(ProfessionsUtil, "GetReagentQuantityInPossession", "FakeReagentCount", true)
    end
    if not self:IsHooked(C_Item, "GetItemCount") then
        self:RawHook(C_Item, "GetItemCount", "FakeReagentCount", true)
    end
    if not self:IsHooked(_G, "GetItemCount") then
        self:RawHook(_G, "GetItemCount", "FakeReagentCount", true)
    end
    if C_Container and C_Container.GetItemCount and not self:IsHooked(C_Container, "GetItemCount") then
        self:RawHook(C_Container, "GetItemCount", "FakeReagentCount", true)
    end

    if C_TradeSkillUI and C_TradeSkillUI.GetHideUnownedFlags
        and not self:IsHooked(C_TradeSkillUI, "GetHideUnownedFlags") then
        self:RawHook(C_TradeSkillUI, "GetHideUnownedFlags", function(recipeID)
            if addon.unlockAllEnabled then return false, true end
            return addon.hooks[C_TradeSkillUI]["GetHideUnownedFlags"](recipeID)
        end, true)
    end

    self:RefreshReagentSlots()
end

function addon:BuildReagentToggle(parent)
    if not parent then return end

    local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    parent.ReagentUnlocker = btn
    btn:SetSize(78, 22)
    btn:Hide()
    btn.active = false

    function btn:UpdateVisual()
        local r, g, b = self.active and 0.08 or 0.45, self.active and 0.08 or 0.08, self.active and 0.08 or 0.08
        for _, tex in ipairs({ self:GetNormalTexture(), self:GetPushedTexture(), self:GetHighlightTexture() }) do
            if tex then tex:SetVertexColor(r, g, b) end
        end
        self:SetText(YELLOW_FONT_COLOR:WrapTextInColorCode(self.active and "Reset" or "Override"))
    end
    btn:UpdateVisual()

    function btn:Refresh()
        self.active = not self.active
        self:UpdateVisual()
        addon.unlockAllEnabled = self.active

        if addon.unlockAllEnabled then
            addon:ApplyFlyoutOverrides()
            addon:SetFlyoutWatcher(true)
        else
            addon:UnhookAll()
            addon:SetFlyoutWatcher(false)
            addon._reagentCache = nil
            addon:ClearAutoAllocations()
            addon:ClearReagentSlotColors()
        end

        if ProfessionsFrame.OrdersPage.OrderView:IsVisible() then
            ProfessionsFrame.OrdersPage.OrderView:OnEvent("BAG_UPDATE")
        elseif ProfessionsCustomerOrdersFrame.Form:IsVisible() then
            ProfessionsCustomerOrdersFrame.Form:OnEvent("BAG_UPDATE")
        elseif ProfessionsFrame.CraftingPage.SchematicForm.UpdateAllSlots then
            ProfessionsFrame.CraftingPage.SchematicForm:UpdateAllSlots()
        end

        if addon.unlockAllEnabled then
            C_Timer.After(0.15, function()
                if addon.unlockAllEnabled then
                    addon:AutoSelectCurrencyReagents()
                end
            end)
        end

        local container = self:GetParent()
        if container then
            local qDialog = container.QualityDialog
            if qDialog and qDialog.recipeID and qDialog.Setup then qDialog:Setup() end
        end
    end

    btn:SetScript("OnClick", function(self) self:Refresh() end)
    btn:SetScript("OnHide", function()
        addon:UnhookAll()
        addon:SetFlyoutWatcher(false)
        addon._reagentCache = nil
    end)

    local simBtn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    parent.SimButton = simBtn
    simBtn:SetSize(78, 22)
    simBtn:SetText("Sim")
    simBtn:Hide()
    simBtn:SetScript("OnClick", function() addon:OnSimClick() end)

    return btn
end

function addon:AutoSelectCurrencyReagents()
    local recipeID = self:GetActiveRecipeID()
    if not recipeID then return end

    local function findWidget(form, slotIndex)
        local containers = {form.Reagents, form.OptionalReagents, form.FinishingReagents,
                            form.ReagentContainer and form.ReagentContainer.Reagents}
        for _, container in ipairs(containers) do
            if container then
                for i = 1, container:GetNumChildren() do
                    local child = select(i, container:GetChildren())
                    if child and child.reagentSlotSchematic
                        and child.reagentSlotSchematic.slotIndex == slotIndex then
                        return child
                    end
                end
            end
        end
    end

    local function applyToForm(form)
        if not form or not form:IsVisible() or not form.transaction then return end
        local tx = form.transaction
        if not tx.OverwriteAllocation then return end
        local schematic = tx.recipeSchematic
        if not schematic or not schematic.reagentSlotSchematics then return end
        for slotIndex, slotSchematic in ipairs(schematic.reagentSlotSchematics) do
            if slotSchematic.reagents then
                local reagent = nil
                if slotSchematic.reagentType == Enum.CraftingReagentType.Basic then
                    if #slotSchematic.reagents >= 2 then
                        reagent = slotSchematic.reagents[#slotSchematic.reagents]
                    end
                elseif #slotSchematic.reagents == 1 then
                    reagent = slotSchematic.reagents[1]
                else
                    for _, r in ipairs(slotSchematic.reagents) do
                        if r.currencyID then reagent = r end
                    end
                end
                if reagent and (reagent.itemID or reagent.currencyID) then
                    local qty = (slotSchematic.GetQuantityRequired and slotSchematic:GetQuantityRequired(reagent))
                        or slotSchematic.quantityRequired or 1
                    pcall(function() tx:OverwriteAllocation(slotIndex, reagent, qty) end)
                    local widget = findWidget(form, slotIndex)
                    if widget and widget.SetReagent then
                        pcall(function() widget:SetReagent(reagent) end)
                    end
                end
            end
        end
        if form.TriggerEvent and ProfessionsRecipeSchematicFormMixin
            and ProfessionsRecipeSchematicFormMixin.Event
            and ProfessionsRecipeSchematicFormMixin.Event.AllocationsModified then
            pcall(function() form:TriggerEvent(ProfessionsRecipeSchematicFormMixin.Event.AllocationsModified) end)
        end
    end

    local pf = ProfessionsFrame
    applyToForm(pf and pf.CraftingPage and pf.CraftingPage.SchematicForm)
    applyToForm(pf and pf.OrdersPage and pf.OrdersPage.OrderView
        and pf.OrdersPage.OrderView.OrderDetails
        and pf.OrdersPage.OrderView.OrderDetails.SchematicForm)
    applyToForm(ProfessionsCustomerOrdersFrame and ProfessionsCustomerOrdersFrame.Form)
end

function addon:ClearAutoAllocations()
    local function clearForm(form)
        if not form or not form:IsVisible() or not form.transaction then return end
        local tx = form.transaction
        local schematic = tx.recipeSchematic
        if not schematic or not schematic.reagentSlotSchematics then return end

        local function findWidget(slotIndex)
            local containers = {form.Reagents, form.OptionalReagents, form.FinishingReagents,
                                form.ReagentContainer and form.ReagentContainer.Reagents}
            for _, container in ipairs(containers) do
                if container then
                    for i = 1, container:GetNumChildren() do
                        local child = select(i, container:GetChildren())
                        if child and child.reagentSlotSchematic
                            and child.reagentSlotSchematic.slotIndex == slotIndex then
                            return child
                        end
                    end
                end
            end
        end

        for slotIndex, slotSchematic in ipairs(schematic.reagentSlotSchematics) do
            if slotSchematic.reagents then
                local shouldClear = false
                if slotSchematic.reagentType == Enum.CraftingReagentType.Basic then
                    if #slotSchematic.reagents >= 2 then shouldClear = true end
                elseif #slotSchematic.reagents == 1 then
                    shouldClear = true
                else
                    for _, r in ipairs(slotSchematic.reagents) do
                        if r.currencyID then shouldClear = true end
                    end
                end
                if shouldClear then
                    pcall(function()
                        if tx.allocations then tx.allocations[slotIndex] = nil end
                    end)
                    pcall(function() tx:ClearAllocations(slotIndex) end)
                    local widget = findWidget(slotIndex)
                    if widget then
                        pcall(function()
                            widget.reagent = nil
                            widget:Update()
                        end)
                    end
                end
            end
        end

        if form.TriggerEvent and ProfessionsRecipeSchematicFormMixin
            and ProfessionsRecipeSchematicFormMixin.Event
            and ProfessionsRecipeSchematicFormMixin.Event.AllocationsModified then
            pcall(function() form:TriggerEvent(ProfessionsRecipeSchematicFormMixin.Event.AllocationsModified) end)
        end
    end

    local pf = ProfessionsFrame
    clearForm(pf and pf.CraftingPage and pf.CraftingPage.SchematicForm)
    clearForm(pf and pf.OrdersPage and pf.OrdersPage.OrderView
        and pf.OrdersPage.OrderView.OrderDetails
        and pf.OrdersPage.OrderView.OrderDetails.SchematicForm)
    clearForm(ProfessionsCustomerOrdersFrame and ProfessionsCustomerOrdersFrame.Form)
end

function addon:GetActiveRecipeID()
    local pf = ProfessionsFrame
    local cf = pf and pf.CraftingPage and pf.CraftingPage.SchematicForm
    if cf and cf.transaction and cf.transaction.recipeID then
        return cf.transaction.recipeID
    end
    local of = pf and pf.OrdersPage and pf.OrdersPage.OrderView
        and pf.OrdersPage.OrderView.OrderDetails
        and pf.OrdersPage.OrderView.OrderDetails.SchematicForm
    if of and of.transaction and of.transaction.recipeID then
        return of.transaction.recipeID
    end
    local form = ProfessionsCustomerOrdersFrame and ProfessionsCustomerOrdersFrame.Form
    if form and form.transaction and form.transaction.recipeID then
        return form.transaction.recipeID
    end
end

function addon:GetReagentRequirementMaps(recipeID)
    if self._reagentCache and self._reagentCache.recipeID == recipeID then
        return self._reagentCache.itemMap, self._reagentCache.currencyMap
    end
    local itemMap, currencyMap = {}, {}
    local ok, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
    if ok and schematic and schematic.reagentSlotSchematics then
        for _, slot in ipairs(schematic.reagentSlotSchematics) do
            local qty = slot.quantityRequired or 1
            if slot.reagents then
                for _, reagent in ipairs(slot.reagents) do
                    if reagent.itemID then
                        itemMap[reagent.itemID] = qty
                    end
                    if reagent.currencyID then
                        currencyMap[reagent.currencyID] = qty
                    end
                end
            end
        end
    end
    self._reagentCache = {recipeID = recipeID, itemMap = itemMap, currencyMap = currencyMap}
    return itemMap, currencyMap
end

function addon:FakeReagentCount(arg1)
    local recipeID = self:GetActiveRecipeID()
    if recipeID then
        local itemMap, currencyMap = self:GetReagentRequirementMaps(recipeID)
        local qty
        if type(arg1) == "number" then
            qty = itemMap[arg1]
        elseif type(arg1) == "table" then
            qty = (arg1.itemID and itemMap[arg1.itemID])
               or (arg1.currencyID and currencyMap[arg1.currencyID])
        end
        if qty then return qty end
    end
    return 999
end

function addon:GetUnlockedOperationInfo(details)
    if not self.unlockAllEnabled then return end

    local form = details and details:GetParent()
    local transaction = form and form.transaction
    local recipeID = transaction and transaction.recipeID
    if not recipeID or not transaction.CreateCraftingReagentInfoTbl then return end

    local reagents = transaction:CreateCraftingReagentInfoTbl() or {}

    local isRecraft = false
    if transaction.IsRecraft then
        pcall(function() isRecraft = transaction:IsRecraft() end)
    end

    local crafting
    if isRecraft and C_TradeSkillUI.GetCraftingOperationInfoForRecraft then
        local ok, result = pcall(C_TradeSkillUI.GetCraftingOperationInfoForRecraft, recipeID, reagents, nil)
        if ok then crafting = result end
    end
    if not crafting or (crafting.baseSkill or 0) == 0 then
        local ok, result = pcall(C_TradeSkillUI.GetCraftingOperationInfo, recipeID, reagents, nil, false)
        if ok then crafting = result end
    end

    if crafting and (crafting.baseSkill or 0) > 0 then return crafting end
end

function addon:ShowSkillDetails(details)
    if not details or not details.operationInfo or not details.statLinePool then return end

    local unlockedInfo = self:GetUnlockedOperationInfo(details)
    local operationInfo = unlockedInfo or details.operationInfo

    for line, _ in details.statLinePool:EnumerateActive() do
        if line.LeftLabel:GetText() == PROFESSIONS_CRAFTING_STAT_TT_CRIT_HEADER then
            local text = self:FormatInfoDetails(operationInfo)
            if unlockedInfo then text = "|cffffcc00[+Crest]|r " .. (text or "") end
            line.RightLabel:SetText(text)
            break
        end
    end
end

function addon:FormatCrafterInfo(entry, hideName)
    local info = entry.info
    local display = info and self:FormatInfoDetails(info) or "|cFF999999???|r"
    return entry.crafter and not hideName and format("%s - %s", entry.crafter, display) or display
end

function addon:FormatInfoDetails(info)
    if not info then return end
    if info.learned == "notloaded" then return "|cff999999not loaded|r" end
    if info.learned == "notlearned" then return "|cffff0000not learned|r" end
    if not info.isQualityCraft then return "|cff00ff00ok|r" end

    local skill = info.baseSkill + info.bonusSkill
    local percent, bonus

    for _, stat in pairs(info.bonusStats) do
        if stat.bonusStatName == PROFESSIONS_CRAFTING_STAT_TT_CRIT_HEADER then
            percent, bonus = string.match(stat.ratingDescription, "([0-9]+%.?[0-9]+)%%[^0-9]+([0-9]+)")
            break
        end
    end

    if not (percent and bonus and skill) then return end

    local threshold = skill - info.upperSkillTreshold + (skill < info.upperSkillTreshold and bonus or 0)
    local baseQual = info.craftingQuality
    local procQual = min(info.guaranteedCraftingQualityID <= 3 and 3 or 5, baseQual + (threshold >= 0 and 1 or 0))

    local icon = format("|A:%s:16:16|a", Professions.GetIconForQuality(procQual, true))
    local nextIcon = format("|A:%s:16:16|a", Professions.GetIconForQuality(min(5, procQual + 1), true))

    local thresholdText = (threshold < 0 and format("(|cffff0000%d|r to %s)", threshold, nextIcon))
        or (threshold >= 0 and format("(|cff00ff00+%d|r)", threshold))

    return (baseQual == procQual and format("%s%s", icon, thresholdText))
        or format("%.1f%% to %s%s", percent, icon, thresholdText)
end

function addon:TableEquals(t1, t2, ignoreMeta)
    local ty1, ty2 = type(t1), type(t2)
    if ty1 ~= ty2 then return false end
    if ty1 ~= 'table' then return t1 == t2 end

    local mt = getmetatable(t1)
    if not ignoreMeta and mt and mt.__eq then return t1 == t2 end

    for k, v in pairs(t1) do
        if t2[k] == nil or not self:TableEquals(v, t2[k]) then return false end
    end
    for k, v in pairs(t2) do
        if t1[k] == nil or not self:TableEquals(t1[k], v) then return false end
    end
    return true
end

function addon:GetSimSlots(recipeID)
    local ok, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
    if not ok or not schematic or not schematic.reagentSlotSchematics then return {} end
    local slots = {}
    for _, slot in ipairs(schematic.reagentSlotSchematics) do
        if slot.reagentType == Enum.CraftingReagentType.Basic and slot.reagents and #slot.reagents >= 2 then
            local ranks = {}
            for _, r in ipairs(slot.reagents) do
                if r.itemID then table.insert(ranks, r.itemID) end
            end
            if #ranks >= 2 then
                table.insert(slots, {
                    dataSlotIndex    = slot.dataSlotIndex,
                    quantityRequired = slot.quantityRequired or 1,
                    ranks            = ranks,
                })
            end
        end
    end
    return slots
end

function addon:GetReagentPrices(slots, modifiers)
    local prices = {}
    local hasAny = false
    if not (Auctionator and Auctionator.API and Auctionator.API.v1
            and Auctionator.API.v1.GetAuctionPriceByItemID) then
        return prices, false
    end
    local function fetch(itemID)
        if not itemID or prices[itemID] then return end
        local ok, price = pcall(Auctionator.API.v1.GetAuctionPriceByItemID, "CraftersMark", itemID)
        if ok and type(price) == "number" and price > 0 then
            prices[itemID] = price
            hasAny = true
        end
    end
    for _, slot in ipairs(slots) do
        for _, itemID in ipairs(slot.ranks) do fetch(itemID) end
    end
    for _, mr in ipairs(modifiers or {}) do fetch(mr.itemID) end
    return prices, hasAny
end

function addon:RunSim(recipeID, slots, baseReagents, prices)
    local n = #slots
    if n == 0 then return nil, false, nil end

    local simIndices = {}
    for _, slot in ipairs(slots) do simIndices[slot.dataSlotIndex] = true end

    local function buildReagents(combo)
        local t = {}
        for _, r in ipairs(baseReagents) do
            if not simIndices[r.dataSlotIndex] then
                table.insert(t, r)
            end
        end
        for i, slot in ipairs(slots) do
            local r1qty = combo[i]
            local r2qty = slot.quantityRequired - r1qty
            if r1qty > 0 then
                table.insert(t, {reagent = {itemID = slot.ranks[1]}, quantity = r1qty, dataSlotIndex = slot.dataSlotIndex})
            end
            if r2qty > 0 then
                table.insert(t, {reagent = {itemID = slot.ranks[2]}, quantity = r2qty, dataSlotIndex = slot.dataSlotIndex})
            end
        end
        return t
    end

    local function checkQ5(combo)
        local ok, info = pcall(C_TradeSkillUI.GetCraftingOperationInfo, recipeID, buildReagents(combo), nil, false)
        if not ok or not info then return false, nil end
        local skill = (info.baseSkill or 0) + (info.bonusSkill or 0)
        return skill >= (info.upperSkillTreshold or math.huge), info
    end

    local combo = {}
    for i = 1, n do combo[i] = 0 end

    local canQ5, operationInfo = checkQ5(combo)
    if not canQ5 then
        return combo, false, operationInfo
    end

    local slotOrder = {}
    for i = 1, n do slotOrder[i] = i end
    if prices and next(prices) then
        table.sort(slotOrder, function(a, b)
            local pa = prices[slots[a].ranks[2]] or prices[slots[a].ranks[1]] or 0
            local pb = prices[slots[b].ranks[2]] or prices[slots[b].ranks[1]] or 0
            return pa > pb
        end)
    end

    for _, i in ipairs(slotOrder) do
        local qty = slots[i].quantityRequired
        for count = 1, qty do
            combo[i] = count
            local q5, info = checkQ5(combo)
            if q5 then
                operationInfo = info
            else
                combo[i] = count - 1
                break
            end
        end
    end

    local ok2, fi = pcall(C_TradeSkillUI.GetCraftingOperationInfo, recipeID, buildReagents(combo), nil, false)
    return combo, true, ok2 and fi or operationInfo
end

function addon:OnSimClick()
    local cf = ProfessionsFrame.CraftingPage.SchematicForm
    if not cf or not cf.transaction then return end
    local recipeID = cf.transaction.recipeID
    if not recipeID then return end

    local simSlots = self:GetSimSlots(recipeID)
    if #simSlots == 0 then
        print("|cffff0000CraftersMark:|r No quality reagents found for this recipe.")
        return
    end

    local baseReagents = {}
    pcall(function()
        local reagents = cf.transaction:CreateReagentInfoTbl() or {}
        for _, r in ipairs(reagents) do table.insert(baseReagents, r) end
        local opts = cf.transaction:CreateOptionalOrFinishingCraftingReagentInfoTbl() or {}
        for _, r in ipairs(opts) do table.insert(baseReagents, r) end
    end)

    do
        local schOk, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
        if schOk and schematic and schematic.reagentSlotSchematics then
            local optSlotMap = {}
            for _, slot in ipairs(schematic.reagentSlotSchematics) do
                if slot.reagentType ~= Enum.CraftingReagentType.Basic then
                    optSlotMap[slot.dataSlotIndex] = slot
                end
            end

            local optSimIndices = {}
            local optSimSlots   = {}
            for _, r in ipairs(baseReagents) do
                local rID  = r.reagent and r.reagent.itemID
                local slot = rID and optSlotMap[r.dataSlotIndex]
                if slot and slot.reagents and not optSimIndices[r.dataSlotIndex] then
                    for j, sr in ipairs(slot.reagents) do
                        if sr.itemID == rID then
                            local qi = C_TradeSkillUI.GetItemReagentQualityInfo(rID)
                            if qi then
                                local r1ID, r2ID
                                if qi.quality == 2 and j > 1 then
                                    local prev = slot.reagents[j-1]
                                    local qp   = prev and prev.itemID and C_TradeSkillUI.GetItemReagentQualityInfo(prev.itemID)
                                    if qp and qp.quality == 1 then r1ID, r2ID = prev.itemID, rID end
                                elseif qi.quality == 1 and j < #slot.reagents then
                                    local nxt  = slot.reagents[j+1]
                                    local qn   = nxt and nxt.itemID and C_TradeSkillUI.GetItemReagentQualityInfo(nxt.itemID)
                                    if qn and qn.quality == 2 then r1ID, r2ID = rID, nxt.itemID end
                                end
                                if r1ID and r2ID then
                                    table.insert(optSimSlots, {
                                        dataSlotIndex    = r.dataSlotIndex,
                                        quantityRequired = r.quantity,
                                        ranks            = {r1ID, r2ID},
                                    })
                                    optSimIndices[r.dataSlotIndex] = true
                                end
                            end
                            break
                        end
                    end
                end
            end

            if next(optSimIndices) then
                local filtered = {}
                for _, r in ipairs(baseReagents) do
                    if not optSimIndices[r.dataSlotIndex] then
                        table.insert(filtered, r)
                    end
                end
                baseReagents = filtered
                for _, s in ipairs(optSimSlots) do table.insert(simSlots, s) end
            end
        end
    end

    local simIndexSet = {}
    for _, s in ipairs(simSlots) do simIndexSet[s.dataSlotIndex] = true end
    local modifierReagents = {}
    for _, r in ipairs(baseReagents) do
        local rID = r.reagent and r.reagent.itemID
        if rID and not simIndexSet[r.dataSlotIndex] then
            table.insert(modifierReagents, {itemID = rID, quantity = r.quantity})
        end
    end

    local prices, hasPrices = self:GetReagentPrices(simSlots, modifierReagents)
    local bestCombo, canQ5, operationInfo = self:RunSim(recipeID, simSlots, baseReagents, prices)
    local ok, err = pcall(function()
        self:ShowSimFrame(simSlots, bestCombo, canQ5, operationInfo, prices, modifierReagents)
    end)
    if not ok then print("|cffff0000CraftersMark sim error:|r " .. tostring(err)) end
end

function addon:ShowSimFrame(simSlots, bestCombo, canQ5, operationInfo, prices, modifierReagents)
    if not _G.CMSimFrame then
        local f = CreateFrame("Frame", "CMSimFrame", UIParent, "ButtonFrameTemplate")
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        f:SetClampedToScreen(true)
        f:SetFrameStrata("DIALOG")
        f:SetPoint("CENTER")
        f:Hide()
        ButtonFrameTemplate_HidePortrait(f)
        ButtonFrameTemplate_HideButtonBar(f)
        if f.Inset then f.Inset:Hide() end
        f:SetTitle("Quality Simulation")
        f.rows = {}
    end

    local f = _G.CMSimFrame
    local ICON, PAD, ROW_H = 18, 6, 22
    local NAME_W, COL_W, LEFT, TOP = 180, 50, 12, -34

    f.rows = f.rows or {}

    if not f.hdrName then
        f.hdrName   = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        f.hdrR1     = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        f.hdrR2     = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        f.divLine   = f:CreateTexture(nil, "ARTWORK")
        f.divLine:SetColorTexture(0.4, 0.4, 0.4, 0.8)
        f.divLine:SetHeight(1)
        f.resultStr = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        f.resultStr:SetJustifyH("LEFT")
        f.costStr   = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        f.costStr:SetJustifyH("LEFT")
        f.savingsStr = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        f.savingsStr:SetJustifyH("LEFT")
        f.hintStr   = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        f.hintStr:SetJustifyH("LEFT")
        f.hintStr:SetTextColor(0.5, 0.5, 0.5)
        f.hintStr:SetText("Tip: select optional reagents (crest, etc.) then hit Sim to include their difficulty.")
    end

    local hdrR1Icon, hdrR2Icon = "R1", "R2"
    if simSlots[1] then
        local qi1 = simSlots[1].ranks[1] and C_TradeSkillUI.GetItemReagentQualityInfo(simSlots[1].ranks[1])
        local qi2 = simSlots[1].ranks[2] and C_TradeSkillUI.GetItemReagentQualityInfo(simSlots[1].ranks[2])
        if qi1 and qi1.iconSmall then hdrR1Icon = CreateAtlasMarkup(qi1.iconSmall, 20, 20) end
        if qi2 and qi2.iconSmall then hdrR2Icon = CreateAtlasMarkup(qi2.iconSmall, 20, 20) end
    end

    f.hdrName:SetPoint("TOPLEFT", f, "TOPLEFT", LEFT + ICON + PAD, TOP)
    f.hdrName:SetText("Reagent")
    f.hdrR1:SetPoint("TOPLEFT",   f, "TOPLEFT", LEFT + ICON + PAD + NAME_W,         TOP)
    f.hdrR1:SetWidth(COL_W)
    f.hdrR1:SetJustifyH("CENTER")
    f.hdrR1:SetText(hdrR1Icon)
    f.hdrR2:SetPoint("TOPLEFT",   f, "TOPLEFT", LEFT + ICON + PAD + NAME_W + COL_W, TOP)
    f.hdrR2:SetWidth(COL_W)
    f.hdrR2:SetJustifyH("CENTER")
    f.hdrR2:SetText(hdrR2Icon)
    f.divLine:SetPoint("TOPLEFT", f, "TOPLEFT", LEFT, TOP - ROW_H + 4)
    f.divLine:SetWidth(ICON + PAD + NAME_W + COL_W * 2)

    local rowY = TOP - ROW_H - PAD
    for i, slot in ipairs(simSlots) do
        local r1qty = bestCombo and bestCombo[i] or 0
        local iID  = slot.ranks[1]
        local name, _, _, _, _, _, _, _, _, icon = C_Item.GetItemInfo(iID)
        name = name or ("Item " .. tostring(iID))

        local row = f.rows[i]
        if not row then
            row = CreateFrame("Frame", nil, f)
            f.rows[i]   = row
            row.iconTex = row:CreateTexture(nil, "ARTWORK")
            row.iconTex:SetSize(ICON, ICON)
            row.iconTex:SetPoint("LEFT", 0, 0)
            row.nameStr = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            row.nameStr:SetPoint("LEFT", row.iconTex, "RIGHT", PAD, 0)
            row.nameStr:SetJustifyH("LEFT")
            row.r1Text  = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            row.r1Text:SetJustifyH("CENTER")
            row.r2Text  = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            row.r2Text:SetJustifyH("CENTER")
        end

        row:SetSize(ICON + PAD + NAME_W + COL_W * 2, ROW_H)
        row:SetPoint("TOPLEFT", f, "TOPLEFT", LEFT, rowY)
        row:Show()

        row.iconTex:SetTexture(icon)
        row.nameStr:SetWidth(NAME_W - PAD)
        row.nameStr:SetText(name)

        row.r1Text:ClearAllPoints()
        row.r1Text:SetPoint("LEFT", row, "LEFT", ICON + PAD + NAME_W, 0)
        row.r1Text:SetWidth(COL_W)
        row.r2Text:ClearAllPoints()
        row.r2Text:SetPoint("LEFT", row, "LEFT", ICON + PAD + NAME_W + COL_W, 0)
        row.r2Text:SetWidth(COL_W)

        local qty1 = r1qty
        local qty2 = slot.quantityRequired - r1qty
        row.r1Text:SetText(tostring(qty1))
        row.r1Text:SetTextColor(qty1 > 0 and 1 or 0.45, qty1 > 0 and 1 or 0.45, qty1 > 0 and 1 or 0.45)
        row.r2Text:SetText(tostring(qty2))
        row.r2Text:SetTextColor(qty2 > 0 and 1 or 0.45, qty2 > 0 and 1 or 0.45, qty2 > 0 and 1 or 0.45)

        rowY = rowY - ROW_H
    end

    for i = #simSlots + 1, #f.rows do
        if f.rows[i] then f.rows[i]:Hide() end
    end

    if not f.modRows then f.modRows = {} end
    if f.modDivLine then f.modDivLine:Hide() end
    for mi = 1, #f.modRows do
        if f.modRows[mi] then f.modRows[mi]:Hide() end
    end

    local resultY = rowY - PAD
    f.resultStr:ClearAllPoints()
    f.resultStr:SetPoint("TOPLEFT", f, "TOPLEFT", LEFT, resultY)
    f.resultStr:SetWidth(ICON + PAD + NAME_W + COL_W * 2)

    if canQ5 then
        f.resultStr:SetText("|cff00ff00Q5 achievable without concentration|r")
    else
        local skill    = operationInfo and ((operationInfo.baseSkill or 0) + (operationInfo.bonusSkill or 0)) or 0
        local need     = operationInfo and (operationInfo.upperSkillTreshold or 0) or 0
        local gap      = need - skill
        local curQ     = operationInfo and (operationInfo.craftingQuality or 0) or 0
        local curQIcon = curQ > 0 and format("|A:Professions-Icon-Quality-Tier%d:12:12|a", curQ) or ""
        if gap > 0 then
            f.resultStr:SetText(format("%sBest quality: Q%d — |cffff8000%d skill short, use concentration|r", curQIcon, curQ, gap))
        else
            f.resultStr:SetText("|cffff0000Q5 not achievable for this recipe|r")
        end
    end

    f.costStr:ClearAllPoints()
    f.costStr:SetPoint("TOPLEFT", f.resultStr, "BOTTOMLEFT", 0, -4)
    f.costStr:SetWidth(ICON + PAD + NAME_W + COL_W * 2)

    local function coin(amount)
        return (C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString)
            and C_CurrencyInfo.GetCoinTextureString(amount)
            or GetMoneyString(amount)
    end

    local totalCost, maxCost, allPriced = 0, 0, true
    if prices and next(prices) and bestCombo then
        for i, slot in ipairs(simSlots) do
            local r1qty = bestCombo[i] or 0
            local r2qty = slot.quantityRequired - r1qty
            local r1price = prices[slot.ranks[1]]
            local r2price = prices[slot.ranks[2]]
            if r1qty > 0 then
                if r1price then totalCost = totalCost + r1price * r1qty else allPriced = false end
            end
            if r2qty > 0 then
                if r2price then totalCost = totalCost + r2price * r2qty else allPriced = false end
            end
            if r2price then
                maxCost = maxCost + r2price * slot.quantityRequired
            end
        end
        for _, mr in ipairs(modifierReagents or {}) do
            local mp = prices[mr.itemID]
            if mp then
                totalCost = totalCost + mp * mr.quantity
                maxCost   = maxCost   + mp * mr.quantity
            end
        end
        local costText = allPriced
            and ("Est. cost: " .. coin(totalCost))
            or  ("Est. cost: " .. coin(totalCost) .. " |cffaaaaaa(partial)|r")
        f.costStr:SetText(costText)
        f.costStr:Show()
    else
        f.costStr:Hide()
    end

    local savings = maxCost - totalCost
    if f.costStr:IsShown() and savings > 0 then
        f.savingsStr:ClearAllPoints()
        f.savingsStr:SetPoint("TOPLEFT", f.costStr, "BOTTOMLEFT", 0, -2)
        f.savingsStr:SetWidth(ICON + PAD + NAME_W + COL_W * 2)
        f.savingsStr:SetText("|cff00ff00Saves " .. coin(savings) .. "|r vs all max-rank")
        f.savingsStr:Show()
    else
        f.savingsStr:Hide()
    end

    f.hintStr:ClearAllPoints()
    f.hintStr:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", LEFT, 10)
    f.hintStr:SetWidth(ICON + PAD + NAME_W + COL_W * 2)

    local extraH = (f.costStr:IsShown() and ROW_H or 0)
                 + (f.savingsStr:IsShown() and ROW_H or 0)
                 + ROW_H
    f:SetHeight(math.abs(resultY) + ROW_H + extraH + 20)
    f:SetWidth(LEFT * 2 + ICON + PAD + NAME_W + COL_W * 2)
    if not f:IsShown() then
        f:ClearAllPoints()
        f:SetPoint("CENTER")
    end
    f:Show()
    f:Raise()
end
